#!/usr/bin/env bash
# 鲸灵健康检查:只记录失败与恢复,不做自动重启(避免掩盖问题)。
set -uo pipefail
LOG=/opt/jingling/health.log
STATUS_FILE=/opt/jingling/.health_last
if curl -fsS -m 5 http://127.0.0.1:3001/health > /dev/null 2>&1; then
  if [ -f "$STATUS_FILE" ] && [ "$(cat "$STATUS_FILE")" = "down" ]; then
    echo "[$(date -Iseconds)] RECOVERED" >> "$LOG"
  fi
  echo up > "$STATUS_FILE"
else
  echo down > "$STATUS_FILE"
  echo "[$(date -Iseconds)] DOWN: /health 无响应" >> "$LOG"
fi