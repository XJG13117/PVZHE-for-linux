#!/bin/bash
# ============================================================================
# 把《植物大战僵尸杂交版》安装成桌面快捷方式（可双击启动，无终端）
#
#   ./install-desktop.sh              # 装到桌面 + 应用程序菜单
#   ./install-desktop.sh --desktop    # 只装桌面
#   ./install-desktop.sh --menu       # 只装应用程序菜单
#   ./install-desktop.sh --uninstall  # 卸载（桌面 + 菜单快捷方式）
#
# 图标用的是游戏本体的 res://icon.png（解包后工程里那份），
# 同时装进 hicolor 图标主题，桌面/菜单都能正确显示。
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ID="pvz-hybrid"
APP_NAME="植物大战僵尸杂交版"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

# 定位桌面目录。不能只用 `xdg-user-dir DESKTOP`：它有时会返回 ~/Desktop
# 而该目录并不存在（或系统用的是中文“桌面”），于是 -d 判断失败、
# 快捷方式被静默跳过，用户以为"没生成桌面图标"（实测踩过）。
# 这里按 xdg-user-dirs 配置 -> 常见中英文目录名 -> 实际存在优先 来挑。
if [ -n "${PVZ_DESKTOP_DIR:-}" ]; then
  DESKTOP_DIR="$PVZ_DESKTOP_DIR"
else
  _d1="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
  _cands="$_d1 $HOME/桌面 $HOME/Desktop $HOME/デスクトップ"
  DESKTOP_DIR=""
  for _d in $_cands; do
    [ -n "$_d" ] || continue
    if [ -d "$_d" ]; then DESKTOP_DIR="$_d"; break; fi
  done
  # 一个都不存在：优先用 xdg 给的路径（稍后 mkdir）；没有就用 ~/Desktop
  [ -n "$DESKTOP_DIR" ] || DESKTOP_DIR="${_d1:-$HOME/Desktop}"
fi

ICON_BASE="$DATA_HOME/icons/hicolor"
APPS_DIR="$DATA_HOME/applications"
DESKTOP_FILE="$APPS_DIR/$APP_ID.desktop"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

MODE="all"
case "${1:-}" in
  --desktop) MODE="desktop" ;;
  --menu)    MODE="menu" ;;
  --uninstall) MODE="uninstall" ;;
  "") ;;
  *) die "未知参数: $1（用 --desktop / --menu / --uninstall）" ;;
esac

# ---------------------------------------------------------------- 卸载
if [ "$MODE" = "uninstall" ]; then
  say "卸载桌面快捷方式…"
  rm -f "$DESKTOP_DIR/$APP_NAME.desktop" "$DESKTOP_DIR/$APP_ID.desktop"
  rm -f "$DESKTOP_FILE"
  for s in 256 128 64 48 32; do rm -f "$ICON_BASE/${s}x${s}/apps/$APP_ID.png"; done
  command -v update-desktop-database >/dev/null 2>&1 && \
    update-desktop-database "$APPS_DIR" 2>/dev/null || true
  say "完成（游戏文件本身没动，play-pvz.sh 仍可直接用）"
  exit 0
fi

[ -x "$ROOT/play-pvz.sh" ] || die "找不到可执行的 play-pvz.sh（应在 $ROOT）"
[ -x "$ROOT/run-game.sh" ] || die "找不到可执行的 run-game.sh（应在 $ROOT）"

# ---------------------------------------------------------------- 图标
say "准备图标…"
if [ ! -f "$ROOT/icons/pvz-256.png" ]; then
  python3 "$ROOT/make-icons.py" || die "图标生成失败（需要 python3-pil）"
fi
for s in 256 128 64 48 32; do
  d="$ICON_BASE/${s}x${s}/apps"
  mkdir -p "$d" 2>/dev/null && cp -f "$ROOT/icons/pvz-$s.png" "$d/$APP_ID.png" 2>/dev/null || true
done
# 主题缓存（失败无所谓，桌面文件里也会写绝对路径兜底）
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$ICON_BASE" >/dev/null 2>&1 || true
fi
say "图标已装到 $ICON_BASE（主题名: $APP_ID）"

# ---------------------------------------------------------------- .desktop
say "生成 .desktop…"
mkdir -p "$APPS_DIR"

# 用共享库生成内容，保证和 run-game.sh 的自愈逻辑逐字节一致
# shellcheck source=lib-desktop.sh
. "$ROOT/lib-desktop.sh"

# 建立固定路径启动器链接：.desktop 指向它，于是项目解压到哪都能用，
# 而且首次双击就能成功（不需要先开终端跑一次）。
if pvz_ensure_bootstrap_link "$ROOT"; then
  say "启动器链接: $PVZ_BOOTSTRAP -> $ROOT/pvz-hybrid-bootstrap.sh"
else
  warn "无法建立启动器链接（$PVZ_BOOTSTRAP），快捷方式将退回项目绝对路径"
  warn "项目一旦移动需要重新运行本脚本"
fi

pvz_desktop_content "$ROOT" > "$DESKTOP_FILE"

# 同时把项目自带那份也刷新，避免用户直接双击它时指向旧路径
pvz_desktop_content "$ROOT" > "$ROOT/$APP_NAME.desktop" 2>/dev/null || true

chmod +x "$DESKTOP_FILE" "$ROOT/$APP_NAME.desktop" 2>/dev/null || true
# 用 desktop-file-validate 自检（有就检查）
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$DESKTOP_FILE" && say "desktop-file-validate: 通过" || warn "校验有告警（通常不影响使用）"
fi

command -v update-desktop-database >/dev/null 2>&1 && \
  update-desktop-database "$APPS_DIR" 2>/dev/null || true

# ---------------------------------------------------------------- 放桌面
if [ "$MODE" = "all" ] || [ "$MODE" = "desktop" ]; then
  # 目录不存在就建一个（xdg-user-dirs 有时只给路径不建目录），别静默跳过
  [ -d "$DESKTOP_DIR" ] || mkdir -p "$DESKTOP_DIR" 2>/dev/null || true
  if [ -d "$DESKTOP_DIR" ]; then
    cp -f "$DESKTOP_FILE" "$DESKTOP_DIR/$APP_NAME.desktop"
    chmod +x "$DESKTOP_DIR/$APP_NAME.desktop"
    # GNOME 需要显式信任，否则桌面图标显示为"未信任的启动器"
    if command -v gio >/dev/null 2>&1; then
      gio set "$DESKTOP_DIR/$APP_NAME.desktop" metadata::trusted true 2>/dev/null || true
    fi
    say "已放到桌面: $DESKTOP_DIR/$APP_NAME.desktop"
  else
    warn "桌面目录不可用（$DESKTOP_DIR），跳过；菜单项已装好，可从应用菜单启动"
  fi
fi

say "完成。"
echo
echo "  双击桌面的「$APP_NAME」即可启动（无终端窗口）。"
echo "  启动日志: $ROOT/logs/latest.log"
echo "  若桌面图标显示为文本/未信任，右键选「允许启动」或执行:"
echo "      gio set \"$DESKTOP_DIR/$APP_NAME.desktop\" metadata::trusted true"
