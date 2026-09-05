#!/usr/bin/env python3
"""核对 DOCK_* 环境变量开关是否全部登记在 Core/Support/DebugSwitch.swift。

用法：python3 Scripts/check_debug_switches.py

三条规则，任一违反退出码 1：
1. App/ Core/ Platform/ 源码里（登记表本身除外）不得出现 "DOCK_…" 字符串字面量——读开关一律走 DebugSwitch；
2. Tests/ Tools/ Scripts/ 里出现的每个 DOCK_… 名字都必须在登记表里（防止测试 / 脚本引用已删掉的开关）；
3. 登记表里的每个 case 都要在 App/ Core/ Platform/ 里被 `DebugSwitch.<case>` 引用过——没人读的开关就是死开关。
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REGISTRY = ROOT / 'Core/Support/DebugSwitch.swift'
SRC_DIRS = ['App', 'Core', 'Platform']
AUX_DIRS = ['Tests', 'Tools', 'Scripts']

LITERAL = re.compile(r'"(DOCK_[A-Z0-9_]+)"')
CASE = re.compile(r'^\s*case\s+([A-Za-z0-9_]+)\s*=\s*"(DOCK_[A-Z0-9_]+)"', re.M)
NAME = re.compile(r'\bDOCK_[A-Z0-9_]+\b')


def swift_files(dirs):
    for d in dirs:
        yield from (ROOT / d).rglob('*.swift')


def main() -> int:
    text = REGISTRY.read_text()
    registered = {raw: case for case, raw in CASE.findall(text)}
    if not registered:
        print(f'❌ 登记表里没解析到任何 case：{REGISTRY}')
        return 1
    problems = []

    # 1. 源码里不许有字面量
    for f in swift_files(SRC_DIRS):
        if f == REGISTRY:
            continue
        for i, line in enumerate(f.read_text().splitlines(), 1):
            for raw in LITERAL.findall(line):
                problems.append(f'{f.relative_to(ROOT)}:{i}: 直接用了 "{raw}" —— 改成 DebugSwitch.{registered.get(raw, "<先登记>")}')

    # 2. 测试 / 工具 / 脚本引用的名字必须已登记
    for d in AUX_DIRS:
        for f in (ROOT / d).rglob('*'):
            if not f.is_file() or f.suffix not in ('.swift', '.sh', '.py') or f.name == 'check_debug_switches.py':
                continue
            for i, line in enumerate(f.read_text(errors='ignore').splitlines(), 1):
                for raw in NAME.findall(line):
                    if raw not in registered:
                        problems.append(f'{f.relative_to(ROOT)}:{i}: {raw} 未登记（删掉的开关？）')

    # 3. 登记了没人读 = 死开关
    src = '\n'.join(f.read_text() for f in swift_files(SRC_DIRS) if f != REGISTRY)
    for raw, case in registered.items():
        if f'DebugSwitch.{case}' not in src:
            problems.append(f'登记表：{raw}（.{case}）没有任何调用点，删掉它')

    print(f'登记 {len(registered)} 个开关')
    if problems:
        print('\n'.join('❌ ' + p for p in problems))
        return 1
    print('✅ 全部对上')
    return 0


if __name__ == '__main__':
    sys.exit(main())
