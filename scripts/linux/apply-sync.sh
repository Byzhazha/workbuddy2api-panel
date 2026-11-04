#!/usr/bin/env bash
# 服务器侧数据落盘：把 /tmp/wb2api-sync-*.tgz（auths/ + data/ + config.json）应用到 runtime/。
#
# 安全顺序：备份 runtime → 停容器 → 临时目录解包 → 原子替换 → 修属主/权限 → 拉起 → 健康检查。
# 半途失败时备份仍在 /root/backups/，可手工还原。
#
# 用法：
#   bash scripts/linux/apply-sync.sh /tmp/wb2api-sync.tgz
set -euo pipefail

TARBALL="${1:-}"
ROOT="${ROOT:-/opt/workbuddy2api-panel}"
COMPOSE="${COMPOSE:-compose.server.yml}"
CONTAINER="${CONTAINER:-workbuddy2api}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:7863/healthz}"

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }

if [ -z "$TARBALL" ] || [ ! -f "$TARBALL" ]; then
  echo "用法：bash $0 /tmp/wb2api-sync.tgz" >&2
  exit 1
fi

cd "$ROOT" || { echo "找不到 $ROOT" >&2; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
mkdir -p /root/backups
BACKUP="/root/backups/wb2api-runtime-$TS-pre-sync.tar.gz"
log "备份 runtime → $BACKUP"
tar -czf "$BACKUP" -C "$ROOT" runtime

log "停止容器（同步期间不接受写入）"
docker stop "$CONTAINER" >/dev/null 2>&1 || true

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar -xzf "$TARBALL" -C "$TMP"
[ -d "$TMP/auths" ] || { echo "同步包缺少 auths/" >&2; exit 1; }
[ -f "$TMP/config.json" ] || { echo "同步包缺少 config.json" >&2; exit 1; }

log "替换 runtime/auths 与 runtime/data"
rm -rf runtime/auths runtime/data
cp -a "$TMP/auths" runtime/auths
cp -a "$TMP/data" runtime/data
cp -a "$TMP/config.json" runtime/config.json

# 容器以 uid 10001 运行；本地打包带上来的属主/权限在服务器上不可信，统一重设。
chown -R 10001:10001 runtime/auths runtime/data runtime/config.json
chmod 700 runtime/auths runtime/data
find runtime/auths runtime/data -maxdepth 1 -type f -name '*.json' -exec chmod 600 {} +
chmod 600 runtime/config.json
[ -d runtime/data/request-logs ] && chmod 755 runtime/data/request-logs

log "拉起容器"
docker compose -f "$COMPOSE" up -d --force-recreate --no-build >/dev/null

for _ in $(seq 1 45); do
  if curl -fsS -m 3 "$HEALTH_URL" >/dev/null 2>&1; then
    log "健康检查通过：$(curl -fsS -m 3 "$HEALTH_URL")"
    log "auths 文件数：$(ls runtime/auths/*.json 2>/dev/null | wc -l)"
    exit 0
  fi
  sleep 2
done

log "ERROR: 同步后健康检查失败；备份：$BACKUP"
log "手工还原示例：tar -xzf $BACKUP -C $ROOT && docker compose -f $COMPOSE up -d --force-recreate --no-build"
exit 1
