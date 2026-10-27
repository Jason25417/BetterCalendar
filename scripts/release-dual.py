#!/usr/bin/env python3
"""BetterCalendar 发版脚本（自 Codex /private/tmp/bc-release-dual.py 收编，2026-10-17；W17 加通道与发版纪律，2026-10-19）。

两个通道（见 BetterCalendar/App/AppChannel.swift）：
  日用版 --channel daily（默认）：双端串行 archive + 上传 TestFlight。发版纪律（Jason 2026-10-19 定）：
    · 每周 1–2 次、晚上发；每次带一句话说明「改了什么 / 你要做什么」（--note，必填）；回滚 = TestFlight 里装上一个 build。
    · 发版前自动检查（任何一项不过就不发，什么都不会上传）：
        ① 数据快照：Mac 日用版 24 小时内导出过完整数据档案（App 每天自动存到容器 Application Support/BetterCalendar/Data/auto/，
           或设置 → 开发者选项 → 「导出完整数据档案」）。快照只在本机，脚本只读它、不上传。
        ② CloudKit schema 只加不改（scripts/cloudkit_schema_check.py，只读 export-schema）：Development 有而 Production
           没有的要先 Deploy；上次发版后删/改名的 @Model 属性一律拒绝。
    · 上传成功后打本地 git 标签 release/<build>（不推送），作为下次「只加不改」检查的基准。
  Dev 版 --channel dev：不上传（Dev 版钉在 CloudKit Development 环境，TestFlight 不收）。本机开发签名构建 scheme
    「BetterCalendar Dev」；--install 时装到 /Applications/BetterCalendar Dev.app；--ios-device <UDID> 时装到已配对的 iPhone。

用法：
  python3 scripts/release-dual.py --build 188 --note "改了什么：…；你要做什么：无"     # 日用版
  python3 scripts/release-dual.py --build 188 --preflight-only                       # 只做发版前检查（不构建）
  python3 scripts/release-dual.py --channel dev --install [--ios-device <UDID>]      # Dev 版
状态写 /private/tmp/bc-release-<号>/status.json。发版一律用正式版 Xcode（DEVELOPER_DIR 固定为 /Applications/Xcode.app），
beta 产物会被 Apple 拒收。"""
import argparse, datetime, json, os, plistlib, shutil, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STABLE_XCODE = '/Applications/Xcode.app/Contents/Developer'
DAILY_BUNDLE = 'com.jason.BetterCalendar'
DEV_BUNDLE = 'com.jason.BetterCalendar.dev'
# 0.79.1 起：日用版容器里的 Application Support/BetterCalendar/Data（与 DataMaintenance.directory 一致；以前是 ~/Downloads/BetterCalendar-Data）
SNAPSHOT_DIR = Path.home() / 'Library' / 'Containers' / DAILY_BUNDLE / 'Data' / 'Library' / 'Application Support' / 'BetterCalendar' / 'Data'
SNAPSHOT_MAX_AGE_H = 24
AUTH = ['-allowProvisioningUpdates', '-authenticationKeyPath', str(Path.home() / '.appstoreconnect/private_keys/AuthKey_MFLQ74N9N7.p8'),
        '-authenticationKeyID', 'MFLQ74N9N7', '-authenticationKeyIssuerID', 'f6b800c3-7e46-4bbb-914e-4c8ca018e8f1']

NOTE_TEMPLATE = '''一句话发版说明模板（会写进 TestFlight「测试内容」，Jason 一眼看懂）：
  改了什么：<一句话，用户看得到的变化；新功能注明「默认关，设置里打开」>；你要做什么：<无 / 打开 Mac App 一次 / 在设置里打开「…」>
例：
  --note "改了什么：日历同步更稳，拖动事件不再偶尔跳回；你要做什么：无"
  --note "改了什么：新增「晚间复盘」（默认关）；你要做什么：想试就在设置 → 智能体里打开"'''


def fail(msg: str):
    print('\n❌ ' + msg, flush=True)
    raise SystemExit(1)


# ---------- 日用版发版前检查 ----------

def newest_snapshot():
    """最新的完整数据档案（自动快照 auto/auto-*.json 或手动导出的 snapshot-*.json），返回 (路径, 小时数, 记录数) 或 None。"""
    files = list((SNAPSHOT_DIR / 'auto').glob('auto-*.json')) + list(SNAPSHOT_DIR.glob('snapshot-*.json'))
    for f in sorted(files, key=lambda p: p.stat().st_mtime, reverse=True):
        try:
            sealed = json.loads(f.read_text())
            archive = sealed['archive']
            assert isinstance(sealed.get('sha256'), str) and isinstance(archive.get('records'), list)
        except Exception:  # noqa: BLE001 — 坏档案不算数，接着看更早的
            print(f'  ⚠️ 跳过读不出的档案 {f.name}')
            continue
        return f, (time.time() - f.stat().st_mtime) / 3600, len(archive['records'])
    return None


def snapshot_guard(allow_stale: bool):
    found = newest_snapshot()
    if found and found[1] <= SNAPSHOT_MAX_AGE_H and found[2] > 0:
        print(f'  ✅ 数据快照：{found[0].name}（{found[1]:.1f} 小时前，{found[2]} 条记录；只在本机）')
        return
    why = (f'最新档案 {found[0].name} 是 {found[1]:.1f} 小时前的（{found[2]} 条记录）' if found
           else f'{SNAPSHOT_DIR} 里没有任何完整数据档案')
    help_text = (f'{why}。发日用版前必须有 {SNAPSHOT_MAX_AGE_H} 小时内的快照：\n'
                 '    打开 Mac 上的 BetterCalendar（日用版）→ 设置 → 开发者选项 → 「导出完整数据档案」，\n'
                 f'    或保持 App 开着等它每天自动存一份（{SNAPSHOT_DIR}/auto/）。然后重跑本命令。')
    if allow_stale:
        print('  ⚠️ ' + help_text + '\n  ⚠️ 已按 --allow-stale-snapshot 继续（只在 Jason 明确同意时用）')
        return
    fail(help_text)


def schema_guard(skip: bool):
    if skip:
        print('  ⚠️ 已按 --skip-schema-check 跳过 CloudKit schema 检查（只在 Jason 明确同意时用）')
        return
    sys.path.insert(0, str(ROOT / 'scripts'))
    import cloudkit_schema_check
    code = cloudkit_schema_check.run()
    if code == 1:
        fail('CloudKit schema 检查有阻断问题（见上）。需要 Deploy 的请 Jason 在 CloudKit 后台 Deploy 后重跑。')
    if code == 2:
        fail('CloudKit schema 检查没能完成（见上）；确认网络与 cktool 令牌后重跑，或 Jason 明确同意时加 --skip-schema-check。')


def daily_preflight(args):
    print(f'发版前检查（日用版 build {args.build}）', flush=True)
    hour = datetime.datetime.now().hour
    if not (hour >= 21 or hour < 5):
        print(f'  ⚠️ 现在 {hour} 点：日用版约定晚上发（21:00 之后），白天发会打断 Jason 正在用的 App。')
    snapshot_guard(args.allow_stale_snapshot)
    schema_guard(args.skip_schema_check)
    if args.preflight_only:
        return
    if not args.note or not args.note.strip():
        fail('缺少一句话发版说明 --note。\n' + NOTE_TEMPLATE)
    print(f'  ✅ 发版说明：{args.note.strip()}')


# ---------- 构建 ----------

def git(*a):
    return subprocess.check_output(['git', *a], cwd=ROOT, text=True).strip()


def run_daily(args):
    out = Path(f'/private/tmp/bc-release-{args.build}'); out.mkdir(exist_ok=True)
    status_path = out / 'status.json'
    if status_path.exists():
        raise SystemExit('Existing release state retained; inspect ASC and live process before retrying.')
    source = git('rev-parse', 'HEAD')
    if git('status', '--porcelain'):
        raise SystemExit('Release requires a clean, committed source checkout.')
    notes = out / 'notes.txt'; notes.write_text(args.note.strip() + '\n')
    env = dict(os.environ, DEVELOPER_DIR=STABLE_XCODE)
    state = {'build': args.build, 'channel': 'daily', 'sourceCommit': source, 'pid': os.getpid(), 'stage': 'starting',
             'note': args.note.strip(), 'platforms': {}}

    def persist(stage):
        state['stage'] = stage; state['updatedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        tmp = status_path.with_suffix('.tmp'); tmp.write_text(json.dumps(state, indent=2, ensure_ascii=False) + '\n'); tmp.replace(status_path)
        print(stage, flush=True)

    options = out / 'exportOptions.plist'
    with options.open('wb') as f:
        plistlib.dump({'destination': 'upload', 'method': 'app-store-connect', 'teamID': 'D2KWHV599Z', 'signingStyle': 'automatic',
                       'uploadSymbols': True, 'manageAppVersionAndBuildNumber': False}, f)
    try:
        for label, destination in [('macOS', 'generic/platform=macOS'), ('iOS', 'generic/platform=iOS')]:
            archive = out / (label + '.xcarchive'); log = out / (label + '-archive.log')
            persist(label + '-archive')
            with log.open('wb') as f:
                p = subprocess.run(['xcodebuild', '-project', 'BetterCalendar.xcodeproj', '-scheme', 'BetterCalendar', '-configuration', 'Release',
                                    '-destination', destination, '-archivePath', str(archive), '-derivedDataPath', str(out / 'DerivedData'), *AUTH, 'archive'],
                                   cwd=ROOT, env=env, stdout=f, stderr=subprocess.STDOUT)
            if p.returncode: raise RuntimeError(label + ' archive failed; see ' + str(log))
            with (archive / 'Info.plist').open('rb') as f: info = plistlib.load(f)
            props = info['ApplicationProperties']
            if str(props.get('CFBundleVersion')) != str(args.build) or props.get('CFBundleIdentifier') != DAILY_BUNDLE:
                raise RuntimeError('Archive identity/version mismatch; upload not attempted.')
            state['platforms'][label] = {'archive': str(archive), 'version': props.get('CFBundleShortVersionString'),
                                         'build': props.get('CFBundleVersion'), 'archiveSucceeded': True}
            persist(label + '-upload')
            log = out / (label + '-upload.log')
            with log.open('wb') as f:
                p = subprocess.run(['xcodebuild', '-exportArchive', '-archivePath', str(archive), '-exportPath', str(out / (label + '-export')),
                                    '-exportOptionsPlist', str(options), *AUTH], cwd=ROOT, env=env, stdout=f, stderr=subprocess.STDOUT)
            if p.returncode: raise RuntimeError(label + ' upload uncertain/failed; query ASC before retrying. See ' + str(log))
            state['platforms'][label]['exportSucceeded'] = True
            persist(label + '-uploaded')
        persist('uploaded-both')
    except Exception as e:
        state['failure'] = str(e); persist('failed'); raise
    tag = f'release/{args.build}'
    if subprocess.run(['git', 'tag', tag, source], cwd=ROOT).returncode == 0:
        print(f'已打本地标签 {tag}（不推送；下次「只加不改」检查以它为基准）')
    print(f'\n下一步：Apple 处理完（几分钟）后写入发版说明：node scripts/asc-build.mjs {args.build} {notes}')


def run_dev(args):
    out = Path('/private/tmp/bc-dev-build'); out.mkdir(exist_ok=True)
    print('Dev 版：本机开发签名构建（不上传；CloudKit Development 环境）', flush=True)
    log = out / 'build.log'
    with log.open('wb') as f:
        p = subprocess.run(['xcodebuild', '-project', 'BetterCalendar.xcodeproj', '-scheme', 'BetterCalendar Dev', '-configuration', 'Dev',
                            '-destination', 'generic/platform=macOS', '-derivedDataPath', str(out / 'DerivedData'), '-allowProvisioningUpdates', 'build'],
                           cwd=ROOT, stdout=f, stderr=subprocess.STDOUT)
    if p.returncode: fail('Dev 版 Mac 构建失败，见 ' + str(log))
    app = out / 'DerivedData/Build/Products/Dev/BetterCalendar Dev.app'
    with (app / 'Contents/Info.plist').open('rb') as f:
        if plistlib.load(f).get('CFBundleIdentifier') != DEV_BUNDLE: fail('产物不是 Dev 版（bundle id 不对），没有安装')
    print('  ✅ 构建成功：' + str(app))
    if args.install:
        dest = Path('/Applications/BetterCalendar Dev.app')
        subprocess.run(['osascript', '-e', 'tell application id "com.jason.BetterCalendar.dev" to quit'], capture_output=True)
        if dest.exists(): shutil.rmtree(dest)
        shutil.copytree(app, dest, symlinks=True)
        print('  ✅ 已装到 ' + str(dest) + '（日用版 /Applications/BetterCalendar.app 没动）')
    if args.ios_device:
        with (out / 'build-ios.log').open('wb') as f:
            p = subprocess.run(['xcodebuild', '-project', 'BetterCalendar.xcodeproj', '-scheme', 'BetterCalendar Dev', '-configuration', 'Dev',
                                '-destination', f'id={args.ios_device}', '-derivedDataPath', str(out / 'DerivedData'), '-allowProvisioningUpdates',
                                '-allowProvisioningDeviceRegistration', 'build'],   # 新设备第一次装 Dev 版：自动登记到开发者账号（Jason 2026-10-20 同意）
                               cwd=ROOT, stdout=f, stderr=subprocess.STDOUT)
        if p.returncode: fail('Dev 版 iOS 构建失败，见 ' + str(out / 'build-ios.log'))
        ios_app = out / 'DerivedData/Build/Products/Dev-iphoneos/BetterCalendar Dev.app'
        p = subprocess.run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', args.ios_device, str(ios_app)])
        if p.returncode: fail('装到 iPhone 失败（需要 iPhone「开发者模式」已打开、已与这台 Mac 配对）')
        print('  ✅ 已装到 iPhone')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--channel', choices=['daily', 'dev'], default='daily')
    ap.add_argument('--build', type=int, help='日用版必填：本次 build 号（先跑 scripts/bump-build.sh）')
    ap.add_argument('--note', help='日用版必填：一句话「改了什么 / 你要做什么」')
    ap.add_argument('--preflight-only', action='store_true', help='日用版：只做发版前检查，不构建不上传')
    ap.add_argument('--allow-stale-snapshot', action='store_true', help='（仅 Jason 明确同意时）没有新快照也发')
    ap.add_argument('--skip-schema-check', action='store_true', help='（仅 Jason 明确同意时）跳过 CloudKit schema 检查')
    ap.add_argument('--install', action='store_true', help='Dev 版：装到 /Applications/BetterCalendar Dev.app')
    ap.add_argument('--ios-device', help='Dev 版：装到这台已配对 iPhone（xcrun devicectl list devices 查 UDID）')
    args = ap.parse_args()
    if args.channel == 'dev':
        if args.note or args.preflight_only: print('（Dev 版不上传，--note / --preflight-only 忽略）')
        run_dev(args); return
    if args.build is None: ap.error('日用版需要 --build')
    daily_preflight(args)
    if args.preflight_only:
        print('\n✅ 发版前检查全部通过（--preflight-only：没有构建、没有上传）'); return
    run_daily(args)


if __name__ == '__main__':
    main()
