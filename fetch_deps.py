#!/usr/bin/env python3
"""按 deps.json 拉取《植物大战僵尸杂交版》所需的第三方 NuGet 运行时程序集。

背景（实测）：发布包 data_PlantsVsZombies_windows_x86_64/ 里只有 PlantsVsZombies.dll，
但它的 deps.json 声明了 Microsoft.Extensions.* / ZLogger / CodeAnalysis 等第三方库。
Windows 自包含发布时这些库由 runtimepack 提供，Linux + Godot 编辑器环境下没有，
于是运行时报 System.IO.FileNotFoundException，导致 Global/GameSaveManager 等
核心单例初始化失败。（实测日志 evidence/ubuntu-headless.log）

做法：解析 deps.json 的 targets，对每个声明的库下载 .nupkg（NuGet flat container）、
解出 runtime 节点指定的 dll（或挑选最合适的 lib/<tfm>/xxx.dll），
统一放到目标目录，并生成一个 .deps.json 让 .NET 能在该目录解析到它们。
"""
import json
import os
import re
import shutil
import struct
import sys
import urllib.error
import urllib.request
import zipfile

NUGET = "https://api.nuget.org/v3-flatcontainer"
SKIP_PREFIX = ("runtimepack.", "Microsoft.NETCore.App", "Microsoft.AspNetCore.App")


def pick_lib(names, simple):
    """从 nupkg 条目里挑最合适的 dll 路径。

    必须排除 lib/<tfm>/<lang>/Xxx.resources.dll 这类多语言资源程序集，
    否则 Microsoft.CodeAnalysis.Common 会被误判成「没有 lib dll」——
    实测踩过：挑中了 lib/net9.0/cs/Microsoft.CodeAnalysis.resources.dll，
    于是 Roslyn 被整体跳过，游戏在 TransientStaticTextureRelease 处崩。
    """
    want = "%s.dll" % simple.lower()
    res = "%s.resources.dll" % simple.lower()
    prio = ["net9.0", "net8.0", "net7.0", "net6.0", "netstandard2.1", "netstandard2.0"]
    cands = [n for n in names
             if n.lower().endswith(want) and not n.lower().endswith(res)]
    if not cands:
        return None

    def score(p):
        low = p.lower()
        for i, t in enumerate(prio):
            # 只要 lib/<tfm>/<name>.dll，不要 lib/<tfm>/<lang>/<name>.dll
            if low.endswith("/lib/%s/%s" % (t, want)):
                return i
        return len(prio) + (0 if "/lib/" in low else 1)

    return sorted(cands, key=score)[0]


def fetch_nupkg(name, version, cache):
    fn = os.path.join(cache, "%s.%s.nupkg" % (name.lower(), version))
    if os.path.exists(fn) and os.path.getsize(fn) > 0:
        return fn
    url = "%s/%s/%s/%s.%s.nupkg" % (NUGET, name.lower(), version.lower(),
                                    name.lower(), version.lower())
    try:
        with urllib.request.urlopen(url, timeout=90) as r, open(fn, "wb") as f:
            shutil.copyfileobj(r, f)
    except urllib.error.HTTPError as e:
        print("    !! 下载失败 %s %s: HTTP %s" % (name, version, e.code))
        return None
    return fn


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        print("用法: fetch_deps.py <data_...目录> <目标程序集目录>")
        return 2
    datadir, outdir = sys.argv[1], sys.argv[2]
    cache = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dl", "nupkg")
    os.makedirs(cache, exist_ok=True)
    os.makedirs(outdir, exist_ok=True)

    deps = json.load(open(os.path.join(datadir, "PlantsVsZombies.deps.json")))
    pkgs = {}
    # (包名, 版本) -> [包内相对路径]，直接来自 deps.json 的 runtime 节点。
    # 必须用它来定位 dll：包名和程序集名常常不一致
    # （Microsoft.CodeAnalysis.Common 里的 dll 叫 Microsoft.CodeAnalysis.dll），
    # 按包名猜会永远猜不中（实测踩过）。
    runtime_map = {}
    for tgt, libs in deps["targets"].items():
        if tgt == ".NETCoreApp,Version=v9.0":
            continue
        for name, info in libs.items():
            if name.startswith(SKIP_PREFIX):
                continue
            deps_of = info.get("dependencies") or {}
            if "/" not in name:
                continue
            n, v = name.rsplit("/", 1)
            pkgs.setdefault(n, set()).add(v)
            rt = info.get("runtime") or {}
            if rt:
                runtime_map.setdefault((n, v), []).extend(rt.keys())
            for dn, dv in deps_of.items():
                pkgs.setdefault(dn, set()).add(dv)

    # 逐个库解析
    picked = {}   # simple name -> (pkg, version, srcpath)
    unresolved = []
    for name in sorted(pkgs):
        if name.startswith(SKIP_PREFIX):
            continue
        if name in ("PlantsVsZombies", "GodotSharp", "Godot.SourceGenerators"):
            continue
        # 纯编译期包：不提供运行时程序集。必须显式跳过，否则
        # Microsoft.CodeAnalysis.Analyzers 会先产出 analyzer 版的
        # Microsoft.CodeAnalysis.dll，把真正的 Common 程序集顶掉
        # （实测：于是 Roslyn 缺失，切场景时 TransientStaticTextureRelease 崩）。
        if name.endswith((".Analyzers", ".SourceGenerators", ".Build.Tasks",
                          ".ILLink.Tasks")) or name in ("Microsoft.NET.ILLink.Tasks",
                                                        "PolySharp"):
            print("  -- %-50s %-10s 编译期包，跳过" % (name, sorted(pkgs[name])[0]))
            continue
        handled = False
        for ver in sorted(pkgs[name]):
            # 1) 优先用 deps.json 明确声明的包内路径
            chosen = None
            for rel in runtime_map.get((name, ver), []):
                if rel.lower().endswith(".dll") and ".resources." not in rel.lower():
                    chosen = rel
                    break
            nup = fetch_nupkg(name, ver, cache)
            if not nup:
                continue
            try:
                z = zipfile.ZipFile(nup)
            except zipfile.BadZipFile:
                print("    !! 不是有效 nupkg: %s %s" % (name, ver))
                continue
            # 2) 退路：按程序集名在包内找（排除多语言资源程序集）
            if not chosen:
                chosen = pick_lib(z.namelist(), name)
            if not chosen:
                print("  -- %-50s %-10s 无 lib dll（仅编译期/分析器）" % (name, ver))
                continue
            if chosen not in z.namelist():
                # deps.json 里的路径偶尔与包内实际布局不一致，退回按名找
                alt = pick_lib(z.namelist(), name)
                if alt:
                    chosen = alt
                else:
                    print("    !! 包内找不到 %s（%s %s）" % (chosen, name, ver))
                    continue
            simple = os.path.basename(chosen)[:-4]
            if simple in picked:
                print("  == %-50s %-10s 已被 %s 提供，跳过"
                      % (name, ver, picked[simple][0]))
                handled = True
                break
            with z.open(chosen) as src:
                data = src.read()
            with open(os.path.join(outdir, simple + ".dll"), "wb") as f:
                f.write(data)
            picked[simple] = (name, ver, chosen)
            print("  ++ %-52s %-10s -> %s" % (name, ver, simple + ".dll"))
            handled = True
            break
        if not handled:
            unresolved.append(name)

    # 在**原始** deps.json 上合并：补上各库的 runtime 条目。
    # 不能整体重写——原文件还声明了 runtimepack/框架依赖，删掉会破坏解析。
    src_deps = os.path.join(datadir, "PlantsVsZombies.deps.json")
    depjson = os.path.join(outdir, "PlantsVsZombies.deps.json")
    orig = json.load(open(src_deps))
    added = 0
    for tgt in list(orig.get("targets", {}).keys()):
        if tgt.endswith("/win-x64"):
            continue          # 跳过 Windows 专用 target
        table = orig["targets"][tgt]
        for simple, (name, ver, _p) in picked.items():
            key = "%s/%s" % (name, ver)
            if key in table:
                continue
            table[key] = {"runtime": {"%s.dll" % simple: {}}}
            added += 1
        for name, vers in pkgs.items():
            for ver in vers:
                key = "%s/%s" % (name, ver)
                if key in table:
                    continue
                # 无 runtime dll 的（分析器/源生成器）也登记，避免解析告警
                table[key] = {}
                added += 1
    for simple, (name, ver, _p) in picked.items():
        orig.setdefault("libraries", {})["%s/%s" % (name, ver)] = {
            "type": "package", "serviceable": False, "sha512": ""
        }
    with open(depjson, "w") as f:
        json.dump(orig, f, indent=2)
    print("\n共解析出 %d 个运行时程序集 -> %s" % (len(picked), outdir))
    print("已在原始 deps.json 上合并 %d 条依赖声明" % added)
    if unresolved:
        print("未能解析: %s" % ", ".join(unresolved))
    return 0


if __name__ == "__main__":
    sys.exit(main())
