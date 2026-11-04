<#
.SYNOPSIS
  监听本地改动 → 自动 ship-cloud（提交 → 推送 → 服务器重建 → 自检）。

.DESCRIPTION
  「本地改了服务器也改」的自动化入口：开着这个窗口，保存代码后约 DebounceSeconds 秒
  自动发布一次。检测方式是轮询 `git status --porcelain`：

    - auths/、data/、config.json、bin/、logs/、backups/ 都在 .gitignore 里，
      所以账号与运行数据不会触发自动发布（它们走 sync-data.ps1，且不适合每次保存都推）；
    - 连续 DebounceSeconds 秒没有新改动才动手，避免编辑器连续保存触发多次构建；
    - 发布失败不会停掉监听，会在日志里记一条并继续等下一次改动。

  发布本身调用 ship-cloud.ps1（同样的测试/推送/回滚语义）。按 Ctrl+C 停止。

.EXAMPLE
  pwsh -File scripts\win\watch-cloud.ps1
#>
[CmdletBinding()]
param(
  [string]$Root,
  [int]$DebounceSeconds = 8,
  [string]$Branch = 'codex/code-review-20261030',
  [string]$Remote = 'fork',
  [string]$Server = 'root@38.76.219.235',
  [int]$Port = 3012,
  [string]$RemoteDir = '/opt/workbuddy2api-panel',
  [switch]$SkipTests,
  [switch]$SyncData
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$Root = (Resolve-Path $Root).Path
Push-Location $Root

$logDir = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'cloud-watch.log'
function Log([string]$m) {
  $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Write-Host $line
  Add-Content -Path $logFile -Value $line -Encoding utf8
}

try {
  Log "开始监听 $Root（防抖 ${DebounceSeconds}s，分支 $Branch，Ctrl+C 停止）"
  $lastSig = ''
  $sigSince = $null

  while ($true) {
    $sig = (@(& git status --porcelain 2>$null) -join "`n")
    $now = Get-Date

    if ($sig -ne $lastSig) {
      $lastSig = $sig
      $sigSince = $now
      if ($sig) {
        $count = @($sig -split "`n" | Where-Object { $_ }).Count
        Log "检测到 $count 处改动，等待 ${DebounceSeconds}s 静默…"
      }
    } elseif ($sig -and ((($now - $sigSince).TotalSeconds) -ge $DebounceSeconds)) {
      $msg = "chore(auto): 自动同步 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
      Log "开始自动发布：$msg"
      $args = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'ship-cloud.ps1'),
        '-Root', $Root, '-Commit', $msg, '-Branch', $Branch, '-Remote', $Remote,
        '-Server', $Server, '-Port', $Port, '-RemoteDir', $RemoteDir)
      if ($SkipTests) { $args += '-SkipTests' }
      if ($SyncData) { $args += '-SyncData' }
      & pwsh @args 2>&1 | ForEach-Object { Log "  $_" }
      $rc = $LASTEXITCODE
      if ($rc -eq 0) { Log '✓ 自动发布完成' } else { Log "✗ 自动发布失败（exit $rc），继续监听" }
      $lastSig = ''
      $sigSince = $null
    }
    Start-Sleep -Seconds 1
  }
} finally {
  Pop-Location
}
