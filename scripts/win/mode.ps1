<#
.SYNOPSIS
  在「本机单实例（服务器反向隧道）」和「服务器自己跑」之间切换。

.DESCRIPTION
  默认模式（Local）：服务器只做入口，公网流量经 SSH 反向隧道转回本机，
  全局只有一个 wb2api 实例，账号/余额/用量/日志天然一致。

  备用模式（Server）：服务器上的容器自己跑（本机可以关机）。切过去时会先把
  本地账号与数据同步到服务器，再从服务器对外服务。

  两种模式不能同时跑（都要占服务器 127.0.0.1:7863）。本脚本会先把另一边停掉。

.EXAMPLE
  # 切回本机为主（默认）
  pwsh -File scripts\win\mode.ps1 -Mode Local

.EXAMPLE
  # 出差/关机时切到服务器自跑
  pwsh -File scripts\win\mode.ps1 -Mode Server
#>
[CmdletBinding()]
param(
  [ValidateSet('Local', 'Server')]
  [string]$Mode = 'Local',
  [string]$Root,
  [string]$Server = 'root@38.76.219.235',
  [int]$Port = 3012,
  [string]$RemoteDir = '/opt/workbuddy2api-panel',
  [switch]$SkipDataSync,
  [switch]$Deploy,
  [switch]$NoVerify
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$Root = (Resolve-Path $Root).Path
$taskName = 'wb2api-tunnel'

function Step([string]$m) { Write-Host "`n── $m ──" -ForegroundColor Cyan }
function Remote([string]$cmd) { & ssh -p $Port $Server $cmd }

function Wait-Public([int]$Seconds = 30) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  do {
    try {
      $h = Invoke-RestMethod -Uri 'https://wkapi.jaycode.online/healthz' -TimeoutSec 5
      if ($h.total -gt 0) { Write-Host "  公网 OK：total=$($h.total) healthy=$($h.healthy)" -ForegroundColor Green; return $true }
    } catch { }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  Write-Host '  公网健康检查超时' -ForegroundColor Red
  return $false
}

if ($Mode -eq 'Server') {
  # —— 1. 停隧道，让出服务器 7863 ————————————————————————————————
  Step '停止本机隧道'
  & schtasks /End /TN $taskName 2>&1 | Out-Null
  # /End 只结束计划任务进程，ssh 子进程可能还活着并占着服务器端口，这里一并清掉。
  Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*127.0.0.1:7863:127.0.0.1:7863*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  $deadline = (Get-Date).AddSeconds(15)
  do {
    $busy = & ssh -p $Port $Server "ss -ltn 2>/dev/null | grep -q '127.0.0.1:7863'" 2>&1
    if ($LASTEXITCODE -ne 0) { break }
    Start-Sleep -Seconds 1
  } while ((Get-Date) -lt $deadline)
  if ($LASTEXITCODE -eq 0) { Write-Host '  警告：服务器 7863 仍被占用，继续尝试' -ForegroundColor Yellow }

  # —— 1.5 可选：先把最新代码发布到服务器（服务器镜像可能停在旧提交）——
  if ($Deploy) {
    Step '发布最新代码到服务器'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'ship-cloud.ps1') -Root $Root -Server $Server -Port $Port -RemoteDir $RemoteDir -SkipTests
    if ($LASTEXITCODE -ne 0) { Write-Host '代码发布失败，切回本机模式以免公网中断' -ForegroundColor Red; & schtasks /Run /TN $taskName | Out-Null; exit 1 }
  }

  # —— 2. 同步本地账号与数据到服务器 ————————————————————————————
  if (-not $SkipDataSync) {
    Step '同步本地账号与数据 → 服务器'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'sync-data.ps1') -Root $Root -Server $Server -Port $Port -RemoteDir $RemoteDir
    if ($LASTEXITCODE -ne 0) { Write-Host '数据同步失败，切回本机模式以免公网中断' -ForegroundColor Red; & schtasks /Run /TN $taskName | Out-Null; exit 1 }
  }

  # —— 3. 拉起服务器容器并确认自启 ————————————————————————————
  Step '启动服务器实例'
  Remote 'cd /opt/workbuddy2api-panel && docker compose -f compose.server.yml up -d --no-build && docker update --restart=unless-stopped workbuddy2api' 2>&1 | Write-Host
  if (-not $NoVerify) { Step '验证公网'; if (-not (Wait-Public)) { exit 1 } }
  Write-Host "`n✓ 已切到服务器直跑：本机可以关机/断网（服务器容器 restart=unless-stopped）" -ForegroundColor Green
  exit 0
}

# —— Local：本机为主 ————————————————————————————————————————————
Step '停止服务器实例（保留镜像与数据，作为待机副本）'
Remote 'docker update --restart=no workbuddy2api && docker stop workbuddy2api 2>/dev/null; ss -ltnp 2>/dev/null | grep ":7863" || echo "7863 已让出"' 2>&1 | Write-Host

Step '启动本机隧道（服务器 127.0.0.1:7863 → 本机 127.0.0.1:7863）'
& schtasks /Run /TN $taskName 2>&1 | Out-Null

if (-not $NoVerify) { Step '验证公网'; if (-not (Wait-Public)) { Write-Host '  检查 logs\tunnel.log 与 schtasks /Query /TN wb2api-tunnel' -ForegroundColor Yellow; exit 1 } }
Write-Host "`n✓ 已切回本机单实例：公网流量经服务器 nginx → SSH 隧道 → 本机 wb2api" -ForegroundColor Green
