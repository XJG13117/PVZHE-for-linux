#!/bin/bash
# ============================================================================
# 固定路径启动器（自举用）
#
# 为什么需要它：.desktop 规范不支持相对路径，所以包内那份 .desktop 没法写成
# "在项目旁边找 run-game.sh"。直接写打包机的绝对路径，换台机器就失效；
# 写占位符又会导致首次双击"找不到文件"。
#
# 解法：让 .desktop 永远指向这个**固定路径**（~/.local/bin/pvz-hybrid），
# 它只是一个指向项目真实位置的符号链接。于是：
#   - 项目解压到哪都无所谓
#   - 首次双击就能成功（符号链接在安装快捷方式时就建好了）
# 由 install-desktop.sh 建立链接，本脚本负责被调用后转交真正的入口。
# ============================================================================
set -uo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
PROJ="$(cd "$(dirname "$SELF")" && pwd)"

if [ ! -x "$PROJ/run-game.sh" ]; then
  # 链接坏了（项目被移动或删除）——给个明确提示，别静默消失
  command -v notify-send >/dev/null 2>&1 && \
    notify-send --app-name="植物大战僵尸杂交版" \
      "找不到游戏目录" "启动器链接已失效：$PROJ" 2>/dev/null || true
  printf '启动器链接已失效，指向: %s\n请在项目目录里重新运行 ./install-desktop.sh\n' "$PROJ" >&2
  exit 1
fi

exec "$PROJ/run-game.sh" "$@"
