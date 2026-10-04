#!/bin/bash
# ============================================================================
# 《植物大战僵尸杂交版 0.29》Ubuntu 24.04 一键启动
#
# 用法（在你的真机 Ubuntu 上，有显卡/桌面会话）：
#     ./play-pvz.sh                     # 自动找 .pck，全流程，最后图形启动
#     ./play-pvz.sh --check             # 只检查不启动
#     ./play-pvz.sh --headless          # 无头自检（不需要显卡）
#     ./play-pvz.sh --opengl3           # 显卡/Vulkan 有问题时用 OpenGL 兼容模式
#     ./play-pvz.sh --refresh           # 强制重新解包（游戏更新后想手动刷新时用）
#     PCK="/路径/xxx.pck" ./play-pvz.sh  # 显式指定 .pck
#
# 游戏更新：把新版 .pck 和 data_PlantsVsZombies_windows_x86_64/ 覆盖到原处即可，
# 脚本靠「指纹」（PCK 路径 + 大小 + mtime）自动发现变化并重解包 + 重解析依赖，
# 不需要手动删任何东西。多个版本的 .pck 同时存在时会自动挑版本号最高的那个。
#
# 关键点（都是实测踩出来的，详见 README-linux-实测.md）：
#   1) 必须把 .pck 解包成真实目录，用 --path 启动。
#      --main-pack 不行：.NET 的 AssemblyLoadContext 要真实文件路径。
#   2) 程序集必须放在 .godot/mono/temp/bin/Debug/（Godot 编辑器二进制认 Debug）。
#   3) data_ 目录里**只有** PlantsVsZombies.dll，它的 deps.json 还声明了
#      Microsoft.Extensions.* / ZLogger / CommunityToolkit 等第三方库，
#      发布包里没带 —— 必须补齐，否则 Global/GameSaveManager 等单例初始化失败。
#      同时要避开与 .NET 9 框架自带的 System.Memory 等同名程序集冲突。
# ============================================================================
set -uo pipefail

GODOT_VER="4.7-stable"
GODOT_HASH_NAME="Godot_v4.7-stable_mono_linux_x86_64"
GODOT_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VER}/Godot_v4.7-stable_mono_linux_x86_64.zip"
# 国内加速（按可用性自动尝试）
MIRRORS=(
  "https://ghfast.top/${GODOT_URL}"
  "https://gh-proxy.com/${GODOT_URL}"
  "${GODOT_URL}"
)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$ROOT/tools"                  # Godot 与 .NET 运行时
DOTNET_DIR="$TOOLS/dotnet"
DOTNET_MAJOR=9

# 从 .desktop（Terminal=false）启动时环境很精简，PATH 可能不含标准目录，
# 会找不到 python3/curl 之类，表现为"双击没反应"却查不出原因。显式补齐。
for d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin /usr/games; do
  case ":$PATH:" in
    *":$d:"*) ;;
    *) PATH="$PATH:$d" ;;
  esac
done
export PATH
export DOTNET_ROOT="${DOTNET_ROOT:-$DOTNET_DIR}"

# ---------------------------------------------------------------- 权限自愈
# 从 U 盘 / zip / 微信传来的项目常常丢掉可执行位（tar.gz 会保留，zip 不一定）。
# 缺了就补回来，避免用户看到"无法执行"却不知为何。
_chmod_needed=0
for f in play-pvz.sh run-game.sh install-desktop.sh lib-desktop.sh make-icons.py fetch_deps.py setup_project.py; do
  [ -f "$ROOT/$f" ] && [ ! -x "$ROOT/$f" ] && _chmod_needed=1
done
if [ "$_chmod_needed" = 1 ]; then
  # 注意用 755 而不是 +x：+x 会受 umask 影响可能生成 --x--x--x，
  # 那样文件不可读（脚本要用 . 加载），会出莫名其妙的错。
  chmod 755 "$ROOT"/*.sh "$ROOT"/*.py 2>/dev/null || true
  printf '[!] 检测到脚本缺少可执行权限，已自动修复\n'
fi

# ---------------------------------------------------------------- 无终端支持
# 从 .desktop 双击启动时没有终端（Terminal=false）。这时把全过程同时写进
# logs/play-<时间>.log，并保留 latest.log 便于排查；有终端时行为和以前一样。
# 注意 sh 里 [[ ]] 不可用，这里用 POSIX 写法。
if [ ! -t 1 ]; then
  mkdir -p "$ROOT/logs" 2>/dev/null
  _log="$ROOT/logs/play-$(date '+%Y%m%d-%H%M%S').log"
  ln -sfn "$(basename "$_log")" "$ROOT/logs/latest.log" 2>/dev/null
  exec > >(tee -a "$_log") 2>&1
fi

MODE="play"
REFRESH=0
for a in "$@"; do
  case "$a" in
    --check)     MODE="check" ;;
    --headless)  MODE="headless" ;;
    --opengl3)   MODE="opengl3" ;;
    --refresh)   REFRESH=1 ;;
    -h|--help)   sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "未知参数: $a"; exit 2 ;;
  esac
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. 找 .pck
# 更新游戏时目录里可能同时存在多个版本的 .pck。只取"最新"的那个：
# 先按文件名里的版本号比大小，版本号相同或解析不出时再按 mtime。
# （绝不能用 find | head -1 —— 顺序由文件系统决定，可能选中旧的。）
pck_version() {   # 从文件名里抽出版本号，便于比较，如 0.29.0 -> 000029000
  local b
  b="$(basename "$1")"
  if [[ "$b" =~ ([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    printf '%03d%03d%03d' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  elif [[ "$b" =~ ([0-9]+)\.([0-9]+) ]]; then
    printf '%03d%03d000' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf ''
  fi
}

find_pck() {
  if [ -n "${PCK:-}" ]; then echo "$PCK"; return; fi
  local list f best="" bestkey=""
  # 先在常见位置找，找不到再放宽深度（新版本可能换目录名/层级）
  list=$(find "$ROOT" -maxdepth 4 -iname '*.pck' -size +100M 2>/dev/null)
  [ -n "$list" ] || list=$(find "$ROOT" -maxdepth 7 -iname '*.pck' -size +100M 2>/dev/null)
  [ -n "$list" ] || list=$(find "$HOME" -maxdepth 5 -iname '*杂交*.pck' 2>/dev/null)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    local v m key
    v=$(pck_version "$f")
    m=$(stat -c '%Y' "$f" 2>/dev/null || echo 0)
    key="${v:-000000000}${m}"
    if [ -z "$best" ] || [[ "$key" > "$bestkey" ]]; then
      best="$f"; bestkey="$key"
    fi
  done <<< "$list"
  echo "$best"
}

say "工作目录: $ROOT"
PCK_FILE="$(find_pck)"
[ -n "$PCK_FILE" ] || die "没找到 .pck（>100MB）。用 PCK=\"/路径/xxx.pck\" ./play-pvz.sh 指定。"
[ -f "$PCK_FILE" ] || die "指定的 .pck 不存在: $PCK_FILE"
PCK_DIR="$(dirname "$PCK_FILE")"
# 统一转绝对路径：脚本后面会 cd 到 .pck 所在目录，相对路径会失效（实测踩过）
PCK_DIR="$(cd "$PCK_DIR" && pwd)"
PCK_FILE="$PCK_DIR/$(basename "$PCK_FILE")"
say "资源包: $PCK_FILE"
say "       $(du -h "$PCK_FILE" | cut -f1)"

GAME_DIR="$PCK_DIR/pvzproj"          # 解包后的工程目录（放在 .pck 旁边）

# 程序集目录：正常叫 data_PlantsVsZombies_windows_x86_64，但更新版本可能改名
# （例如多一个平台后缀），所以先精确找、再通配找，最后宽松兜底。
DATA_DIR="$PCK_DIR/data_PlantsVsZombies_windows_x86_64"
if [ ! -f "$DATA_DIR/PlantsVsZombies.dll" ]; then
  for cand in "$PCK_DIR"/data_PlantsVsZombies*/ "$PCK_DIR"/data_*/; do
    [ -d "$cand" ] || continue
    if [ -f "${cand}PlantsVsZombies.dll" ]; then DATA_DIR="${cand%/}"; break; fi
  done
fi

if [ -f "$DATA_DIR/PlantsVsZombies.dll" ]; then
  say "程序集: $DATA_DIR/PlantsVsZombies.dll"
else
  warn "在 .pck 同层没找到含 PlantsVsZombies.dll 的 data_* 目录"
  warn "如果压缩包还没解压，请先全部解压（Ubuntu 上用 7z，普通 unzip 会因 deflate64 报错）"
  DATA_DIR="$(find "$ROOT" "$HOME" -maxdepth 5 -type d -name 'data_PlantsVsZombies*' 2>/dev/null | head -1)"
  [ -n "$DATA_DIR" ] && say "改用: $DATA_DIR" || die "找不到程序集目录，无法继续。"
fi

# ------------------------------------------------- 2. 校验 PCK（纯 python，不依赖 7z）
say "校验 .pck 结构…"
python3 - "$PCK_FILE" <<'PY' || die "PCK 校验失败"
import struct, hashlib, random, sys
p = sys.argv[1]
raw = open(p, "rb").read()
assert raw[:4] == b"GDPC", "magic 不是 GDPC"
fmt, = struct.unpack_from("<I", raw, 4)
v = struct.unpack_from("<III", raw, 8)
fb, = struct.unpack_from("<Q", raw, 24)
do, = struct.unpack_from("<Q", raw, 32)
cnt, = struct.unpack_from("<I", raw, do)
q = do + 4; ents = []
for _ in range(cnt):
    ln, = struct.unpack_from("<I", raw, q); q += 4
    nm = raw[q:q+ln].rstrip(b"\x00").decode("utf-8", "replace"); q += ln
    ofs, sz = struct.unpack_from("<QQ", raw, q); q += 16
    md5 = raw[q:q+16]; q += 16
    fl, = struct.unpack_from("<I", raw, q); q += 4
    ents.append((nm, ofs, sz, md5))
random.seed(1)
bad = 0
for nm, ofs, sz, md5 in random.sample(ents, min(300, cnt)):
    d = raw[fb+ofs:fb+ofs+sz]
    if md5 != b"\x00"*16 and hashlib.md5(d).digest() != md5:
        bad += 1
print("    Godot %d.%d.%d packfmt=%d 条目=%d md5抽检失败=%d" % (*v, fmt, cnt, bad))
assert bad == 0, "md5 抽检失败，文件可能损坏"
print("    ✔ 资源包完好")
PY

# ------------------------------------------------------------- 3. 装 Godot
GODOT_BIN="$TOOLS/$GODOT_HASH_NAME/Godot_v4.7-stable_mono_linux.x86_64"
if [ ! -x "$GODOT_BIN" ]; then
  say "下载官方 Godot ${GODOT_VER} .NET (Linux x86_64)…"
  mkdir -p "$TOOLS"
  zip="$TOOLS/godot.zip"
  ok=0
  for m in "${MIRRORS[@]}"; do
    echo "    尝试: ${m%%/https*}"
    if curl -L --fail --retry 3 --connect-timeout 15 -o "$zip" "$m"; then ok=1; break; fi
  done
  [ "$ok" = 1 ] || die "Godot 下载失败。请手动下载放到 $TOOLS/ 并解压：
    $GODOT_URL"
  unzip -q -o "$zip" -d "$TOOLS" || die "解压 Godot 失败"
  chmod +x "$TOOLS/$GODOT_HASH_NAME"/Godot_v4.7-stable_mono_linux.x86_64
  rm -f "$zip"
fi
[ -x "$GODOT_BIN" ] || die "Godot 可执行文件缺失: $GODOT_BIN"
say "Godot: $("$GODOT_BIN" --headless --version 2>/dev/null | tail -1)"

# --------------------------------------------------------------- 4. 装 .NET
if [ ! -x "$DOTNET_DIR/dotnet" ]; then
  say "安装 .NET ${DOTNET_MAJOR} 运行时（装到 $DOTNET_DIR，不需要 root）…"
  mkdir -p "$DOTNET_DIR"
  script="$TOOLS/dotnet-install.sh"
  if [ ! -s "$script" ]; then
    curl -L --fail -o "$script" https://dot.net/v1/dotnet-install.sh || die "下载 dotnet-install.sh 失败"
  fi
  chmod +x "$script"
  "$script" --runtime dotnet --channel "${DOTNET_MAJOR}.0" --install-dir "$DOTNET_DIR" --no-path \
    || die "安装 .NET 运行时失败（检查网络）"
fi
export DOTNET_ROOT="$DOTNET_DIR"
export PATH="$DOTNET_DIR:$PATH"
say ".NET: $("$DOTNET_DIR/dotnet" --list-runtimes 2>/dev/null | grep -m1 NETCore)"

# ------------------------------------------------- 5. 解包 .pck 成工程目录
# 判断是否需要重解包，分三层，越靠后越准、代价越大：
#   1) .pck 路径变了（改名升级 0.29 -> 0.30）            -> 直接重解包
#   2) stat 签名（大小+mtime+inode+ctime）没变            -> 内容必然没变，零开销跳过
#   3) 签名变了 -> 算一次内容哈希跟上次比：
#        哈希不同 -> 内容真变了，重解包
#        哈希相同 -> 只是时间戳变了（比如重新解压同一个包），不重解包
# 这样既能抓住"改了内容但时间戳没变"，也不会因为"时间戳变了但内容没变"白忙一场。
STATE="$GAME_DIR/.pvz-state"
PCK_HASH=""          # 本次算出的内容哈希（按需计算，见下）

pck_stat_sig() {     # 轻量签名：内容没动就一定相同
  stat -c '%s-%Y-%i-%Z' "$1" 2>/dev/null || echo "unknown"
}

pck_content_hash() { # 完整内容哈希（460MB，约 1~2 秒）。优先用系统 sha256sum
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1
  else
    python3 - "$1" <<'PY' 2>/dev/null
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as f:
    for chunk in iter(lambda: f.read(8 << 20), b""):
        h.update(chunk)
print(h.hexdigest())
PY
  fi
}

state_get() { grep -m1 "^$1=" "$STATE" 2>/dev/null | cut -d= -f2-; }

NEED_UNPACK=0
UNPACK_WHY=""
NEED_STATE_REFRESH=0     # 内容没变但 stat 变了：只更新记录，不重解包

if [ ! -f "$GAME_DIR/project.binary" ]; then
  NEED_UNPACK=1; UNPACK_WHY="还没有解包过"
elif [ "$REFRESH" = 1 ]; then
  NEED_UNPACK=1; UNPACK_WHY="指定了 --refresh"
else
  # 状态文件内容是自产的，但仍不 source（避免任何意外执行）
  old_pck="$(state_get PCK)"
  if [ -z "$old_pck" ]; then
    NEED_UNPACK=1; UNPACK_WHY="缺少版本记录（首次启用指纹）"
  elif [ "$old_pck" != "$PCK_FILE" ]; then
    NEED_UNPACK=1; UNPACK_WHY="资源包换了：$(basename "$old_pck") -> $(basename "$PCK_FILE")"
  else
    old_sig="$(state_get SIG)"
    new_sig="$(pck_stat_sig "$PCK_FILE")"
    if [ "$old_sig" != "$new_sig" ]; then
      # 签名变了：可能是真更新，也可能只是时间戳被动过。比内容哈希分清楚。
      say "资源包的时间戳/大小有变化，正在核对内容（约 1~2 秒）…"
      PCK_HASH="$(pck_content_hash "$PCK_FILE")"
      old_hash="$(state_get HASH)"
      if [ -z "$old_hash" ]; then
        NEED_UNPACK=1; UNPACK_WHY="缺少内容哈希（首次启用内容比对）"
      elif [ "$PCK_HASH" != "$old_hash" ]; then
        NEED_UNPACK=1; UNPACK_WHY="资源包内容确实变了（哈希不同）"
      else
        # 内容一样，只是 stat 变了（例如重新解压同一个包）
        NEED_STATE_REFRESH=1
        say "内容未变（哈希一致），只是时间戳不同 —— 无需重新解包"
      fi
    fi
  fi
fi

if [ "$NEED_UNPACK" = 1 ]; then
  say "更新/解包：$UNPACK_WHY"
  # GAME_DIR 必须是 .pck 同层那个 pvzproj，加个安全闸防止误删
  case "$GAME_DIR" in
    */pvzproj) ;;
    *) die "工程目录不符合预期（$GAME_DIR），拒绝清理" ;;
  esac
  [ -d "$GAME_DIR" ] && rm -rf "$GAME_DIR"
  say "解包 $PCK_FILE 到 $GAME_DIR（约 26500 个文件，1~2 分钟）…"
  python3 "$ROOT/setup_project.py" "$PCK_FILE" "$GAME_DIR" "$DATA_DIR" || die "解包失败"
  # 换了资源包 -> 依赖也必须重新解析（新版可能增删依赖）
  rm -f "$GAME_DIR/.deps-fixed"
  # 哈希已经算过就复用，避免同一轮读两遍 460MB
  [ -n "$PCK_HASH" ] || PCK_HASH="$(pck_content_hash "$PCK_FILE")"
  {
    printf 'PCK=%s\n' "$PCK_FILE"
    printf 'SIG=%s\n' "$(pck_stat_sig "$PCK_FILE")"
    printf 'HASH=%s\n' "$PCK_HASH"
    printf 'SIZE=%s\n' "$(stat -c '%s' "$PCK_FILE")"
    printf 'MTIME=%s\n' "$(stat -c '%Y' "$PCK_FILE")"
    printf 'UNPACKED_AT=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  } > "$STATE"
  say "已记录资源包版本（下次启动无需重新解包）"
elif [ "$NEED_STATE_REFRESH" = 1 ]; then
  # 内容没变、只是 stat 变了：把记录对齐，下次就能直接跳过
  {
    printf 'PCK=%s\n' "$PCK_FILE"
    printf 'SIG=%s\n' "$(pck_stat_sig "$PCK_FILE")"
    printf 'HASH=%s\n' "$PCK_HASH"
    printf 'SIZE=%s\n' "$(stat -c '%s' "$PCK_FILE")"
    printf 'MTIME=%s\n' "$(stat -c '%Y' "$PCK_FILE")"
    printf 'UNPACKED_AT=%s\n' "$(state_get UNPACKED_AT)"
  } > "$STATE"
  say "工程目录已是最新（内容未变），跳过解包"
else
  say "工程目录已是最新（$(basename "$PCK_FILE")），跳过解包"
fi

# ------------------------------------------ 6. 补齐第三方 NuGet 依赖（关键）
BIN_DEBUG="$GAME_DIR/.godot/mono/temp/bin/Debug"
BIN_REL="$GAME_DIR/.godot/mono/temp/bin/Release"
MARK="$GAME_DIR/.deps-fixed"
if [ ! -f "$MARK" ]; then
  say "补齐第三方依赖库（Microsoft.Extensions.* / ZLogger / Roslyn / CodeAnalysis …）…"
  python3 "$ROOT/fetch_deps.py" "$DATA_DIR" "$BIN_DEBUG" || warn "依赖解析有问题，继续尝试"
  # 只排除**真正的垫片包**：
  #   System.Memory 4.5.3 是给 netstandard 的旧垫片，放在程序集旁边会把 .NET 9
  #   框架自带的 System.Memory 降级，导致 ZLogger 报
  #   MissingMethodException: MemoryMarshal.GetReference（实测）。
  # 注意：Microsoft.CodeAnalysis.* **不能删**——游戏的 TransientStaticTextureRelease
  #   会反射遍历字段类型，需要 Roslyn 元数据程序集，删了会在切场景时崩
  #   （实测：TypeInitializationException -> FileNotFoundException Microsoft.CodeAnalysis）。
  #   同理 System.Collections.Immutable / System.Reflection.Metadata 是 Roslyn 的
  #   显式依赖（deps.json 声明 9.0.0），要保留。
  rm -f "$BIN_DEBUG/System.Memory.dll" "$BIN_REL/System.Memory.dll"
  # 多语言资源程序集对运行时无用，删掉省体积
  find "$BIN_DEBUG" "$BIN_REL" -name '*.resources.dll' -delete 2>/dev/null || true
  python3 - "$BIN_DEBUG" "$BIN_REL" <<'PY'
import json, os, sys
rm = {"System.Memory/4.5.3"}
for cfg in sys.argv[1:]:
    p = os.path.join(cfg, "PlantsVsZombies.deps.json")
    if not os.path.exists(p):
        continue
    d = json.load(open(p))
    for t in d.get("targets", {}).values():
        for k in list(t):
            if k in rm:
                del t[k]
    for k in list(d.get("libraries", {})):
        if k in rm:
            del d["libraries"][k]
    json.dump(d, open(p, "w"), indent=2)
PY
  touch "$MARK"
else
  say "依赖已补齐过（删除 $MARK 可重做）"
fi
# 程序集三个文件 + 依赖同时放 Debug 和 Release 两份最稳
# （Godot 编辑器二进制认 Debug；导出模板才认 Release。目录必须先确保存在，
#   否则 cp 到不存在的路径会把它当成文件名，留下一个叫 Release 的普通文件。）
mkdir -p "$BIN_DEBUG" "$BIN_REL"
# 主程序集必须**每次**确认在位：它只在解包那一步被 setup_project.py 放进来，
# 而解包在工程已存在时会被跳过——如果 bin/ 被清理过，程序集就永久缺失，
# 症状是 ".NET: Failed to load project assembly" + 136 条
# "Cannot instantiate C# script"（实测踩过）。这里无条件重放。
for c in "$BIN_DEBUG" "$BIN_REL"; do
  cp -f "$DATA_DIR/PlantsVsZombies.dll" \
        "$DATA_DIR/PlantsVsZombies.deps.json" \
        "$DATA_DIR/PlantsVsZombies.runtimeconfig.json" "$c/" 2>/dev/null || true
done
cp -f "$BIN_DEBUG"/* "$BIN_REL"/ 2>/dev/null || true
_ndll=$(ls "$BIN_DEBUG"/*.dll 2>/dev/null | wc -l)
say "依赖库数量: $_ndll 个 dll"
[ -f "$BIN_DEBUG/PlantsVsZombies.dll" ] || die "主程序集未能就位: $BIN_DEBUG/PlantsVsZombies.dll"

# ------------------------------------------------- 6.5 装快捷方式（含 --check）
# 首次运行时顺手把桌面/菜单快捷方式装好，省掉用户"再跑一次安装脚本"。
# 放在 --check 退出之前：这样 `./play-pvz.sh --check` 就等于"初始化 + 自检"。
# 失败不影响游戏启动（例如 HOME 只读）。
INSTALL_MARK="$ROOT/.desktop-installed"
if [ ! -f "$INSTALL_MARK" ] && [ -x "$ROOT/install-desktop.sh" ]; then
  if "$ROOT/install-desktop.sh" >/dev/null 2>&1; then
    touch "$INSTALL_MARK" 2>/dev/null || true
    say "已装好桌面/应用菜单快捷方式（之后可直接双击启动）"
  else
    warn "快捷方式安装失败，可稍后手动运行 ./install-desktop.sh"
  fi
fi

# ------------------------------------------------------------------ 7. 启动
[ "$MODE" = "check" ] && { say "检查完成（--check，不启动）。"; exit 0; }

cd "$PCK_DIR" || die "无法进入 $PCK_DIR"

# Godot 要把存档/日志写到 $HOME/.local/share/godot/...，如果那里不可写
# 它会 make_dir_recursive 失败并直接段错误（signal 11）。
# 注意：不能只用 `mkdir -p` 判断——目录已存在但文件系统只读时 mkdir 也返回 0，
# 必须真正试写一个文件才能发现（实测踩过：/home 只读，mkdir 成功但写失败）。
if ! { mkdir -p "$HOME/.local/share/godot/app_userdata" 2>/dev/null &&
       touch "$HOME/.local/share/godot/app_userdata/.wtest" 2>/dev/null &&
       rm -f "$HOME/.local/share/godot/app_userdata/.wtest"; }; then
  warn "HOME 不可写（$HOME），改用工作区内目录，避免 Godot 段错误"
  export HOME="$ROOT/home"
  mkdir -p "$HOME/.local/share/godot/app_userdata" 2>/dev/null || die "备用 HOME 也建不出来: $HOME"
  touch "$HOME/.local/share/godot/app_userdata/.wtest" 2>/dev/null || die "备用 HOME 不可写: $HOME"
  rm -f "$HOME/.local/share/godot/app_userdata/.wtest"
fi

ARGS=(--path "$GAME_DIR")
case "$MODE" in
  headless) ARGS+=(--headless --quit-after 600) ;;
  opengl3)  ARGS+=(--rendering-driver opengl3) ;;
esac

say "启动: $GODOT_BIN ${ARGS[*]}"
echo "    （退出游戏后，日志在: \"\$HOME/.local/share/godot/app_userdata/植物大战僵尸杂交版/logs/godot.log\"）"
exec "$GODOT_BIN" "${ARGS[@]}"
