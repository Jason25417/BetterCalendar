#!/bin/zsh
# W17：建立 Dev 版智能体工作区 BetterCalendar_AgentRuntime-dev（智能体运行时仓库的 git worktree，分支 dev）。
# - 日用版工作区 BetterCalendar_AgentRuntime（main）一律不动：只接收在 Dev 测过、合并好的改动。
# - Dev 工作区有自己的 bridge/（标记 bridge/CHANNEL = dev，日用版 App 拒连）、自己的记忆副本、自己的调度状态与会话。
# - 只生成 LaunchAgent plist，不安装；最后打印安装命令给 Jason。
# 可重复运行（已存在就只补缺的目录/文件）。测试时可用环境变量 BC_RUNTIME_DIR / BC_RUNTIME_DEV_DIR 指向别处。
set -euo pipefail
RUNTIME="${BC_RUNTIME_DIR:-$HOME/Developer/App Development/BetterCalendar_AgentRuntime}"
DEV="${BC_RUNTIME_DEV_DIR:-$HOME/Developer/App Development/BetterCalendar_AgentRuntime-dev}"
BRANCH=dev
LABEL=com.jason.bettercalendar.agent-dispatch-dev
HERE="${0:A:h}"
NODE="$(command -v node || echo /opt/homebrew/bin/node)"

[[ -d "$RUNTIME/.git" ]] || { echo "❌ 找不到智能体运行时仓库：$RUNTIME"; exit 1; }

if [[ -e "$DEV" ]]; then
  git -C "$DEV" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "❌ $DEV 已存在但不是 git 工作区，没动它"; exit 1; }
  echo "• Dev 工作区已存在：$DEV（分支 $(git -C "$DEV" branch --show-current)）"
else
  if git -C "$RUNTIME" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git -C "$RUNTIME" worktree add "$DEV" "$BRANCH"
  else
    git -C "$RUNTIME" worktree add -b "$BRANCH" "$DEV" main
  fi
  echo "✅ 已建 Dev 工作区：$DEV（分支 $BRANCH，起点 = 日用版 main）"
fi

# 自己的 bridge/（目录本身被 .gitignore 忽略，各工作区各一份）
for d in events events/processed events/failed proposals results results/messages messages chat activity runtime; do
  mkdir -p "$DEV/bridge/$d"
done
print -n dev > "$DEV/bridge/CHANNEL"
EXCLUDE="$(git -C "$RUNTIME" rev-parse --git-common-dir)/info/exclude"
[[ "$EXCLUDE" = /* ]] || EXCLUDE="$RUNTIME/$EXCLUDE"
mkdir -p "${EXCLUDE:h}"; touch "$EXCLUDE"
for pat in bridge/CHANNEL "dispatch/$LABEL.plist"; do grep -qxF "$pat" "$EXCLUDE" || echo "$pat" >> "$EXCLUDE"; done
echo "✅ bridge/CHANNEL = dev（日用版 App 不会连这个目录，Dev 版 App 只连它）"

# LaunchAgent plist（只生成，不安装）
PLIST="$DEV/dispatch/$LABEL.plist"
sed -e "s|__DEV__|$DEV|g" -e "s|__NODE__|$NODE|g" "$HERE/$LABEL.plist" > "$PLIST"
plutil -lint "$PLIST" >/dev/null
echo "✅ 已生成调度 plist：$PLIST"

cat <<MSG

—— 接下来由 Jason 本人做（Claude 不装常驻项）——
1) 装 Dev 调度（盯 Dev 的 bridge/events，与日用版调度互不相干）：
   cp "$PLIST" ~/Library/LaunchAgents/
   launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/$LABEL.plist
   # 停用：launchctl bootout gui/\$(id -u)/$LABEL && rm ~/Library/LaunchAgents/$LABEL.plist
2) 打开「BetterCalendar Dev」→ 多端审批 → 连接 bridge 文件夹，选：
   $DEV/bridge
3) 工作流：智能体改动先合进分支 $BRANCH、在 Dev 工作区测；测过再合进 main（日用版工作区）。
MSG
