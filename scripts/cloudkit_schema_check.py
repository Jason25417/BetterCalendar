#!/usr/bin/env python3
"""CloudKit schema「只加不改」检查（W17，2026-10-19）。只读：只调用 cktool export-schema，绝不 import / deploy。

为什么：日用版（TestFlight）读写的是 Production 环境；Production 不会自动建新字段，也从不删字段。
  ① Development 有、Production 没有的类型/字段 → 发版前必须由 Jason 在 CloudKit 后台 Deploy，否则新版一写就同步失败（踩过）。
  ② 代码里 @Model 的属性在 Production 没有对应 CD_ 字段 → 一旦写入非空值，那条记录的上传就会失败（潜在同步卡死）。
  ③ 上次发版的源码里有、现在没了的 @Model 属性/类型 → 违反「数据只加不改」（删/改名会让旧版本和旧数据对不上）。
  ④ 同名字段在两个环境类型不同 → 不可能自动兼容。

用法：
  python3 scripts/cloudkit_schema_check.py [--base <git ref>] [--prod-file X.ckdb --dev-file Y.ckdb]
退出码：0 = 无阻断问题（可能有提醒）；1 = 有阻断问题；2 = 没能完成检查（cktool 失败等）。
管理令牌由 cktool 自己从钥匙串读（xcrun cktool save-token 存过）。"""
import argparse, re, subprocess, sys, tempfile
from pathlib import Path

TEAM = 'D2KWHV599Z'
CONTAINER = 'iCloud.com.jason.BetterCalendar'
ROOT = Path(__file__).resolve().parent.parent
SYSTEM_FIELD = re.compile(r'^___')


def export(env: str, out: Path) -> str:
    cmd = ['xcrun', 'cktool', 'export-schema', '--team-id', TEAM, '--container-id', CONTAINER,
           '--environment', env, '--output-file', str(out)]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if p.returncode or not out.exists():
        raise RuntimeError(f'cktool export-schema --environment {env} 失败：{(p.stderr or p.stdout).strip()[:400]}')
    return out.read_text()


def parse_schema(text: str) -> dict:
    """{记录类型: {字段: 类型}}（去掉 ___ 系统字段与 GRANT 行）。"""
    types = {}
    for m in re.finditer(r'RECORD TYPE (\S+) \((.*?)\n\s*\);', text, re.S):
        fields = {}
        for line in m.group(2).splitlines():
            line = line.strip().rstrip(',')
            if not line or line.startswith('GRANT'):
                continue
            parts = line.split()
            name = parts[0].strip('"')
            if SYSTEM_FIELD.match(name):
                continue
            fields[name] = parts[1] if len(parts) > 1 else '?'
        types[m.group(1)] = fields
    return types


MODEL = re.compile(r'@Model\s+(?:final\s+)?class\s+(\w+)[^{]*\{')
PROP = re.compile(r'^\s{4}(?:@\w+(?:\([^)]*\))?\s+)*var\s+(\w+)\s*:\s*([^{=\n]+?)\s*(?:=[^\n{]*)?(?://[^\n]*)?$', re.M)


def parse_models(sources: dict) -> dict:
    """{类名: {属性: 类型文本}}——只认 @Model 类顶层的存储属性（4 空格缩进的 var，计算属性因带 { 被排除）。"""
    models = {}
    for _, text in sources.items():
        for m in MODEL.finditer(text):
            body = text[m.end():]
            end = re.search(r'^\}', body, re.M)
            body = body[:end.start()] if end else body
            body = re.split(r'\n    (?:init|convenience init|func |static |@Transient)', body)[0]
            models[m.group(1)] = {p.group(1): p.group(2).strip() for p in PROP.finditer(body)}
    return models


def model_sources_at(ref=None) -> dict:
    if ref is None:
        return {str(p): p.read_text() for p in (ROOT / 'BetterCalendar' / 'Models').glob('*.swift')}
    names = subprocess.run(['git', 'ls-tree', '--name-only', ref, 'BetterCalendar/Models/'], cwd=ROOT,
                           capture_output=True, text=True, check=True).stdout.split()
    return {n: subprocess.run(['git', 'show', f'{ref}:{n}'], cwd=ROOT, capture_output=True, text=True, check=True).stdout
            for n in names if n.endswith('.swift')}


def latest_release_tag():
    tags = subprocess.run(['git', 'tag', '--list', 'release/*', '--sort=-creatordate'], cwd=ROOT,
                          capture_output=True, text=True).stdout.split()
    return tags[0] if tags else None


def check(prod: dict, dev: dict, models_now: dict, models_base) -> tuple:
    blockers, notes = [], []
    for t, fields in dev.items():
        if t not in prod:
            blockers.append(f'Development 有新记录类型 {t}，Production 没有 → 发版前请在 CloudKit 后台 Deploy')
            continue
        for f, ty in fields.items():
            if f not in prod[t]:
                blockers.append(f'{t}.{f}（{ty}）只在 Development → 发版前请 Deploy')
            elif prod[t][f] != ty:
                blockers.append(f'{t}.{f} 类型不同：Production {prod[t][f]} / Development {ty}（不可兼容，需改名为新字段）')
    for t, fields in prod.items():
        if t not in dev:
            notes.append(f'Production 有 {t}，Development 没有（多半是 Development 被重置过；Deploy 前先在 Development 补建）')
            continue
        for f in fields:
            if f not in dev[t]:
                notes.append(f'{t}.{f} 在 Production 有、Development 没有（Development 被重置过？）')
    for cls, props in models_now.items():
        rt = 'CD_' + cls
        if rt not in prod:
            blockers.append(f'@Model {cls} 在 Production 没有记录类型 {rt} → 先在 Development 建出并 Deploy')
            continue
        for p, ty in props.items():
            have = prod[rt]
            if f'CD_{p}' in have or f'CD_{p}_ckAsset' in have:
                continue
            if re.match(r'\[?\w+\]?\??$', ty) and ty.strip('[]?') in models_now:
                continue   # 关系：字段在对端记录上
            notes.append(f'@Model {cls}.{p}（{ty}）在 Production 没有 CD_{p} 字段：一旦写入非空值，这条记录上传会失败 → '
                         f'建议用 Debug 版在 Development 写一条非空值建出字段后 Deploy')
    if models_base is None:
        notes.append('没有找到上次发版的源码标记（git tag release/*），跳过「代码删字段」检查；本次发版成功后会打上标记')
    else:
        for cls, props in models_base.items():
            if cls not in models_now:
                blockers.append(f'@Model {cls} 在上次发版后被删除/改名 → 违反「数据只加不改」')
                continue
            for p, ty in props.items():
                if p not in models_now[cls]:
                    blockers.append(f'@Model {cls}.{p} 在上次发版后被删除/改名 → 违反「数据只加不改」（保留属性，不再使用即可）')
                elif models_now[cls][p].replace(' ', '') != ty.replace(' ', ''):
                    blockers.append(f'@Model {cls}.{p} 类型从 {ty} 改成 {models_now[cls][p]} → 违反「数据只加不改」（加新属性代替）')
    return blockers, notes


def run(base=None, prod_file=None, dev_file=None) -> int:
    try:
        with tempfile.TemporaryDirectory() as d:
            prod = parse_schema(Path(prod_file).read_text() if prod_file else export('production', Path(d) / 'p.ckdb'))
            dev = parse_schema(Path(dev_file).read_text() if dev_file else export('development', Path(d) / 'd.ckdb'))
    except Exception as e:  # noqa: BLE001 — 检查没做成要明说，不能当成通过
        print(f'❌ CloudKit schema 检查没能完成：{e}')
        return 2
    if not prod:
        print('❌ 没解析出 Production schema（导出格式变了？），检查没能完成')
        return 2
    base = base or latest_release_tag()
    try:
        models_base = parse_models(model_sources_at(base)) if base else None
    except subprocess.CalledProcessError:
        print(f'❌ 读不到基准版本 {base} 的源码')
        return 2
    blockers, notes = check(prod, dev, parse_models(model_sources_at()), models_base)
    print(f'CloudKit schema 检查（Production {len(prod)} 类 / Development {len(dev)} 类；代码基准 {base or "无"}）')
    for n in notes:
        print('  ⚠️ ' + n)
    for b in blockers:
        print('  ❌ ' + b)
    if not blockers:
        print('  ✅ 没有阻断问题')
    return 1 if blockers else 0


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', help='上次发版的 git ref（默认最新的 release/* 标签）')
    ap.add_argument('--prod-file')
    ap.add_argument('--dev-file')
    a = ap.parse_args()
    sys.exit(run(a.base, a.prod_file, a.dev_file))
