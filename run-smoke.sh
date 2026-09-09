#!/bin/bash
# Дымовые тесты на живом текстовом поле: печатает в собственное окно
# и проверяет результат. Работающее приложение на время останавливается,
# иначе исправлять будут сразу два экземпляра.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
# Тестируем именно установленную копию: разрешения macOS выданы ей,
# а сборка в build/ управлять вводом не имеет права
APP="/Applications/LayoutGlow.app"
if [ ! -d "$APP" ]; then
    echo "Сначала установите приложение: ./install.sh" >&2
    exit 1
fi

WAS_RUNNING=0
if pgrep -x LayoutGlow >/dev/null; then WAS_RUNNING=1; pkill -x LayoutGlow; sleep 1; fi

# Запуск через open: иначе macOS считает владельцем разрешений терминал,
# и приложение не сможет ни печатать, ни читать поле
LOG="$HOME/Library/Application Support/LayoutGlow/smoke.log"
rm -f "$LOG"
open -n -W -a "$APP" --args --smoke-test
STATUS=0
if [ -f "$LOG" ]; then
    cat "$LOG"
    grep -q "^Провалено" "$LOG" && STATUS=1
else
    echo "Дымовые тесты не оставили отчёта — приложение не запустилось." >&2
    STATUS=1
fi

if [ "$WAS_RUNNING" = "1" ]; then open -a /Applications/LayoutGlow.app; fi
exit $STATUS
