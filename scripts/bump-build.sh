#!/bin/bash
# 每次往 TestFlight 传新 build 前跑一次：CURRENT_PROJECT_VERSION 全工程 +1。
# 同一版本号(MARKETING_VERSION)下，App Store Connect 要求每个上传的 build 号唯一且递增。
set -euo pipefail
cd "$(dirname "$0")/.."
PBX="BetterCalendar.xcodeproj/project.pbxproj"

CUR=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PBX" | sed 's/[^0-9]//g')
NEW=$((CUR + 1))
COUNT_BEFORE=$(grep -c "CURRENT_PROJECT_VERSION = $CUR;" "$PBX")

sed -i '' "s/CURRENT_PROJECT_VERSION = $CUR;/CURRENT_PROJECT_VERSION = $NEW;/g" "$PBX"

COUNT_AFTER=$(grep -c "CURRENT_PROJECT_VERSION = $NEW;" "$PBX")
if [ "$COUNT_BEFORE" != "$COUNT_AFTER" ]; then
  echo "❌ 断言失败：改前 $COUNT_BEFORE 处、改后 $COUNT_AFTER 处，请检查 $PBX"
  exit 1
fi
echo "✅ build 号 $CUR → $NEW（$COUNT_AFTER 处，app+widget+tests 同步）"
