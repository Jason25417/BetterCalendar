"""W13：快捷指令生成器自测。python3 -m unittest scripts/test_make_activity_shortcuts.py
不签名、不碰仓库里的产物；触发器形状对照 2026-10-18 从 Jason 快捷指令库解出的真实结构。"""
import importlib.util, json, os, plistlib, sqlite3, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("gen", os.path.join(HERE, "make-activity-shortcuts.py"))
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

# Jason 库里真实的触发器（App 4，节选）——生成的必须是同一形状。
REAL_TRIGGER = {"WFTriggerIdentifier": "WFAppInFocusTrigger", "WFTriggerUUID": "02846B3B-C4F4-4355-9729-9D8E343DF78A",
                "WFTriggerSerializedParameters": {"WFAppState": "opened", "WFSelectedApps": [
                    {"BundleIdentifier": "com.HoYoverse.Nap", "Name": "绝区零", "TeamIdentifier": "5JG79VMBAP"}]}}

DEVICECTL_JSON = json.dumps({"info": {"outcome": "success"}, "result": {"apps": [
    {"bundleIdentifier": "com.tencent.xin", "name": "微信", "removable": True, "appClip": False, "hidden": False, "internalApp": False},
    {"bundleIdentifier": "com.apple.mobilenotes", "name": "备忘录", "removable": False},
    {"bundleIdentifier": "com.apple.podcasts", "name": "播客", "removable": True},
    {"bundleIdentifier": "com.jason.BetterCalendar", "name": "BetterCalendar", "removable": True},
    {"bundleIdentifier": "com.apple.shortcuts", "name": "快捷指令", "removable": False},
    {"bundleIdentifier": "com.x.clip", "name": "Clip", "appClip": True},
    {"bundleIdentifier": "com.x.hidden", "name": "H", "hidden": True},
    {"bundleIdentifier": "com.tencent.xin", "name": "微信（重复）"},
    {"bundleIdentifier": "com.HoYoverse.Nap", "name": "绝区零"},
]}})


class GeneratorTests(unittest.TestCase):
    def test_generic_shortcuts_have_no_trigger_and_bind_current_app(self):
        s = gen.generic_shortcuts()
        self.assertEqual(set(s), {"BetterCalendar 记录 App 打开", "BetterCalendar 记录 App 关闭"})
        for wf in s.values():
            self.assertNotIn("WFWorkflowTriggers", wf)
            ids = [a["WFWorkflowActionIdentifier"] for a in wf["WFWorkflowActions"]]
            self.assertIn("is.workflow.actions.getcurrentapp", ids)
            app_action = wf["WFWorkflowActions"][-1]
            self.assertTrue(app_action["WFWorkflowActionIdentifier"].startswith("com.jason.BetterCalendar.RecordApp"))
            cur = next(a for a in wf["WFWorkflowActions"] if a["WFWorkflowActionIdentifier"] == "is.workflow.actions.getcurrentapp")
            self.assertEqual(cur["WFWorkflowActionParameters"]["WFVisibleAppScope"], "Current")
            token = app_action["WFWorkflowActionParameters"]["appName"]
            self.assertEqual(token["Value"]["attachmentsByRange"]["{0, 1}"]["OutputUUID"], cur["WFWorkflowActionParameters"]["UUID"])
            d = app_action["WFWorkflowActionParameters"]["AppIntentDescriptor"]
            self.assertEqual(d, {"TeamIdentifier": "D2KWHV599Z", "BundleIdentifier": "com.jason.BetterCalendar",
                                 "Name": "BetterCalendar", "AppIntentIdentifier": d["AppIntentIdentifier"]})
        close_ids = [a["WFWorkflowActionIdentifier"] for a in s["BetterCalendar 记录 App 关闭"]["WFWorkflowActions"]]
        self.assertLess(close_ids.index("is.workflow.actions.delay"), close_ids.index("is.workflow.actions.getcurrentapp"))

    def test_parse_devicectl_json_filters_and_dedupes(self):
        apps = gen.parse_apps(DEVICECTL_JSON)
        self.assertEqual([a["bundle"] for a in apps], ["com.tencent.xin", "com.HoYoverse.Nap"])   # 按名字排序：微信 / 绝区零
        self.assertEqual(apps[0]["name"], "微信")
        with_apple = gen.parse_apps(DEVICECTL_JSON, include_apple=True)
        self.assertIn("com.apple.podcasts", [a["bundle"] for a in with_apple])        # 可删除的苹果 App 才保留
        self.assertNotIn("com.apple.mobilenotes", [a["bundle"] for a in with_apple])
        self.assertNotIn("com.jason.BetterCalendar", [a["bundle"] for a in with_apple])
        self.assertNotIn("com.apple.shortcuts", [a["bundle"] for a in with_apple])

    def test_parse_text_list(self):
        apps = gen.parse_apps("# 注释\ncom.a.b\tAlpha\tTEAM1\ncom.c.d\n\ncom.a.b\tdup\n")
        self.assertEqual(apps, [{"bundle": "com.a.b", "name": "Alpha", "team": "TEAM1"}, {"bundle": "com.c.d", "name": "com.c.d", "team": None}])

    def test_automation_trigger_matches_real_shape(self):
        apps = gen.enrich(gen.parse_apps(DEVICECTL_JSON), {"com.HoYoverse.Nap": {"name": "绝区零", "team": "5JG79VMBAP"}})
        s = gen.automation_shortcuts(apps)
        self.assertEqual(set(s), {"BetterCalendar 自动记录 App 打开", "BetterCalendar 自动记录 App 关闭"})
        for name, state in (("BetterCalendar 自动记录 App 打开", "opened"), ("BetterCalendar 自动记录 App 关闭", "closed")):
            trig = s[name]["WFWorkflowTriggers"]
            self.assertEqual(len(trig), 1)
            t = trig[0]
            self.assertEqual(set(t), set(REAL_TRIGGER))
            self.assertEqual(t["WFTriggerIdentifier"], REAL_TRIGGER["WFTriggerIdentifier"])
            self.assertEqual(set(t["WFTriggerSerializedParameters"]), set(REAL_TRIGGER["WFTriggerSerializedParameters"]))
            self.assertEqual(t["WFTriggerSerializedParameters"]["WFAppState"], state)
            sel = t["WFTriggerSerializedParameters"]["WFSelectedApps"]
            nap = next(x for x in sel if x["BundleIdentifier"] == "com.HoYoverse.Nap")
            self.assertEqual(nap, REAL_TRIGGER["WFTriggerSerializedParameters"]["WFSelectedApps"][0])
            wx = next(x for x in sel if x["BundleIdentifier"] == "com.tencent.xin")
            self.assertEqual(set(wx), {"BundleIdentifier", "Name"})   # 不知道 team id 就不写
            # 动作与通用版一样（触发器之外不多不少）
            self.assertEqual([a["WFWorkflowActionIdentifier"] for a in s[name]["WFWorkflowActions"]],
                             [a["WFWorkflowActionIdentifier"] for a in gen.generic_shortcuts()[name.replace("自动记录", "记录")]["WFWorkflowActions"]])
        # 两个触发器 UUID 不同、且稳定（重跑不变）
        self.assertNotEqual(s["BetterCalendar 自动记录 App 打开"]["WFWorkflowTriggers"][0]["WFTriggerUUID"],
                            s["BetterCalendar 自动记录 App 关闭"]["WFWorkflowTriggers"][0]["WFTriggerUUID"])
        self.assertEqual(s["BetterCalendar 自动记录 App 打开"]["WFWorkflowTriggers"][0]["WFTriggerUUID"],
                         gen.automation_shortcuts(apps)["BetterCalendar 自动记录 App 打开"]["WFWorkflowTriggers"][0]["WFTriggerUUID"])
        # 能写成二进制 plist 再读回
        data = plistlib.dumps(s["BetterCalendar 自动记录 App 打开"], fmt=plistlib.FMT_BINARY)
        self.assertEqual(plistlib.loads(data)["WFWorkflowTriggers"][0]["WFTriggerSerializedParameters"]["WFAppState"], "opened")

    def test_harvest_from_fixture_db(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = os.path.join(tmp, "Shortcuts.sqlite")
            c = sqlite3.connect(db)
            c.execute("create table ZUNIFIEDTRIGGER(Z_PK integer primary key, ZDATA blob)")
            c.execute("insert into ZUNIFIEDTRIGGER values (1, ?)", (plistlib.dumps(REAL_TRIGGER, fmt=plistlib.FMT_BINARY),))
            c.execute("insert into ZUNIFIEDTRIGGER values (2, ?)", (plistlib.dumps({"WFTriggerIdentifier": "WFTimeTrigger"}, fmt=plistlib.FMT_BINARY),))
            c.execute("insert into ZUNIFIEDTRIGGER values (3, ?)", (b"garbage",))
            c.commit(); c.close()
            found = gen.harvest_shortcuts_db(db)
            self.assertEqual(found, {"com.HoYoverse.Nap": {"name": "绝区零", "team": "5JG79VMBAP"}})
            self.assertEqual(gen.harvest_shortcuts_db(os.path.join(tmp, "none.sqlite")), {})

    def test_cli_writes_unsigned_files_outside_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            apps = os.path.join(tmp, "apps.json"); out = os.path.join(tmp, "out")
            with open(apps, "w") as f:
                f.write(DEVICECTL_JSON)
            self.assertEqual(gen.main(["--apps", apps, "--out", out, "--no-sign"]), 0)
            files = sorted(os.listdir(out))
            self.assertEqual(files, ["BetterCalendar 自动记录 App 关闭.unsigned.shortcut", "BetterCalendar 自动记录 App 打开.unsigned.shortcut", "apps-used.txt"])
            with open(os.path.join(out, files[1]), "rb") as f:
                wf = plistlib.load(f)
            self.assertEqual(len(wf["WFWorkflowTriggers"][0]["WFTriggerSerializedParameters"]["WFSelectedApps"]), 2)
            with self.assertRaises(SystemExit):   # 自动化版必须指定仓库外目录
                gen.main(["--apps", apps, "--no-sign"])


if __name__ == "__main__":
    unittest.main()
