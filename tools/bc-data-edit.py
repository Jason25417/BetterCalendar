#!/usr/bin/env python3
"""Prepare one conditional developer edit from a BetterCalendar archive; never opens SQLite."""
import argparse
import json
import os
from pathlib import Path
import time
import uuid


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("archive", type=Path)
    p.add_argument("--entity", required=True, help="e.g. LongTask, PlanBlock, JournalEntry")
    selector = p.add_mutually_exclusive_group(required=True)
    selector.add_argument("--id", help="business UUID; refuses ambiguous planned/actual or duplicate rows")
    selector.add_argument("--key", help="opaque row key copied from the archive")
    p.add_argument("--field", required=True)
    p.add_argument("--value", required=True, help="JSON value: a quoted string, number, true/false, or null")
    p.add_argument("--output", type=Path, required=True, help="request.json in the enabled developer folder")
    args = p.parse_args()
    archive = json.loads(args.archive.read_text())["archive"]
    if archive["formatVersion"] != 1:
        p.error("unsupported archive version")
    matches = [r for r in archive["records"] if r["entity"] == args.entity and (
        r["key"] == args.key if args.key else str(r["values"].get("id", "")).lower() == args.id.lower())]
    if len(matches) != 1:
        p.error(f"expected exactly one row, found {len(matches)}; use --key for an unambiguous row")
    record = matches[0]
    if args.field not in record["values"]:
        p.error("unknown field")
    replacement = dict(record["values"])
    replacement[args.field] = json.loads(args.value)
    if "modifiedAt" in replacement and args.field != "modifiedAt":
        replacement["modifiedAt"] = time.time() * 1000
    request = {"formatVersion": 1, "requestID": str(uuid.uuid4()), "edits": [
        {"key": record["key"], "expected": record["values"], "replacement": replacement}
    ]}
    # Do not overwrite a request which the app has not consumed yet.
    if args.output.exists():
        p.error("output already exists; inspect its receipt before submitting another request")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_name(f".{args.output.name}.{uuid.uuid4()}.tmp")
    try:
        with temporary.open("x") as f:
            json.dump(request, f, ensure_ascii=False, indent=2)
            f.flush()
            os.fsync(f.fileno())
        # link is atomic and fails rather than overwriting an unconsumed request.
        os.link(temporary, args.output)
    finally:
        temporary.unlink(missing_ok=True)
    print(f"Prepared {request['requestID']}; inspect receipt.json for the app's outcome.")


if __name__ == "__main__":
    main()
