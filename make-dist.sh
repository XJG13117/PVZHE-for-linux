#!/bin/bash
# ============================================================================
# 打包成「解压就能用」的分发包
#
#   ./make-dist.sh                 # 产出一个 tar.gz，放到上层目录
#   ./make-dist.sh --out /tmp      # 指定输出目录
#   ./make-dist.sh --dry-run       # 只列出会打包什么，不真打包
#
# 为什么用 tar.gz 而不是 zip：tar.gz 会保留可执行权限，zip 常常丢，
# 丢了虽然脚本有权限自愈，但用户得先用 `bash xxx.sh` 才能触发，不友好。
#
# 分发包里刻意做的事：
#   - 把项目自带的 .desktop 里的绝对路径换成占位符 __PROJECT_DIR__，
#     这样它在任何机器上都不匹配，首次运行必然触发自愈 -> 自动指向真实位置。
#   - 排除日志、缓存、Windows 专用文件等无用内容。
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(readlink -f "$ROOT" 2>/dev/null || echo "$ROOT")"
NAME="pvzhybrid-linux"
# 默认输出到项目内的 dist/ —— 写到项目外常常因权限/沙箱失败
OUTDIR="$ROOT/dist"
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --out)     OUTDIR="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# 打包清单（相对项目根）
# 注意必须带上「植物大战僵尸杂交版.desktop」——不然解压后没东西可双击，
# 整个"解压就能用"就落空了（踩过这个坑）。
INCLUDE=(
  play-pvz.sh run-game.sh install-desktop.sh lib-desktop.sh pvz-hybrid-bootstrap.sh
  make-icons.py fetch_deps.py setup_project.py make-dist.sh
  diagnose-dock.sh patch-appname.py
  "植物大战僵尸杂交版.desktop"
  icons
  tools
  dl
  ext3
  README-linux-实测.md README-ubuntu.md
)
# 排除规则。
# 注意：**不排除** .deps-fixed / .pvz-state —— 带上它们，目标机器首次启动
# 就能跳过解包与依赖解析；丢了大不了重做一遍，只是白等 1~2 分钟。
# 也不排除 .godot/ 下的东西：.godot/imported 是从 PCK 解出来的 .ctex，
# .godot/exported 里是游戏自己的数据（adobe_animate、gameplay），都不是缓存。
EXCLUDES=(
  --exclude='logs'
  --exclude='*.log'
  --exclude='__pycache__'
  --exclude='save-backup'
  --exclude='.git'
  # 必须排除：这个标记表示"本机已装过快捷方式"。若打进包，新机首次运行会
  # 跳过安装，桌面/菜单里就没有快捷方式。
  --exclude='.desktop-installed'
)

say "项目根: $ROOT"
echo

# ---------------------------------------------------------------- 完整性自检
say "打包前自检…"
problems=0
chk() {  # chk <描述> <路径>
  if [ -e "$2" ]; then printf '  ✔ %s\n' "$1"
  else printf '  ✘ %s  (缺: %s)\n' "$1" "$2"; problems=$((problems+1)); fi
}
chk "主脚本 play-pvz.sh"          "$ROOT/play-pvz.sh"
chk "桌面入口 run-game.sh"        "$ROOT/run-game.sh"
chk "快捷方式库 lib-desktop.sh"   "$ROOT/lib-desktop.sh"
chk "图标生成 make-icons.py"      "$ROOT/make-icons.py"
chk "依赖解析 fetch_deps.py"      "$ROOT/fetch_deps.py"
chk "解包脚本 setup_project.py"   "$ROOT/setup_project.py"
chk "图标目录 icons/"             "$ROOT/icons/pvz-256.png"
chk "Godot 引擎"                  "$ROOT/tools/Godot_v4.7-stable_mono_linux_x86_64/Godot_v4.7-stable_mono_linux.x86_64"
chk ".NET 运行时"                 "$ROOT/tools/dotnet/dotnet"
pck="$(ls "$ROOT"/ext3/*/*.pck 2>/dev/null | head -1)"
if [ -n "$pck" ]; then printf '  ✔ 资源包 %s\n' "$(basename "$pck")"
else printf '  ✘ 找不到 .pck\n'; problems=$((problems+1)); fi
proj="$(dirname "$pck" 2>/dev/null)/pvzproj"
if [ -f "$proj/project.binary" ]; then
  printf '  ✔ 已解包工程 pvzproj/（首次启动省 1~2 分钟）\n'
else
  warn "pvzproj/ 未解包 —— 首次启动会现场解包（也能用，只是慢一点）"
fi
[ "$problems" = 0 ] || die "有 $problems 项缺失，先修好再打包"
echo

# ---------------------------------------- 生成「可移植」的 .desktop（固定启动器）
# .desktop 规范不支持相对路径，所以 Exec 指向固定路径的启动器
#     ~/.local/bin/pvz-hybrid   ->  <项目>/pvz-hybrid-bootstrap.sh
# 这个链接由 install-desktop.sh 建立，于是项目解压到哪都无所谓。
# 包内这份直接写成上面这个正确内容（保留备份，打包完还原本机的）。
DESK="$ROOT/植物大战僵尸杂交版.desktop"
KEEPBAK="$ROOT/.desktop.local.bak"
restore_desk() {   # 打包结束/中断都要把本地快捷方式还原，别影响当前这台机器
  if [ -f "$KEEPBAK" ]; then
    cp -f "$KEEPBAK" "$DESK" 2>/dev/null || true
    chmod 755 "$DESK" 2>/dev/null || true
    rm -f "$KEEPBAK" 2>/dev/null || true
    say "已还原项目自带 .desktop（本机快捷方式不受影响）"
  fi
}
trap restore_desk EXIT INT TERM

if [ -f "$ROOT/lib-desktop.sh" ]; then
  # shellcheck source=lib-desktop.sh
  . "$ROOT/lib-desktop.sh"
  if [ "$DRY" = 1 ]; then
    say "[dry-run] 将把项目自带 .desktop 写成「与 HOME 无关」的可移植版本"
  else
    [ -f "$DESK" ] && cp -f "$DESK" "$KEEPBAK" 2>/dev/null || true
    tmpd="$(mktemp)"
    # 生成的 Exec 里含打包机的 HOME（/home/wdf/...），换台机器就废。
    # 统一换成占位符，目标机上第一次运行 play-pvz.sh 会按真实 HOME 重建。
    PVZ_BOOTSTRAP='__HOME__/.local/bin/pvz-hybrid' \
      pvz_desktop_content "$ROOT" \
      | sed "s|Path=$ROOT|Path=__PROJECT_DIR__|" > "$tmpd"
    cp -f "$tmpd" "$DESK"
    chmod 755 "$DESK"
    rm -f "$tmpd"
    say "已写入与 HOME 无关的可移植 .desktop"
  fi
fi
echo

# ---------------------------------------------------------------- 打包
STAMP="$(date '+%Y%m%d')"
TARBALL="$OUTDIR/$NAME-$STAMP.tar.gz"

if [ "$DRY" = 1 ]; then
  say "[dry-run] 会打包以下内容："
  for x in "${INCLUDE[@]}"; do
    [ -e "$ROOT/$x" ] && printf '    %-28s %s\n' "$x" "$(du -sh "$ROOT/$x" 2>/dev/null | cut -f1)"
  done
  echo "  排除: ${EXCLUDES[*]}"
  echo "  输出: $TARBALL"
  exit 0
fi

say "打包中（约 1.4 GB，需要几分钟）…"
mkdir -p "$OUTDIR"
# 打包成 <name>/... 顶层目录，解压即得项目根。
# 文件名可能带空格（.desktop 就是），所以用 NUL 分隔的列表经管道传给 tar；
# 不能用 $(...) 传参（会被拆词），也不能用 heredoc（bash 会丢掉 NUL）。
_base="$(basename "$ROOT")"
{
  for x in "${INCLUDE[@]}"; do
    [ -e "$ROOT/$x" ] && printf '%s\0' "$_base/$x"
  done
} | tar --null --no-unquote -czf "$TARBALL" \
      "${EXCLUDES[@]}" \
      -C "$(dirname "$ROOT")" \
      --transform "s|^$_base|$NAME|" \
      -T - \
  || die "tar 打包失败"

say "完成: $TARBALL  ($(du -h "$TARBALL" | cut -f1))"
echo
echo "  目标机器上："
echo "      tar -xzf $(basename "$TARBALL")"
echo "      cd $NAME"
echo "      双击项目里的「植物大战僵尸杂交版.desktop」"
echo "  （首次双击会自动把快捷方式指向正确位置并装到桌面/菜单）"
