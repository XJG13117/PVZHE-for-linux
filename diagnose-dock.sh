#!/bin/bash
# ============================================================================
# 诊断 Dock/任务栏图标与名称不正常的根因
#
# 用法：先启动游戏，让它停在主界面，然后另开一个终端跑
#     ./diagnose-dock.sh
#
# GNOME Dock 靠「窗口标识」把窗口关联到 .desktop，从而取图标和名称：
#   - Wayland 原生窗口 -> xdg-toplevel 的 app_id
#   - XWayland 窗口    -> WM_CLASS
# 关联不上时，Dock 只能退回显示窗口标题（如果标题本身有问题就显示乱码）
# 并用一个通用图标。这个脚本把真实标识查出来，好对症下药。
# ============================================================================
set -uo pipefail

echo "会话类型: XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-?}  WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-?}  DISPLAY=${DISPLAY:-?}"
echo

found=0

# ---------------------------------------------------- 1) X11 / XWayland 窗口
if command -v xprop >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
  echo "=== X11/XWayland 窗口（找游戏窗口的 WM_CLASS / _NET_WM_NAME） ==="
  # 列出所有窗口 id
  ids="$(xprop -root _NET_CLIENT_LIST 2>/dev/null | sed 's/.*# //; s/,//g')"
  if [ -z "$ids" ]; then
    echo "  （拿不到 _NET_CLIENT_LIST；当前会话可能是纯 Wayland，见下面第 2 节）"
  fi
  for id in $ids; do
    cls="$(xprop -id "$id" WM_CLASS 2>/dev/null | sed 's/^WM_CLASS(STRING) = //')"
    nm="$(xprop -id "$id" _NET_WM_NAME 2>/dev/null | sed 's/^_NET_WM_NAME(UTF8_STRING) = //')"
    case "$cls$nm" in
      *[Gg]odot*|*杂交*|*PlantsVsZombies*)
        echo "  ── 匹配到疑似游戏窗口 ──"
        echo "     WM_CLASS   : $cls"
        echo "     _NET_WM_NAME: $nm"
        echo "     (WM_CLASS 的第二个值就是 GNOME 用来匹配 .desktop 的字符串)"
        found=1
        ;;
    esac
  done
  [ "$found" = 1 ] || echo "  （X11 侧没找到游戏窗口 —— 说明它跑在原生 Wayland 上）"
else
  echo "=== 跳过 X11 检测（没有 xprop 或 DISPLAY） ==="
fi

echo

# ---------------------------------------------------- 2) Wayland 原生窗口 app_id
echo "=== Wayland 原生窗口 app_id ==="
if command -v gdbus >/dev/null 2>&1; then
  out="$(gdbus call --session --dest org.gnome.Shell \
        --object-path /org/gnome/Shell \
        --method org.gnome.Shell.Eval \
        'global.get_window_actors().map(a=>a.meta_window.get_wm_class()+" | "+a.meta_window.get_title()).join("\n")' 2>&1)"
  case "$out" in
    *"(true,"*)
      echo "$out" | sed 's/^(true, //; s/)$//' | tr -d "'\"" | sed 's/\\n/\n/g' | sed 's/^/  /'
      ;;
    *)
      echo "  GNOME Shell 拒绝求值（新版 GNOME 默认禁用 Eval）。"
      echo "  可以用下面这条替代（需要在游戏运行时执行）："
      echo "      xprop -root _NET_CLIENT_LIST"
      echo "      xprop -id <窗口ID> WM_CLASS"
      ;;
  esac
else
  echo "  gdbus 不可用，跳过"
fi

echo

# ---------------------------------------------------- 3) 当前 .desktop 状态
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(readlink -f "$ROOT" 2>/dev/null || echo "$ROOT")"
echo "=== 当前安装的 .desktop ==="
for f in "$ROOT/植物大战僵尸杂交版.desktop" \
         "${XDG_DATA_HOME:-$HOME/.local/share}/applications/pvz-hybrid.desktop"; do
  if [ -f "$f" ]; then
    echo "  $f"
    grep -E '^(Name|Exec|Icon|StartupWMClass)=' "$f" | sed 's/^/      /'
  fi
done

echo
echo "把上面 WM_CLASS（或 app_id）那一行发我，就能把 StartupWMClass 配对。"
