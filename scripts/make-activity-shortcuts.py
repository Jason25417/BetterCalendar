#!/usr/bin/env python3
"""W13：生成两个可导入 iPhone 的快捷指令（设备活动记录：App 打开 / 关闭），并用 macOS `shortcuts sign` 签名。

  BetterCalendar 记录 App 打开 = 获取当前 App → 「记录 App 打开」（App = 当前 App）
  BetterCalendar 记录 App 关闭 = 等待 2 秒 → 获取当前 App → 「记录 App 关闭」（现在前台的 App = 当前 App）

做法来自 Jason 的「打开/关闭游戏模式 v10.1」（is.workflow.actions.getcurrentapp，WFVisibleAppScope=Current；
关闭后等 2 秒再比较，区分「控制中心/通知盖了一层」与真关闭）。比较与状态在 BetterCalendar 里（PhoneAppSession），不用 Data Jar。

App Intent 动作的写法照快捷指令库里第三方 App Intent 的现成结构：
  WFWorkflowActionIdentifier = <bundle id>.<Intent 类型名>，参数键 = Swift 属性名，
  AppIntentDescriptor = {TeamIdentifier, BundleIdentifier, Name, AppIntentIdentifier}。
改了 Intent 类型名 / 参数名 / team id 就重跑本脚本：
  python3 scripts/make-activity-shortcuts.py          # 输出到 BetterCalendar/ActivityShortcuts/（已签名，「任何人」模式；随 App 打包）
签名需要登录 iCloud（Apple 签名服务）；失败时保留未签名的 .unsigned.shortcut 并非零退出。
"""
import os, plistlib, subprocess, sys, uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "BetterCalendar", "ActivityShortcuts")   # 在 App 包里：iPhone 设置引导可一键分享给「快捷指令」导入
BUNDLE, TEAM, APP = "com.jason.BetterCalendar", "D2KWHV599Z", "BetterCalendar"


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


def workflow(actions, color, glyph):
    return {"WFWorkflowActions": actions, "WFWorkflowClientVersion": "3218.0.4", "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900", "WFWorkflowIcon": {"WFWorkflowIconStartColor": color, "WFWorkflowIconGlyphNumber": glyph},
            "WFWorkflowImportQuestions": [], "WFWorkflowTypes": [], "WFQuickActionSurfaces": [],
            "WFWorkflowInputContentItemClasses": ["WFAppContentItem", "WFStringContentItem"],
            "WFWorkflowOutputContentItemClasses": [], "WFWorkflowHasOutputFallback": False, "WFWorkflowHasShortcutInputVariables": False}


SHORTCUTS = {
    "BetterCalendar 记录 App 打开": workflow([
        comment("BetterCalendar 设备活动记录（实验）：在「App 已打开（选全部 App）」自动化里运行本快捷指令。"
                "记下前台是哪个 App，经 iCloud 汇到 Mac 给智能体当情境。BetterCalendar 设置里可暂停/关闭。"),
        get_current_app("open-app"),
        intent("RecordAppOpenedIntent", "open-app"),
    ], 4282601983, 61440),
    "BetterCalendar 记录 App 关闭": workflow([
        comment("BetterCalendar 设备活动记录（实验）：在「App 已关闭（选全部 App）」自动化里运行本快捷指令。"
                "先等 2 秒让前台稳定，再看现在前台是哪个 App：和刚才打开的相同 = 只是控制中心/通知盖了一层，不算关闭。"),
        {"WFWorkflowActionIdentifier": "is.workflow.actions.delay", "WFWorkflowActionParameters": {"WFDelayTime": 2.0}},
        get_current_app("close-app"),
        intent("RecordAppClosedIntent", "close-app"),
    ], 4251333119, 61440),
}


def main():
    os.makedirs(OUT, exist_ok=True)
    ok = True
    for name, wf in SHORTCUTS.items():
        unsigned = os.path.join(OUT, f"{name}.unsigned.shortcut")
        signed = os.path.join(OUT, f"{name}.shortcut")
        with open(unsigned, "wb") as f:
            plistlib.dump(wf, f, fmt=plistlib.FMT_BINARY)
        for _ in range(3):   # 签名服务偶尔回「The file doesn't exist」，重试即好（2026-10-18 实测）
            r = subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", unsigned, "--output", signed],
                               capture_output=True, text=True)
            if r.returncode == 0 and os.path.exists(signed):
                break
        if r.returncode == 0 and os.path.exists(signed) and os.path.getsize(signed) > 0:
            os.remove(unsigned)
            print(f"signed: {signed} ({os.path.getsize(signed)} bytes)")
        else:
            ok = False
            print(f"SIGN FAILED for {name}: {r.stderr.strip() or r.stdout.strip()}", file=sys.stderr)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
