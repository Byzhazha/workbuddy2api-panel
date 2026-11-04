<#
.SYNOPSIS
  本机 → 服务器的 SSH 反向隧道：让服务器的 127.0.0.1:7863 指向本机服务。

.DESCRIPTION
  单实例架构（推荐）：

      公网 https://wkapi.jaycode.online
        → 服务器 nginx → 127.0.0.1:7863（sshd 反向隧道）
          → 本机 127.0.0.1:7863（唯一在跑的那个 wb2api）

  这样账号、余额、用量、请求日志、冷却/禁用状态全都在本机这一份数据里，
  不存在「两边各算各的」。服务器上的容器作为待机副本保留（停用），
  想切回服务器直跑时见 README「云端服务器」一节。

  守护逻辑：ssh 断开就 5 秒后重连；服务器端口被占（容器在跑）会立刻失败并重试，
  日志里能看到原因。开机自启用 scripts\win\tunnel.ps1 注册的计划任务（见 README）。

  常用参数：-WatchdogInterval 重连间隔（秒）；-Once 只跑一次（调试用）。
#>
[CmdletBinding()]
param(
  [string]$Server = 'root@38.76.219.235',
  [int]$Port = 3012,
  [int]$LocalPort = 7863,
  [int]$RemotePort = 7863,
  [int]$WatchdogInterval = 5,
  [switch]$Once
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'tunnel.log'

function Log([string]$m) {
  $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Write-Host $line
  Add-Content -Path $logFile -Value $line -Encoding utf8
}

$sshArgs = @(
  '-N', '-T',
  '-o', 'ExitOnForwardFailure=yes',
  '-o', 'ServerAliveInterval=15',
  '-o', 'ServerAliveCountMax=3',
  '-o', 'TCPKeepAlive=yes',
  '-p', $Port,
  '-R', "127.0.0.1:${RemotePort}:127.0.0.1:${LocalPort}",
  $Server
)

Log "隧道守护启动：服务器 127.0.0.1:${RemotePort} → 本机 127.0.0.1:${LocalPort}（${Server}:${Port}）"
do {
  Log '建立隧道…'
  & ssh @sshArgs 2>&1 | ForEach-Object { Log "  ssh: $_" }
  if ($LASTEXITCODE -ne 0) { Log "隧道断开（exit $LASTEXITCODE），${WatchdogInterval}s 后重连" }
  else { Log "隧道退出，${WatchdogInterval}s 后重连" }
  if (-not $Once) { Start-Sleep -Seconds $WatchdogInterval }
} while (-not $Once)
