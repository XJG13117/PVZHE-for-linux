#!/bin/bash
# ============================================================================
# 快捷方式生成逻辑（被 install-desktop.sh 和 run-game.sh 共用）
#
# 核心设计：.desktop 的 Exec 指向一个**固定路径的启动器**
#     ~/.local/bin/pvz-hybrid   （符号链接 -> <项目>/pvz-hybrid-bootstrap.sh）
# 而不是指向项目里的 run-game.sh。原因：
#   - .desktop 规范不支持相对路径；
#   - 写项目绝对路径则换机器/换目录就失效；
#   - 写占位符则首次双击报"找不到文件"。
# 用固定路径的符号链接，项目解压到哪都无所谓，且**首次双击就能成功** ——
# 链接在安装快捷方式时就建好了。
#
# 抽成库的原因：install-desktop.sh 负责安装、run-game.sh 负责启动时核对，
# 两处必须生成完全一致的 .desktop，否则会来回覆盖、来回重装。
# ============================================================================

PVZ_APP_ID="${PVZ_APP_ID:-pvz-hybrid}"
PVZ_APP_NAME="${PVZ_APP_NAME:-植物大战僵尸杂交版}"
PVZ_BOOTSTRAP="${PVZ_BOOTSTRAP:-$HOME/.local/bin/pvz-hybrid}"

# 把 .desktop 内容写到 stdout，由调用方决定落盘位置。
# 参数：<项目根目录>
pvz_desktop_content() {
  local root="$1"
  local exec_path="$PVZ_BOOTSTRAP"
  local exec_field
  # Exec 含空格必须加引号（freedesktop 规范）；不含空格就不加，少踩解析坑
  case "$exec_path" in
    *" "*) exec_field="\"$exec_path\"" ;;
    *)     exec_field="$exec_path" ;;
  esac

  cat <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=$PVZ_APP_NAME
Name[zh_CN]=$PVZ_APP_NAME
Comment=植物大战僵尸杂交重制版 0.29（Godot + .NET 原生运行）
Comment[zh_CN]=植物大战僵尸杂交重制版 0.29（Godot + .NET 原生运行）
Exec=$exec_field
Icon=$PVZ_APP_ID
Terminal=false
Categories=Game;StrategyGame;
Keywords=PVZ;PlantsVsZombies;植物大战僵尸;杂交版;游戏;
StartupNotify=true
StartupWMClass=Godot_Engine
Path=$root
EOF
}

# 确保固定路径的启动器符号链接存在且指向本项目。
# 参数：<项目根目录>。成功返回 0。
pvz_ensure_bootstrap_link() {
  local root="$1"
  local target="$root/pvz-hybrid-bootstrap.sh"
  [ -f "$target" ] || return 1

  local dir; dir="$(dirname "$PVZ_BOOTSTRAP")"
  mkdir -p "$dir" 2>/dev/null || return 1

  local cur=""
  [ -L "$PVZ_BOOTSTRAP" ] && cur="$(readlink -f "$PVZ_BOOTSTRAP" 2>/dev/null)"
  local want; want="$(readlink -f "$target" 2>/dev/null || echo "$target")"

  if [ "$cur" != "$want" ]; then
    rm -f "$PVZ_BOOTSTRAP" 2>/dev/null
    ln -s "$target" "$PVZ_BOOTSTRAP" 2>/dev/null || return 1
  fi
  chmod 755 "$target" 2>/dev/null || true
  [ -x "$PVZ_BOOTSTRAP" ] || return 1
  return 0
}

# 需要重新生成吗？参数：项目根目录。返回 0=需要，1=不需要。
# 只做检查，不产生任何副作用（make-dist.sh 这类只读流程也会调它）。
pvz_desktop_needs_repair() {
  local root="$1"

  # 启动器链接必须存在且指向本项目（项目被移动后要能跟上）
  if [ ! -L "$PVZ_BOOTSTRAP" ]; then return 0; fi
  local cur want
  cur="$(readlink -f "$PVZ_BOOTSTRAP" 2>/dev/null)"
  want="$(readlink -f "$root/pvz-hybrid-bootstrap.sh" 2>/dev/null)"
  [ -n "$want" ] && [ "$cur" = "$want" ] || return 0

  local f
  for f in "$root/$PVZ_APP_NAME.desktop" \
           "${XDG_DATA_HOME:-$HOME/.local/share}/applications/$PVZ_APP_ID.desktop"; do
    [ -f "$f" ] || return 0
    local c
    c="$(grep -m1 '^Exec=' "$f" 2>/dev/null | cut -d= -f2- | tr -d '"')"
    # 旧版本写的是项目绝对路径或占位符 -> 需要升级成固定路径启动器
    [ "$c" = "$PVZ_BOOTSTRAP" ] || return 0
  done
  return 1
}
