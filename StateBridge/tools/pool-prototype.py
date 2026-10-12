#!/usr/bin/env python3
"""Jason-only bridge for the installed BC 163 store, until the native reader ships.

SQLite is opened read-only. Credentials stay in the existing BC Keychain item.
Run once per minute with launchd; no schema migration or native outbox writes.
"""
import argparse
import base64
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import time
import urllib.request
import uuid

ORIGIN = "https://jason-state-bridge.jason25417.chatgpt.site"
SUPPORT = Path.home() / "Library/Containers/com.jason.BetterCalendar/Data/Library/Application Support"
STATE_DIR = Path.home() / "Library/Application Support/BetterCalendarPrototype"
PREFIX = "prototype_pool_"


def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def record_uuid(value):
    if value is None:
        return None
    if not isinstance(value, bytes) or len(value) != 16:
        raise ValueError("unsupported record identity")
    return str(uuid.UUID(bytes=value)).upper()


def date_ms(value):
    # Core Data dates are seconds since 2001-01-01, not Unix timestamps.
    return None if value is None else (float(value) + 978307200) * 1000


def deletion(row):
    deleted = date_ms(row.get("ZDELETEDAT"))
    deletion_id = record_uuid(row.get("ZDELETIONID"))
    restored = record_uuid(row.get("ZRESTOREDDELETIONID"))
    return {"deletedAt": deleted, "deletionId": deletion_id, "restoredDeletionId": restored,
            "deletionContext": base64.b64encode(row["ZDELETIONCONTEXT"]).decode() if row.get("ZDELETIONCONTEXT") is not None else None,
            "isInTrash": deletion_id is not None and deletion_id != restored}


def read_pool(store):
    # A consistent read transaction includes WAL changes made by the real App.
    connection = sqlite3.connect(store.resolve().as_uri() + "?mode=ro", uri=True, timeout=3)
    connection.row_factory = sqlite3.Row
    try:
        connection.execute("PRAGMA query_only=ON")
        connection.execute("BEGIN")
        tasks = [dict(r) for r in connection.execute("SELECT * FROM ZLONGTASK")]
        stages = [dict(r) for r in connection.execute("SELECT * FROM ZLONGTASKCHECKPOINT")]
        required = {"Z_PK", "ZID", "ZTITLE", "ZNOTE", "ZSTATUS", "ZZONERAW", "ZCREATEDAT", "ZMODIFIEDAT"}
        columns = {r[1] for r in connection.execute("PRAGMA table_info(ZLONGTASK)")}
        if not required <= columns:
            raise ValueError("unsupported BC store schema")
        parents = {r["Z_PK"] for r in tasks}
        if any(r["ZTASK"] not in parents for r in stages):
            raise ValueError("orphan stages: refusing an incomplete catalog")
        records = []
        for task in tasks:
            task_id = record_uuid(task["ZID"])
            if task_id is None or task["ZSTATUS"] not in ("active", "done", "shelved"):
                raise ValueError("unsupported task identity or state")
            checkpoints = []
            for cp in stages:
                if cp["ZTASK"] != task["Z_PK"]:
                    continue
                if cp["ZID"] is None:
                    raise ValueError("missing stage identity")
                checkpoints.append({"id": record_uuid(cp["ZID"]), "title": cp["ZTITLE"], "order": cp["ZORDER"],
                                    "estimatedMinutes": cp["ZESTIMATEDMINUTES"], "doneAt": date_ms(cp["ZDONEAT"]),
                                    "createdAt": date_ms(cp["ZCREATEDAT"]), **deletion(cp)})
            checkpoints.sort(key=lambda r: (r["order"], r["id"]))
            if len({r["id"] for r in checkpoints}) != len(checkpoints):
                raise ValueError("duplicate stage identities")
            values = {"id": task_id, "title": task["ZTITLE"], "note": task["ZNOTE"], "zone": task["ZZONERAW"],
                      "status": task["ZSTATUS"], "createdAt": date_ms(task["ZCREATEDAT"]), "modifiedAt": date_ms(task["ZMODIFIEDAT"]),
                      "deadline": date_ms(task["ZDEADLINE"]), "doneAt": date_ms(task["ZDONEAT"]),
                      "cadenceMinutesPerWeek": task["ZCADENCEMINUTESPERWEEK"], "totalMinutes": task["ZTOTALMINUTES"],
                      "unitMinutes": task["ZUNITMINUTES"], "family": task["ZFAMILY"], "spilledFromDay": date_ms(task["ZSPILLEDFROMDAY"]),
                      "checkpoints": checkpoints, **deletion(task)}
            records.append({"id": task_id, "revision": digest(encode(values)), "values": values})
        records.sort(key=lambda r: r["id"])
        if len({r["id"] for r in records}) != len(records):
            raise ValueError("duplicate task identities")
        payload = encode({"formatVersion": 1, "authority": "swiftdata", "dateUnit": "unix-milliseconds", "records": records,
                          "reader": "mac-sqlite-prototype-163"})
        if len(payload) > 8 * 1024 * 1024:
            raise ValueError("catalog exceeds existing bridge limit")
        return payload, len(records), len(stages)
    finally:
        connection.close()


def write_state(path, value):
    temporary = path.with_suffix(".new")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as out:
        out.write(encode(value))
    os.replace(temporary, path)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


def run(args):
    pool, count, stage_count = read_pool(args.store)
    if args.dry_run:
        print(json.dumps({"mode": "read-only", "recordCount": count, "stageCount": stage_count, "bytes": len(pool), "contentHash": digest(pool)}))
        return
    native_queue = json.loads((SUPPORT / "DotStateBridge/outbox-v1.json").read_text())
    if native_queue.get("poolCache") is not None:
        print('{"status":"native-reader-took-over"}')
        return
    secret = subprocess.run(["security", "find-generic-password", "-s", "com.jason.BetterCalendar.StateBridge", "-a", "dot-state-bridge-v1", "-w"], capture_output=True, timeout=8, check=True)
    credentials = json.loads(secret.stdout)
    if credentials["siteURL"].rstrip("/") != ORIGIN:
        raise ValueError("configured private origin differs")
    opener = urllib.request.build_opener(NoRedirect())

    def post(path, body):
        request = urllib.request.Request(ORIGIN + "/api/" + path, encode(body), {
            "Content-Type": "application/json", "OAI-Sites-Authorization": "Bearer " + credentials["platformToken"],
            "Authorization": "Bearer " + credentials["deviceToken"]}, method="POST")
        with opener.open(request, timeout=15) as response:
            return json.load(response)

    args.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(args.state_dir, 0o700)
    # Keep this tiny publisher from concurrently spending its own sequence IDs.
    with (args.state_dir / "pool.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        path = args.state_dir / "pool-state.json"
        state = json.loads(path.read_text()) if path.exists() else {"nextSequence": 1, "pending": []}
        if state.get("deviceId", credentials["deviceId"]) != credentials["deviceId"]:
            raise ValueError("prototype device changed; keep previous queue")
        state["deviceId"] = credentials["deviceId"]
        latest = post("pool/read", {"deviceId": credentials["deviceId"], "limit": 1})
        if latest.get("snapshotEventId") and not latest["snapshotEventId"].startswith(PREFIX):
            print('{"status":"native-reader-took-over"}')
            return

        def enqueue(source, value, valid_seconds):
            timestamp = dt.datetime.now(dt.timezone.utc)
            observation = {"schemaVersion": 1, "eventId": PREFIX + str(uuid.uuid4()), "source": source,
                           "sequence": state["nextSequence"], "observedAt": timestamp.isoformat(),
                           "expiresAt": (timestamp + dt.timedelta(seconds=valid_seconds)).isoformat(), "assertion": "observed", "value": value}
            state["nextSequence"] += 1
            state["pending"].append(observation)
            return observation["eventId"]

        # Finish a previous immutable batch first; network failures keep it local.
        if not state["pending"]:
            content_hash = digest(pool)
            cache = state.get("cache")
            if not cache or cache["contentHash"] != content_hash:
                ids = [enqueue("bc.pool.chunk", {"formatVersion": 1, "contentHash": content_hash, "index": index,
                        "bytes": base64.b64encode(pool[start:start + 30720]).decode()}, 365 * 86400)
                       for index, start in enumerate(range(0, len(pool), 30720))]
                cache = {"formatVersion": 1, "authority": "swiftdata", "availability": "available", "contentHash": content_hash,
                         "recordCount": count, "chunkEventIds": ids, "reader": "mac-sqlite-prototype-163"}
                state["cache"] = cache
            enqueue("bc.pool", cache, 180)
            # The forthcoming native App uses its existing much larger sequence.
            # Do not consume or modify that App's queue, nor obstruct takeover.
            if state["nextSequence"] >= native_queue["nextSequence"]:
                raise ValueError("prototype sequence reached native queue; stop publisher")
            write_state(path, state)
        while state["pending"]:
            batch = state["pending"][:4]
            result = post("pool/upload", {"observations": batch})
            accepted = set(result.get("accepted", []) + result.get("ignored", []))
            if not all(r["eventId"] in accepted for r in batch):
                raise ValueError("upload not confirmed")
            state["pending"] = state["pending"][len(batch):]
            write_state(path, state)
        post("flush", {})
        print(json.dumps({"status": "published", "recordCount": count, "stageCount": stage_count, "readAt": dt.datetime.now(dt.timezone.utc).isoformat()}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--store", type=Path, default=SUPPORT / "default.store")
    parser.add_argument("--state-dir", type=Path, default=STATE_DIR)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--watch", action="store_true", help="Current-session prototype; repeats every minute until stopped")
    args = parser.parse_args()
    while True:
        failed = False
        try:
            run(args)
        except Exception as error:
            # Never print credentials, request headers, record content or response bodies.
            detail = str(error) if isinstance(error, (sqlite3.Error, ValueError)) else None
            print(json.dumps({"status": "error", "category": type(error).__name__, "reason": detail,
                              "retryNextMinute": args.watch}), flush=True)
            failed = True
        if not args.watch:
            raise SystemExit(1 if failed else 0)
        time.sleep(60)
