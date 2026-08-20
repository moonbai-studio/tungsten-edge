#!/usr/bin/env python3
"""核对本地化 key 与 Localizable.xcstrings 是否一一对应，并统计还剩多少中文没翻。

用法：python3 Scripts/check_localization.py [--remaining]

漏一条 = 中文用户在那个位置突然看到英文，编译期完全不报错。
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / 'Resources/Localizable.xcstrings'
DIRS = ['App', 'Core', 'Platform', 'UI']

STR = r'"((?:[^"\\]|\\.)*)"'
# 全文匹配（允许构造器后换行），用 match.start() 反查行号
RE_LOCALIZED = re.compile(r'String\(\s*localized:\s*(?!""")' + STR)
RE_SWIFTUI = re.compile(r'\b(?:Text|Button|Toggle|Label|Picker|TextField)\(\s*' + STR)
# 用户可见的中文字面量（用来统计剩余工作量）
RE_CHINESE = re.compile(STR)

SKIP_FILES = {'App/Scenes/ContentView.swift'}   # 未接线的调试台，按方案不翻


def unescape(s):
    return s.replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')


def strip_comments(text):
    """把注释行整行变成空白，保留行数（这样行号仍然准）。"""
    out = []
    in_block = False
    for line in text.splitlines():
        s = line.strip()
        if in_block:
            out.append('')
            if '*/' in line:
                in_block = False
            continue
        if s.startswith('/*'):
            out.append('')
            if '*/' not in line:
                in_block = True
            continue
        if s.startswith('//'):
            out.append('')
            continue
        out.append(line)
    return '\n'.join(out)


def lineno_of(text, pos):
    return text.count('\n', 0, pos) + 1


def eval_multiline(block_lines, closing_indent):
    out = []
    for line in block_lines:
        line = line[closing_indent:] if len(line) >= closing_indent else line.lstrip()
        out.append(line)
    text = '\n'.join(out)
    # 行尾续行符：\ + 换行 → 直接拼接
    text = re.sub(r'\\\n', '', text)
    return text


def extract_multiline(path):
    lines = pathlib.Path(path).read_text(encoding='utf-8').splitlines()
    keys = []
    i = 0
    while i < len(lines):
        if re.search(r'String\(localized:\s*"""\s*$', lines[i]):
            body = []
            j = i + 1
            while j < len(lines) and lines[j].strip() != '"""' and not lines[j].strip().startswith('""")'):
                body.append(lines[j])
                j += 1
            closing = len(lines[j]) - len(lines[j].lstrip()) if j < len(lines) else 0
            keys.append(eval_multiline(body, closing))
            i = j
        i += 1
    return keys


def scan():
    used, chinese = {}, []
    for d in DIRS:
        for f in sorted((ROOT / d).rglob('*.swift')):
            rel = str(f.relative_to(ROOT))
            if rel in SKIP_FILES:
                continue
            text = strip_comments(f.read_text(encoding='utf-8'))
            for rx in (RE_LOCALIZED, RE_SWIFTUI):
                for m in rx.finditer(text):
                    key = unescape(m.group(1))
                    if rx is RE_SWIFTUI and re.fullmatch(r'[a-z0-9]+(?:\.[a-z0-9]+)+', key):
                        continue   # SF Symbol 名，如 folder.badge.plus
                    used.setdefault(key, []).append(f'{rel}:{lineno_of(text, m.start())}')
            for key in extract_multiline(f):
                used.setdefault(key, []).append(rel)
            for m in RE_CHINESE.finditer(text):
                if re.search(r'[一-龥]', m.group(1)):
                    chinese.append((f'{rel}:{lineno_of(text, m.start())}', m.group(1)))
    return used, chinese


def main():
    catalog = json.loads(CATALOG.read_text(encoding='utf-8'))['strings']
    used, chinese = scan()

    missing = {k: v for k, v in used.items() if k not in catalog}
    unused = [k for k in catalog if k not in used]
    untranslated = [k for k, v in catalog.items()
                    if not v.get('localizations', {}).get('zh-Hans', {}).get('stringUnit', {}).get('value')]
    chinese_key = [k for k in used if re.search(r'[一-龥]', k)]

    print(f'代码引用 {len(used)} 个 key ｜ catalog {len(catalog)} 条 ｜ 源码剩余中文字面量 {len(chinese)} 处\n')

    ok = True
    if missing:
        ok = False
        print(f'❌ catalog 缺 {len(missing)} 条（中文用户会看到英文）：')
        for k, locs in sorted(missing.items()):
            print(f'   {k[:70]!r}  ← {locs[0]}')
    if untranslated:
        ok = False
        print(f'\n❌ {len(untranslated)} 条没有中文翻译：')
        for k in untranslated:
            print(f'   {k[:70]!r}')
    if chinese_key:
        ok = False
        print(f'\n❌ {len(chinese_key)} 个 key 本身是中文（源语言应为英文）：')
        for k in chinese_key:
            print(f'   {k[:70]!r}  ← {used[k][0]}')
    if unused:
        ok = False
        print(f'\n❌ catalog 里 {len(unused)} 条没被引用（死条目或扫描盲区，两种都要查）：')
        for k in unused:
            print(f'   {k[:70]!r}')

    if '--remaining' in sys.argv and chinese:
        print(f'\n--- 剩余中文字面量 {len(chinese)} 处 ---')
        for loc, s in chinese:
            print(f'   {loc}  {s[:60]}')

    print()
    print('✅ 全部对上' if ok else '⛔ 有问题，见上')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
