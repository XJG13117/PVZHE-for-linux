#!/usr/bin/env python3
"""生成 .desktop / hicolor 图标主题所需的游戏图标。

图标来源：解包后工程里的 res://icon.png（256×256，游戏本体图标，
画面是花朵+手套+"杂交版"字样+圣诞帽）。
优先用工程目录里解包出来的那份；没有就退回工作区 pvzproj/。

产出：icons/pvz-<尺寸>.png（256/128/64/48/32）
"""
import os
import sys

try:
    from PIL import Image
except ImportError:
    print("需要 Pillow: sudo apt install python3-pil", file=sys.stderr)
    sys.exit(1)

HERE = os.path.dirname(os.path.abspath(__file__))
CANDIDATES = [
    os.path.join(HERE, "ext3", "植物大战僵尸杂交重制版", "pvzproj", "icon.png"),
    os.path.join(HERE, "pvzproj", "icon.png"),
    os.path.join(HERE, "win", "icon.png"),
]
SIZES = (256, 128, 64, 48, 32)


def find_source():
    for p in CANDIDATES:
        if os.path.exists(p):
            return p
    return None


def main():
    src = find_source()
    if not src:
        print("找不到 icon.png，候选路径：", file=sys.stderr)
        for p in CANDIDATES:
            print("  " + p, file=sys.stderr)
        return 1
    print("图标源: %s" % src)
    img = Image.open(src).convert("RGBA")
    if img.size != (256, 256):
        img = img.resize((256, 256), Image.LANCZOS)
        print("  已缩放到 256×256")

    outdir = os.path.join(HERE, "icons")
    os.makedirs(outdir, exist_ok=True)
    for s in SIZES:
        out = os.path.join(outdir, "pvz-%d.png" % s)
        img.resize((s, s), Image.LANCZOS).save(out, "PNG", optimize=True)
        print("  -> %s (%d×%d, %d B)" % (os.path.relpath(out, HERE), s, s,
                                         os.path.getsize(out)))

    # 顺便产一个 .ico，方便别处用（可选）
    ico = os.path.join(outdir, "pvz.ico")
    img.save(ico, sizes=[(s, s) for s in SIZES])
    print("  -> %s" % os.path.relpath(ico, HERE))
    return 0


if __name__ == "__main__":
    sys.exit(main())
