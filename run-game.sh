#!/bin/bash
# ============================================================================
# 桌面入口（.desktop 双击走这里）
#
# 这个文件是「解压就能用」的关键：.desktop 规范不支持相对路径，所以项目里
# 那份 .desktop 难免带着打包时的绝对路径，换台机器/换个目录就失效。
# 因此每次启动都顺手核对一遍，路径不对就按当前位置重装快捷方式，
# 用户不需要手动跑 install-desktop.sh。
#
# 无终端：全部输出由 play-pvz.sh 写进 logs/play-<时间>.log（logs/latest.log）。
# ============================================================================
set -uo pipefail

# 解析成真实路径：$BASH_SOURCE 给的是被调用的路径，从符号链接目录启动时
# 会不一致（生成 .desktop 用 A 路径、比较用 B 路径 -> 反复重装）。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(readlink -f "$ROOT" 2>/dev/null || echo "$ROOT")"

# .desktop 启动时 PATH 很精简，先补齐，后面才找得到各种命令
for d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin /usr/games; do
  case ":$PATH:" in *":$d:"*) ;; *) PATH="$PATH:$d" ;; esac
done
export PATH

mkdir -p "$ROOT/logs" 2>/dev/null

notify() {  # notify-send 属 libnotify-bin，缺了就静默（不影响游戏）
  command -v notify-send >/dev/null 2>&1 && \
    notify-send --app-name="植物大战僵尸杂交版" --icon="$ROOT/icons/pvz-256.png" \
      "$1" "$2" 2>/dev/null || true
}

# ---------------------------------------------------------------- 自愈：快捷方式
# 项目里那份 .desktop 和系统菜单项可能还指向打包机的路径（.desktop 规范
# 不支持相对路径，做不到可移植）。这里核对一次：不对就按当前位置重装。
# 只动快捷方式、不碰游戏数据；失败也不影响本次启动。
# 用标记文件防止"修不好 -> 每次启动都重试 -> 反复弹窗"。
sh_selfheal() {
  local lib="$ROOT/lib-desktop.sh"
  [ -f "$lib" ] || return 0
  # shellcheck source=lib-desktop.sh
  . "$lib"

  # 先确保固定路径启动器链接指向本项目（项目被移动后，快捷方式靠它自动跟上）
  pvz_ensure_bootstrap_link "$ROOT" 2>/dev/null || true

  pvz_desktop_needs_repair "$ROOT" || return 0

  local stamp="$ROOT/logs/.desktop-repair-tried"
  if [ -f "$stamp" ] && [ -n "$(find "$stamp" -mmin -10 2>/dev/null)" ]; then
    return 0    # 10 分钟内试过了，别再刷
  fi
  mkdir -p "$ROOT/logs" 2>/dev/null
  touch "$stamp" 2>/dev/null || true

  # 先只刷新项目自带那份（快、必定可写），让"直接双击项目里的 .desktop"能正常工作
  pvz_desktop_content "$ROOT" > "$ROOT/$PVZ_APP_NAME.desktop" 2>/dev/null || true
  chmod +x "$ROOT/$PVZ_APP_NAME.desktop" 2>/dev/null || true

  # 再尝试完整重装（桌面 + 菜单）；没有写权限时会失败，属正常
  if [ -x "$ROOT/install-desktop.sh" ]; then
    "$ROOT/install-desktop.sh" >>"$ROOT/logs/launcher.log" 2>&1 || true
  fi
}
sh_selfheal

# ---------------------------------------------------------------- 启动
notify "正在启动" "首次运行需要准备环境，可能要一两分钟…"

"$ROOT/play-pvz.sh" "$@"
rc=$?

if [ "$rc" -ne 0 ]; then
  notify "启动失败（退出码 $rc）" "详情见 logs/latest.log"
  printf '启动失败 rc=%s\n日志: %s/logs/latest.log\n' "$rc" "$ROOT" >&2
fi
exit "$rc"

