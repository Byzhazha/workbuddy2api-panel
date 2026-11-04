#!/usr/bin/env bash
# 服务器侧现状摘要（key=value，供本地 ship-cloud.ps1 解析与人工核对）。
set -uo pipefail

ROOT="${ROOT:-/opt/workbuddy2api-panel}"
CONTAINER="${CONTAINER:-workbuddy2api}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:7863/healthz}"

cd "$ROOT" 2>/dev/null || { echo "repo_commit=unknown"; exit 1; }

echo "repo_commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "repo_subject=$(git log -1 --format='%s' 2>/dev/null | cut -c1-60)"
echo "running_label=$(docker inspect "$CONTAINER" --format '{{index .Config.Labels "wb2api.commit"}}' 2>/dev/null | cut -c1-7)"
echo "container=$(docker inspect "$CONTAINER" --format '{{.State.Status}}/{{.State.Health.Status}}' 2>/dev/null || echo missing)"
echo "image_id=$(docker inspect "$CONTAINER" --format '{{.Image}}' 2>/dev/null | cut -c8-19)"
echo "auths_files=$(ls runtime/auths/*.json 2>/dev/null | wc -l)"
echo "healthz=$(curl -fsS -m 5 "$HEALTH_URL" 2>/dev/null || echo unreachable)"
echo "public_healthz=$(curl -fsS -m 8 https://wkapi.jaycode.online/healthz 2>/dev/null || echo unreachable)"
