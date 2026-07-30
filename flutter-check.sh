#!/usr/bin/env bash
# Flutter 静态检查：用本机匹配项目的 SDK（Flutter 3.44.2 / Dart 3.12.2）跑 analyze。
# 用法：bash flutter-check.sh            # 全量分析
#       bash flutter-check.sh lib/...    # 只分析指定文件/目录
set -e
export PATH="$PATH:/c/Windows/System32/WindowsPowerShell/v1.0:/c/Windows/System32"
FLUTTER="/d/Software/Flutter/flutter/bin/flutter"
# 注意：不要用 /d/Software/Flutter（Dart 3.12.1 不够 ^3.12.2）
#       也不要用 /d/Software/flutter_flutter（OpenHarmony 分支 Dart 3.9.2）。
cd /d/Projects/uten_imp
if [ $# -gt 0 ]; then
  "$FLUTTER" analyze "$@"
else
  "$FLUTTER" analyze
fi
