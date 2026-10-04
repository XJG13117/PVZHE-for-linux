#!/usr/bin/env python3
"""把 project.binary 里的应用名换成等长 ASCII。

╔══════════════════════════════════════════════════════════════════════════╗
║ ⚠  默认不要用！这个操作有真实副作用，实测踩过：                          ║
║                                                                          ║
║ Godot 用 application/config/name 派生**用户数据（存档）目录**：          ║
║     user://  ->  ~/.local/share/godot/app_userdata/<应用名>/             ║
║ 改了名字，Godot 就去找 app_userdata/<新名字>/，**原存档目录找不到**——    ║
║ 文件还在，但游戏读不到，等于把进度藏起来了。                             ║
║                                                                          ║
║ 所以：Dock 图标/名称问题请优先用 .desktop 的 StartupWMClass 解决          ║
║ （见 README-linux-实测.md 第十三节），不要动应用名。                     ║
║ 本脚本仅作研究/应急用；真要改，必须先把存档目录一并改名或备份。           ║
╚══════════════════════════════════════════════════════════════════════════╝

原理：project.binary 里 application/config/name 是「植物大战僵尸杂交版」
（UTF-8 27 字节）。本脚本把它**等长替换**为 ASCII，长度不变 ->
project.binary 里所有长度字段都不用动，风险最低。

用法:
    python3 patch-appname.py <project.binary>            # 默认 "PvZ Hybrid Remastered v0.29"
    python3 patch-appname.py <project.binary> "SomeName" # 自定义（自动补空格/截断到等长）
    python3 patch-appname.py <project.binary> --restore  # 还原
"""
import os
import sys

CN_DEFAULT = "植物大战僵尸杂交版"
# 必须与原 UTF-8 串**等长**（27 字节），否则要动 project.binary 里的长度字段，
# 风险大得多。下面这个恰好 27 字节。
NEW_DEFAULT = "PvZ Hybrid Remastered v0.29"
BAK_SUFFIX = ".appname.bak"


def fit_ascii(s, n):
    """把 s 调成正好 n 字节的 ASCII：不足补空格，超了截断。"""
    b = s.encode("ascii", "replace")
    if len(b) > n:
        b = b[:n]
    return b + b" " * (n - len(b))


def find_and_replace(data, old_bytes, new_bytes):
    """返回 (新数据, 命中次数)。等长替换，不调整任何长度字段。"""
    if len(old_bytes) != len(new_bytes):
        raise ValueError("长度必须相同：old=%d new=%d" % (len(old_bytes), len(new_bytes)))
    out = bytearray(data)
    hits = 0
    start = 0
    while True:
        i = data.find(old_bytes, start)
        if i < 0:
            break
        out[i:i + len(old_bytes)] = new_bytes
        hits += 1
        start = i + len(old_bytes)
    return bytes(out), hits


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    arg = sys.argv[2] if len(sys.argv) > 2 else NEW_DEFAULT
    restore = arg == "--restore"

    if not os.path.exists(path):
        print("找不到: %s" % path, file=sys.stderr)
        return 1
    bak = path + BAK_SUFFIX

    if restore:
        if not os.path.exists(bak):
            print("没有备份可还原（%s）" % bak, file=sys.stderr)
            return 1
        with open(bak, "rb") as f:
            orig = f.read()
        with open(path, "wb") as f:
            f.write(orig)
        os.remove(bak)
        print("已还原: %s" % path)
        return 0

    if not arg.isascii():
        print("替换值必须是 ASCII（当前 %r 含非 ASCII 字符）" % arg, file=sys.stderr)
        return 1

    with open(path, "rb") as f:
        data = f.read()

    old = CN_DEFAULT.encode("utf-8")
    new = fit_ascii(arg, len(old))
    patched, hits = find_and_replace(data, old, new)

    if hits == 0:
        print("没找到「%s」——可能已经打过补丁，或这个版本用了别的名字" % CN_DEFAULT)
        return 0

    if not os.path.exists(bak):
        with open(bak, "wb") as f:
            f.write(data)
        print("已备份原文件: %s" % bak)
    with open(path, "wb") as f:
        f.write(patched)
    print("已把应用名替换为 %r（%d 处，等长替换，长度字段未动）" % (arg, hits))
    return 0


if __name__ == "__main__":
    sys.exit(main())
