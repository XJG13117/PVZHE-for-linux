#!/usr/bin/env python3
"""把《植物大战僵尸杂交重制版 0.29》的 .pck 解包成可运行的 Godot 工程目录。

为什么必须解包（实测 + 源码依据）：
  Godot 的 .NET 层加载游戏程序集时，会把它交给
  GodotPlugins.PluginLoadContext -> System.Runtime.Loader.AssemblyLoadContext，
  而 AssemblyLoadContext 需要**真实文件路径**，无法从虚拟包路径加载。
  所以 `Godot --main-pack xxx.pck` 必然失败在 PluginLoadContext 构造函数
  （症状：".NET: Failed to load project assembly" + 136 条
   "Cannot instantiate C# script because the associated class could not be found"）。
  改用「解包成目录 + --path」走真实文件系统，程序集即可正常加载（实测 0 错误）。

另外两个关键点（都是实测踩出来的）：
  1. 条目偏移是**相对 file_base** 的：真实位置 = file_base + offset。
  2. 程序集要放到 .godot/mono/temp/bin/**Debug**/（Godot 编辑器二进制是 debug 构建，
     _get_expected_build_config() 返回 "Debug"；Release 目录会导致加载失败）。
     正式 export template 才是 Release，所以两个目录都放一份最稳。

用法:
    python3 setup_project.py <原.pck> <输出工程目录> <data_...目录>
例:
    python3 setup_project.py "植物大战僵尸杂交版发布版0.29.0.Csharp.pck" ./pvzproj \
        ./data_PlantsVsZombies_windows_x86_64
"""
import hashlib
import os
import shutil
import struct
import sys
import time

BIN_CONFIGS = ["Debug", "Release"]
ASSEMBLY = "PlantsVsZombies"


def read_index(path):
    raw = open(path, "rb").read()
    if raw[:4] != b"GDPC":
        raise SystemExit("不是 Godot PCK（magic 应为 GDPC）: %s" % path)
    pack_format = struct.unpack_from("<I", raw, 4)[0]
    vmaj, vmin, vpat = struct.unpack_from("<III", raw, 8)
    file_base = struct.unpack_from("<Q", raw, 24)[0]
    dir_offset = struct.unpack_from("<Q", raw, 32)[0]
    p = dir_offset
    count, = struct.unpack_from("<I", raw, p)
    p += 4
    ents = []
    for _ in range(count):
        ln, = struct.unpack_from("<I", raw, p)
        p += 4
        name = raw[p:p + ln].rstrip(b"\x00").decode("utf-8", "replace")
        p += ln
        ofs, sz = struct.unpack_from("<QQ", raw, p)
        p += 16
        md5 = raw[p:p + 16]
        p += 16
        flags, = struct.unpack_from("<I", raw, p)
        p += 4
        ents.append((name, ofs, sz, md5, flags))
    return raw, pack_format, (vmaj, vmin, vpat), file_base, ents


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    pck, outdir, datadir = sys.argv[1], sys.argv[2], sys.argv[3]
    for x in (pck, datadir):
        if not os.path.exists(x):
            print("找不到:", x)
            return 1

    raw, fmt, ver, file_base, ents = read_index(pck)
    print("PCK: Godot %d.%d.%d packfmt %d, file_base=%d, %d 个文件"
          % (*ver, fmt, file_base, len(ents)))
    print("解包到:", outdir)

    os.makedirs(outdir, exist_ok=True)
    t0 = time.time()
    bad = 0
    for i, (name, ofs, sz, md5, flags) in enumerate(ents):
        if flags & 1:
            print("  跳过加密条目:", name)
            continue
        dest = os.path.join(outdir, name.replace("/", os.sep))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        data = raw[file_base + ofs: file_base + ofs + sz]
        if md5 != b"\x00" * 16 and hashlib.md5(data).digest() != md5:
            bad += 1
        with open(dest, "wb") as f:
            f.write(data)
        if (i + 1) % 5000 == 0:
            print("  %d/%d  (%.0fs)" % (i + 1, len(ents), time.time() - t0), flush=True)
    print("解包完成: %d 个文件, md5 失败 %d, 用时 %.0fs" % (len(ents), bad, time.time() - t0))

    pb = os.path.join(outdir, "project.binary")
    if os.path.exists(pb):
        head = open(pb, "rb").read(4)
        print("project.binary 魔数:", head, "(应为 b'ECFG')")
        if head != b"ECFG":
            print("  !! 警告：project.binary 头部不是 ECFG，解包偏移可能有误")

    # 放置程序集（Debug 与 Release 各一份）
    n = 0
    for cfg in BIN_CONFIGS:
        tgt = os.path.join(outdir, ".godot", "mono", "temp", "bin", cfg)
        os.makedirs(tgt, exist_ok=True)
        for f in ("%s.dll" % ASSEMBLY, "%s.deps.json" % ASSEMBLY,
                  "%s.runtimeconfig.json" % ASSEMBLY):
            src = os.path.join(datadir, f)
            if os.path.exists(src):
                shutil.copy2(src, os.path.join(tgt, f))
                n += 1
    print("已放置程序集 %d 个文件（目录: %s）" % (n, ", ".join(BIN_CONFIGS)))

    print()
    print("完成。启动方式：")
    print('  "$GODOT" --path "%s" --verbose' % os.path.abspath(outdir))
    print("（备用渲染后端: 追加 --rendering-driver opengl3）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
