#!/usr/bin/env python3
"""W13：生成可导入 iPhone 的快捷指令（设备活动记录：App 打开 / 关闭），并用 macOS `shortcuts sign` 签名。

两种产物：
1. 通用版（不带触发器，随 App 打包，iPhone 设置引导里一键分享导入；自动化要 Jason 在快捷指令里手建）：
     python3 scripts/make-activity-shortcuts.py
   输出 BetterCalendar/ActivityShortcuts/：
     BetterCalendar 记录 App 打开 = 获取当前 App → 「记录 App 打开」（App = 当前 App）
     BetterCalendar 记录 App 关闭 = 等待 2 秒 → 获取当前 App → 「记录 App 关闭」（现在前台的 App = 当前 App）
2. 自动化版（带「App 已打开 / 已关闭」触发器、App 名单已填好；含 Jason 的装机清单 = 个人数据，**不进仓库、不进 App 包**）：
     python3 scripts/make-activity-shortcuts.py --apps apps.json --out ~/Desktop/BetterCalendar-自动化
   apps.json 来自 `xcrun devicectl device info apps --device <iPhone> --include-all-apps --json-output apps.json`
   （或一行一个 `bundle.id<TAB>名字<TAB>TEAMID` 的文本）。再加 `--harvest-shortcuts-db` 可从本机快捷指令库
   已有的 App 触发器里补 TeamIdentifier。

触发器格式（2026-10-18 从 Jason 自己的自动化「App 4」= 打开游戏模式 v10.1 的 ZUNIFIEDTRIGGER.ZDATA 解出，不是猜的）：
   {WFTriggerIdentifier: "WFAppInFocusTrigger", WFTriggerUUID, WFTriggerSerializedParameters: {
      WFAppState: "opened" | "closed", WFSelectedApps: [{BundleIdentifier, Name, TeamIdentifier}] }}
快捷指令文件格式本身有 `WFWorkflowTriggers`（WorkflowKit 的记录键，同一处还列着 WFTriggerIdentifier / WFTriggerUUID /
WFTriggerSerializedParameters / WFTriggerMinimumClientVersion），所以触发器可以写进 .shortcut 文件。
⚠️ 导入后是否真的建成自动化，只能在 iPhone 上验证（Mac 不支持 App 触发器，没法在这里试）。

App Intent 动作的写法照快捷指令库里第三方 App Intent 的现成结构：
  WFWorkflowActionIdentifier = <bundle id>.<Intent 类型名>，参数键 = Swift 属性名，
  AppIntentDescriptor = {TeamIdentifier, BundleIdentifier, Name, AppIntentIdentifier}。
改了 Intent 类型名 / 参数名 / team id 就重跑本脚本。签名需要登录 iCloud（Apple 签名服务）；失败时保留未签名的
.unsigned.shortcut 并非零退出。自测：python3 -m unittest scripts/test_make_activity_shortcuts.py
"""
import argparse, json, os, plistlib, sqlite3, subprocess, sys, tempfile, uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "BetterCalendar", "ActivityShortcuts")   # 在 App 包里：iPhone 设置引导可一键分享给「快捷指令」导入
BUNDLE, TEAM, APP = "com.jason.BetterCalendar", "D2KWHV599Z", "BetterCalendar"
# 自动化版默认不监听的 App：自己、快捷指令本身（避免自激）。
EXCLUDED_BUNDLES = {BUNDLE, "com.apple.shortcuts"}


def uid(tag):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "bettercalendar-w13-" + tag)).upper()


def get_current_app(tag):
    return {"WFWorkflowActionIdentifier": "is.workflow.actions.getcurrentapp",
            "WFWorkflowActionParameters": {"UUID": uid(tag), "WFVisibleAppScope": "Current", "CustomOutputName": "当前 App"}}


def intent(name, app_output_tag):
    token = {"Value": {"string": "￼", "attachmentsByRange": {
                "{0, 1}": {"OutputUUID": uid(app_output_tag), "Type": "ActionOutput", "OutputName": "当前 App"}}},
             "WFSerializationType": "WFTextTokenString"}
    return {"WFWorkflowActionIdentifier": f"{BUNDLE}.{name}",
            "WFWorkflowActionParameters": {"UUID": uid(name), "ShowWhenRun": False, "appName": token,
                                           "AppIntentDescriptor": {"TeamIdentifier": TEAM, "BundleIdentifier": BUNDLE,
                                                                   "Name": APP, "AppIntentIdentifier": name}}}


def comment(text):
    return {"WFWorkflowActionIdentifier": "is.workflow.actions.comment",
            "WFWorkflowActionParameters": {"WFCommentActionText": text}}


def delay(seconds):
    return {"WFWorkflowActionIdentifier": "is.workflow.actions.delay", "WFWorkflowActionParameters": {"WFDelayTime": float(seconds)}}


def workflow(actions, color, glyph, triggers=None):
    wf = {"WFWorkflowActions": actions, "WFWorkflowClientVersion": "3218.0.4", "WFWorkflowMinimumClientVersion": 900,
          "WFWorkflowMinimumClientVersionString": "900", "WFWorkflowIcon": {"WFWorkflowIconStartColor": color, "WFWorkflowIconGlyphNumber": glyph},
          "WFWorkflowImportQuestions": [], "WFWorkflowTypes": [], "WFQuickActionSurfaces": [],
          "WFWorkflowInputContentItemClasses": ["WFAppContentItem", "WFStringContentItem"],
          "WFWorkflowOutputContentItemClasses": [], "WFWorkflowHasOutputFallback": False, "WFWorkflowHasShortcutInputVariables": False}
    if triggers:
        wf["WFWorkflowTriggers"] = triggers
    return wf


def app_trigger(state, apps, tag):
    """「App 已打开 / 已关闭」触发器，形状与 Jason 库里的一致；TeamIdentifier 不知道时省略（库里的条目都有，未验证省略是否被接受）。"""
    assert state in ("opened", "closed")
    selected = []
    for a in apps:
        entry = {"BundleIdentifier": a["bundle"], "Name": a.get("name") or a["bundle"]}
        if a.get("team"):
            entry["TeamIdentifier"] = a["team"]
        selected.append(entry)
    return {"WFTriggerIdentifier": "WFAppInFocusTrigger", "WFTriggerUUID": uid("trigger-" + tag),
            "WFTriggerSerializedParameters": {"WFAppState": state, "WFSelectedApps": selected}}


OPEN_ACTIONS = lambda: [
    comment("BetterCalendar 设备活动记录（实验）：在「App 已打开（选全部 App）」自动化里运行本快捷指令。"
            "记下前台是哪个 App，经 iCloud 汇到 Mac 给智能体当情境。BetterCalendar 设置里可暂停/关闭。"),
    get_current_app("open-app"),
    intent("RecordAppOpenedIntent", "open-app"),
]
CLOSE_ACTIONS = lambda: [
    comment("BetterCalendar 设备活动记录（实验）：在「App 已关闭（选全部 App）」自动化里运行本快捷指令。"
            "先等 2 秒让前台稳定，再看现在前台是哪个 App：和刚才打开的相同 = 只是控制中心/通知盖了一层，不算关闭。"),
    delay(2),
    get_current_app("close-app"),
    intent("RecordAppClosedIntent", "close-app"),
]
OPEN_COLOR, CLOSE_COLOR, GLYPH = 4282601983, 4251333119, 61440


def generic_shortcuts():
    return {"BetterCalendar 记录 App 打开": workflow(OPEN_ACTIONS(), OPEN_COLOR, GLYPH),
            "BetterCalendar 记录 App 关闭": workflow(CLOSE_ACTIONS(), CLOSE_COLOR, GLYPH)}


def automation_shortcuts(apps):
    return {"BetterCalendar 自动记录 App 打开": workflow(OPEN_ACTIONS(), OPEN_COLOR, GLYPH, [app_trigger("opened", apps, "opened")]),
            "BetterCalendar 自动记录 App 关闭": workflow(CLOSE_ACTIONS(), CLOSE_COLOR, GLYPH, [app_trigger("closed", apps, "closed")])}


# —— App 名单 ——

def parse_apps(text, include_apple=False):
    """devicectl 的 --json-output（result.apps[]）或文本（每行 bundle<TAB>名字<TAB>TEAMID，# 开头是注释）→ [{bundle, name, team}]。
    过滤：App Clip、隐藏、内部 App、自己、快捷指令；com.apple.* 默认不要（系统 App 太多、多数不值得记），--include-apple 保留可删除的那些。"""
    text = text.strip()
    rows = []
    if text.startswith("{") or text.startswith("["):
        data = json.loads(text)
        items = data.get("result", {}).get("apps") if isinstance(data, dict) else data
        if items is None:
            items = data.get("apps", []) if isinstance(data, dict) else []
        for it in items:
            if not isinstance(it, dict) or not it.get("bundleIdentifier"):
                continue
            if it.get("appClip") or it.get("hidden") or it.get("internalApp"):
                continue
            rows.append({"bundle": it["bundleIdentifier"], "name": it.get("name") or it["bundleIdentifier"],
                         "team": it.get("teamIdentifier"), "removable": it.get("removable", True)})
    else:
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split("\t")]
            rows.append({"bundle": parts[0], "name": parts[1] if len(parts) > 1 and parts[1] else parts[0],
                         "team": parts[2] if len(parts) > 2 and parts[2] else None, "removable": True})
    out, seen = [], set()
    for r in rows:
        b = r["bundle"]
        if b in seen or b in EXCLUDED_BUNDLES:
            continue
        if b.startswith("com.apple.") and not (include_apple and r.get("removable")):
            continue
        seen.add(b)
        out.append({"bundle": b, "name": r["name"], "team": r.get("team")})
    out.sort(key=lambda a: a["name"].lower())
    return out


def harvest_shortcuts_db(db_path=os.path.expanduser("~/Library/Shortcuts/Shortcuts.sqlite")):
    """本机快捷指令库里已有的 App 触发器 → {bundle: {name, team}}（拷到临时目录再读，库可能被占用）。"""
    found = {}
    if not os.path.exists(db_path):
        return found
    with tempfile.TemporaryDirectory() as tmp:
        dst = os.path.join(tmp, "Shortcuts.sqlite")
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(db_path + suffix):
                with open(db_path + suffix, "rb") as src, open(dst + suffix, "wb") as out:
                    out.write(src.read())
        db = sqlite3.connect(f"file:{dst}?mode=ro", uri=True)
        for (data,) in db.execute("select ZDATA from ZUNIFIEDTRIGGER where ZDATA is not null"):
            try:
                d = plistlib.loads(data)
            except Exception:
                continue
            if d.get("WFTriggerIdentifier") != "WFAppInFocusTrigger":
                continue
            for a in d.get("WFTriggerSerializedParameters", {}).get("WFSelectedApps", []):
                if a.get("BundleIdentifier"):
                    found[a["BundleIdentifier"]] = {"name": a.get("Name"), "team": a.get("TeamIdentifier")}
        db.close()
    return found


def enrich(apps, known):
    for a in apps:
        k = known.get(a["bundle"])
        if k:
            a["team"] = a.get("team") or k.get("team")
            a["name"] = a.get("name") or k.get("name")
    return apps


# —— 写文件 + 签名 ——

def write_and_sign(shortcuts, out_dir, sign=True):
    os.makedirs(out_dir, exist_ok=True)
    ok = True
    for name, wf in shortcuts.items():
        unsigned = os.path.join(out_dir, f"{name}.unsigned.shortcut")
        signed = os.path.join(out_dir, f"{name}.shortcut")
        with open(unsigned, "wb") as f:
            plistlib.dump(wf, f, fmt=plistlib.FMT_BINARY)
        if not sign:
            print(f"unsigned: {unsigned}")
            continue
        r = None
        for _ in range(3):   # 签名服务偶尔回「The file doesn't exist」，重试即好（2026-10-18 实测）
            r = subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", unsigned, "--output", signed],
                               capture_output=True, text=True)
            if r.returncode == 0 and os.path.exists(signed):
                break
        if r.returncode == 0 and os.path.exists(signed) and os.path.getsize(signed) > 0:
            os.remove(unsigned)
            os.chmod(signed, 0o644)
            print(f"signed: {signed} ({os.path.getsize(signed)} bytes)")
        else:
            ok = False
            print(f"SIGN FAILED for {name}: {r.stderr.strip() or r.stdout.strip()}", file=sys.stderr)
    return ok


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--apps", help="App 名单：devicectl 的 JSON 或文本（有它 = 生成带触发器的自动化版）")
    p.add_argument("--out", help="输出目录（自动化版必填，别放进仓库；通用版默认 BetterCalendar/ActivityShortcuts/）")
    p.add_argument("--include-apple", action="store_true", help="保留可删除的苹果自带 App（默认全部不要）")
    p.add_argument("--harvest-shortcuts-db", action="store_true", help="从本机快捷指令库已有的 App 触发器里补 TeamIdentifier / 名字")
    p.add_argument("--no-sign", action="store_true", help="只写未签名文件（调试）")
    a = p.parse_args(argv)
    if a.apps:
        if not a.out:
            p.error("自动化版含你的装机清单，必须用 --out 指定仓库外的目录")
        with open(a.apps, encoding="utf-8") as f:
            apps = parse_apps(f.read(), include_apple=a.include_apple)
        if a.harvest_shortcuts_db:
            apps = enrich(apps, harvest_shortcuts_db())
        if not apps:
            print("名单里没有可用的 App", file=sys.stderr)
            return 1
        missing = [x["bundle"] for x in apps if not x.get("team")]
        print(f"{len(apps)} 个 App 进触发器；{len(missing)} 个没有 TeamIdentifier（已省略该键）")
        os.makedirs(a.out, exist_ok=True)
        with open(os.path.join(a.out, "apps-used.txt"), "w", encoding="utf-8") as f:   # 实际进了触发器的名单，便于核对
            for x in apps:
                f.write(f"{x['bundle']}\t{x['name']}\t{x.get('team') or ''}\n")
        return 0 if write_and_sign(automation_shortcuts(apps), a.out, sign=not a.no_sign) else 1
    return 0 if write_and_sign(generic_shortcuts(), a.out or OUT, sign=not a.no_sign) else 1


if __name__ == "__main__":
    sys.exit(main())
