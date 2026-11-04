#!/usr/bin/env bash
# 服务器侧部署入口：拉取代码 → 构建镜像 → 替换容器 → 健康检查 → 失败自动回滚。
#
# 设计（与 Windows 的 deploy.ps1 同思路）：
#   1. git fetch/reset 只改代码，不碰 runtime/（账号与数据，已被 .gitignore 排除）；
#   2. 先 docker build 出新镜像，构建失败时线上容器与镜像都不动；
#   3. 构建产物带 wb2api.commit=<完整 sha> 标签，容器已在跑同一提交且健康时直接跳过
#      （watch 反复触发也安全）；
#   4. 替换前把当前镜像打成 :rollback；新容器 90s 内不健康就回滚并重新拉起。
#
# 用法（本地 ship-cloud.ps1 就是这么调的）：
#   bash /opt/workbuddy2api-panel/scripts/linux/deploy.sh
#   FORCE=1 bash .../deploy.sh     # 同一提交也强制重建
#
# 退出码：0 成功（或已是最新）；1 构建/启动失败并已尝试回滚。
set -euo pipefail

ROOT="${ROOT:-/opt/workbuddy2api-panel}"
REPO="${REPO:-https://github.com/Byzhazha/workbuddy2api-panel.git}"
BRANCH="${BRANCH:-codex/code-review-20261030}"
COMPOSE="${COMPOSE:-compose.server.yml}"
IMAGE="${IMAGE:-workbuddy2api-panel:local}"
ROLLBACK_IMAGE="${ROLLBACK_IMAGE:-workbuddy2api-panel:rollback}"
CONTAINER="${CONTAINER:-workbuddy2api}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:7863/healthz}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"
FORCE="${FORCE:-0}"

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

cd "$ROOT" 2>/dev/null || die "找不到部署目录 $ROOT"

# 旧机器上可能有一份未被 git 跟踪的 compose.server.yml，会挡住 checkout —— 先挪走留证。
if [ -f "$COMPOSE" ] && ! git ls-files --error-unmatch "$COMPOSE" >/dev/null 2>&1; then
  mkdir -p /root/backups
  mv "$COMPOSE" "/root/backups/${COMPOSE}.pre-git.$(date +%Y%m%d-%H%M%S)"
  log "已备份未跟踪的 $COMPOSE"
fi

# origin 必须指向自己的 fork（从上游 clone 的机器一键切过来，避免推到只读上游）。
if [ "$(git remote get-url origin 2>/dev/null || true)" != "$REPO" ]; then
  git remote set-url origin "$REPO"
  log "origin → $REPO"
fi

log "拉取 $BRANCH"
git fetch --prune origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" || die "git fetch 失败"
git checkout -q -B "$BRANCH" "origin/$BRANCH" || die "git checkout 失败"
git reset --hard "origin/$BRANCH" >/dev/null || die "git reset 失败"
SHA="$(git rev-parse HEAD)"
SHORT="$(git rev-parse --short HEAD)"
log "代码就位：$SHORT $(git log -1 --format='%s')"

# —— 已在运行同一提交且健康 → 无事可做 ————————————————————————————————
RUNNING_SHA="$(docker inspect "$CONTAINER" --format '{{index .Config.Labels "wb2api.commit"}}' 2>/dev/null || true)"
RUNNING_STATE="$(docker inspect "$CONTAINER" --format '{{.State.Running}}' 2>/dev/null || true)"
if [ "$FORCE" != "1" ] && [ "$RUNNING_SHA" = "$SHA" ] && [ "$RUNNING_STATE" = "true" ] \
   && curl -fsS -m 3 "$HEALTH_URL" >/dev/null 2>&1; then
  log "容器已在跑 $SHORT 且健康，跳过构建"
  exit 0
fi

wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  while [ $SECONDS -lt $deadline ]; do
    if curl -fsS -m 3 "$HEALTH_URL" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

rollback() {
  if docker image inspect "$ROLLBACK_IMAGE" >/dev/null 2>&1; then
    log "回滚到 $ROLLBACK_IMAGE"
    docker tag "$ROLLBACK_IMAGE" "$IMAGE"
    docker compose -f "$COMPOSE" up -d --force-recreate --no-build >/dev/null 2>&1 || true
    if wait_healthy; then
      log "已回滚并恢复：$(curl -fsS -m 3 "$HEALTH_URL")"
    else
      log "CRITICAL: 回滚后仍不健康，请手动检查 docker logs $CONTAINER"
    fi
  else
    log "CRITICAL: 没有回滚镜像，请手动检查 docker logs $CONTAINER"
  fi
  exit 1
}

# —— 回滚点 ——————————————————————————————————————————————————————
CUR_IMAGE_ID="$(docker inspect "$CONTAINER" --format '{{.Image}}' 2>/dev/null || true)"
if [ -n "$CUR_IMAGE_ID" ]; then
  docker tag "$CUR_IMAGE_ID" "$ROLLBACK_IMAGE" 2>/dev/null || true
  log "回滚点已保存：$ROLLBACK_IMAGE ${CUR_IMAGE_ID:0:19}"
fi

# —— 构建（失败不动线上）——————————————————————————————————————————————
log "构建镜像（$SHORT）"
if ! docker build --label "wb2api.commit=$SHA" -t "$IMAGE" . 2>&1 | tail -n 15; then
  die "构建失败，线上未改动"
fi
log "新镜像：$(docker image inspect "$IMAGE" --format '{{.Id}}' | cut -c1-19)"

# —— 替换 + 健康检查 ————————————————————————————————————————————
log "替换容器"
if ! docker compose -f "$COMPOSE" up -d --force-recreate --no-build 2>&1 | tail -n 6; then
  log "docker compose up 失败"
  rollback
fi

if wait_healthy; then
  log "健康检查通过：$(curl -fsS -m 3 "$HEALTH_URL")"
  log "容器：$(docker inspect "$CONTAINER" --format '{{.State.Status}}/{{.State.Health.Status}}' 2>/dev/null || echo unknown)"
  # 每次部署都会产生一个悬空镜像（:local 标签被新镜像占用），只清 3 天前的悬空层，留回滚镜像
  docker image prune -f --filter "until=72h" >/dev/null 2>&1 || true
  log "== 部署完成：$SHORT =="
  exit 0
fi

log "健康检查失败（${HEALTH_TIMEOUT}s）"
rollback
