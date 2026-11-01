<#
.SYNOPSIS
  编译 → 原地替换 → 空闲窗口内重启 → 健康检查 → 失败自动回滚。

.DESCRIPTION
  设计要点（为什么不"停服再编译"）：

    1. 编译、smoke、文件替换都不需要停服务（Windows 允许 rename 运行中的镜像）。
       所以"从敲命令到文件就位"这段时间服务一直是可用的。
    2. 唯一的中断是「停进程 → 起进程」，约 0.3~1 秒。脚本会先轮询 /status 的
       in_flight 总和，等它连续 IdleSettleSeconds 秒为 0 才动手——即挑"没有在途
       请求"的瞬间。客户端只有在恰好在那一瞬发起请求时才会看到连接被拒。
    3. 换成新文件后起不来 → 自动用 wb2api.exe.old 回滚并重新拉起，退出码 1。

  注意：本脚本会重启 wb2api 进程。如果你的对话/客户端正经由它代理（例如
  DeepSeek Harness 走 127.0.0.1:7863），重启那一秒正在生成的流式回复会断。
  所以：**在空闲时执行**，或用 -NoRestart 只换文件、挑自己方便的时候重启。

.EXAMPLE
  # 只编译+替换文件，不重启（零中断；新版在下次重启后生效）
  pwsh -File scripts\win\deploy.ps1 -NoRestart

.EXAMPLE
  # 等空闲后重启（推荐：0.3~1s 窗口，通常客户端无感）
  pwsh -File scripts\win\deploy.ps1

.EXAMPLE
  # 最多等 5 分钟空闲，超时就放弃（服务保持原样，什么都不改）
  pwsh -File scripts\win\deploy.ps1 -IdleTimeoutSeconds 300
#>
[CmdletBinding()]
param(
  [string]$Root,
  [int]$IdleSettleSeconds = 3,
  [int]$IdleTimeoutSeconds = 600,
  [int]$HealthTimeoutSeconds = 25,
  [switch]$NoRestart,
  [switch]$SkipCanary
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$Root = (Resolve-Path $Root).Path
$exe = Join-Path $Root 'wb2api.exe'
$cfg = Join-Path $Root 'config.json'

$logDir = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir ("deploy-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
function Write-Log([string]$m) {
  $line = "{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
  Write-Host $line
  Add-Content -Path $logFile -Value $line -Encoding utf8
}

# ---- 读取监听地址与 api_key（健康检查用；无 api_key 时也能 200） -------------
$listen = '127.0.0.1:7863'
$apiKey = ''
if (Test-Path $cfg) {
  try {
    $c = Get-Content $cfg -Raw | ConvertFrom-Json
    if ($c.listen) { $listen = $c.listen }
    if ($c.api_key) { $apiKey = $c.api_key }
  } catch { Write-Log "WARN: 解析 config.json 失败：$($_.Exception.Message)" }
}
$statusUrl = "http://$listen/status"
$headers = @{}
if ($apiKey) { $headers['Authorization'] = "Bearer $apiKey" }

function Get-Status {
  try { return (Invoke-WebRequest -Uri $statusUrl -UseBasicParsing -TimeoutSec 3 -Headers $headers -ErrorAction Stop).Content | ConvertFrom-Json }
  catch { return $null }
}

function Get-InFlight($st) {
  if ($null -eq $st) { return -1 }
  $sum = 0
  foreach ($a in $st.accounts) { $sum += [int]$a.in_flight }
  return $sum
}

function Get-PanelProcs {
  Get-CimInstance Win32_Process -Filter "Name LIKE 'wb2api%'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$Root*" }
}

# ---- 1. 编译 ---------------------------------------------------------------
Write-Log "== deploy 开始（root=$Root）=="
$built = & (Join-Path $PSScriptRoot 'build.ps1') -Root $Root
Write-Log "编译完成：$(Split-Path -Leaf $built.Path) sha256=$($built.Hash.Substring(0,16))"

# ---- 1.5 canary：用隔离配置在备用端口真跑一次（不碰线上） -------------------
if (-not $SkipCanary) {
  & (Join-Path $PSScriptRoot 'smoke.ps1') -Root $Root -Exe $built.Path
  if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: canary 启动失败，线上服务与 wb2api.exe 均未改动，已中止。"
    exit 3
  }
  Write-Log "canary 通过（新二进制能真正启动并响应 /status）"
}

# ---- 2. 记录当前是否健康（替换前基线） -------------------------------------
$before = Get-Status
Write-Log ("替换前 /status：{0}" -f $(if ($before) { "OK in_flight=$(Get-InFlight $before) healthy=$($before.healthy)" } else { '不可达（服务可能没在跑）' }))

# ---- 3. 原地替换（不停服务） -----------------------------------------------
# 只在两次 rename 之间留下"正式名短暂不存在"的窗口（毫秒级），不依赖任何删除：
#   本机实测（Win11）：正在运行的镜像可以 rename；但被句柄占住的旧备份删不掉
#   （Delete 被拒）。所以旧备份用**唯一时间戳名**，永远不覆盖、也不删除。
$staged = Join-Path $Root 'wb2api.exe.staged'
$backup = Join-Path $Root ("wb2api.exe.old-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Copy-Item $built.Path $staged -Force
Write-Log "新二进制已暂存 → $(Split-Path -Leaf $staged)"

$movedOld = $false
try {
  if (Test-Path $exe) {
    Move-Item $exe $backup
    $movedOld = $true
    Write-Log "旧版已改名 → $(Split-Path -Leaf $backup)"
  }
  Move-Item $staged $exe
  Write-Log "新版已就位 → wb2api.exe（sha256=$(Get-FileHash $exe -Algorithm SHA256 | ForEach-Object { $_.Hash.Substring(0,16) }))"
} catch {
  Write-Log "ERROR: 替换失败：$($_.Exception.Message)"
  if ($movedOld -and -not (Test-Path $exe) -and (Test-Path $backup)) {
    Move-Item $backup $exe
    Write-Log "已把旧文件改回 wb2api.exe"
  }
  Remove-Item $staged -Force -ErrorAction SilentlyContinue
  exit 4
}
# 备份保留最近 3 份（删不掉的就此跳过——本机已见过被句柄占住的情形）。
Get-ChildItem $Root -Filter 'wb2api.exe.old-*' -File -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 |
  ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }

if ($NoRestart) {
  Write-Log "已指定 -NoRestart：文件替换完成，正在跑的进程仍是旧镜像，**下次重启后生效**。"
  Write-Log "手动生效：pwsh -File scripts\win\deploy.ps1   （或重启机器，开机自启会拉起 wb2api.exe）"
  exit 0
}

# ---- 4. 等空闲窗口 ---------------------------------------------------------
Write-Log "等待空闲窗口（in_flight 连续 ${IdleSettleSeconds}s = 0，最长 ${IdleTimeoutSeconds}s）…"
$deadline = (Get-Date).AddSeconds($IdleTimeoutSeconds)
$idleSince = $null
$waited = $false
while ((Get-Date) -lt $deadline) {
  $st = Get-Status
  $nf = Get-InFlight $st
  if ($null -eq $st) {
    Write-Log 'WARN: /status 不可达，按「已停止」处理，直接复用文件替换结果。'
    $waited = $true
    break
  }
  if ($nf -eq 0) {
    if (-not $idleSince) { $idleSince = Get-Date }
    if (((Get-Date) - $idleSince).TotalSeconds -ge $IdleSettleSeconds) { $waited = $true; break }
  } else {
    $idleSince = $null
  }
  Start-Sleep -Milliseconds 400
}
if (-not $waited) {
  Write-Log "放弃重启：${IdleTimeoutSeconds}s 内始终有在途请求。文件已换成新版，但进程未重启（下次重启生效）。"
  exit 2
}
Write-Log "命中空闲窗口，开始重启（中断 ≈ 0.3~1s）"

# ---- 5. 停 → 起 → 健康检查 -------------------------------------------------
$procs = @(Get-PanelProcs)
foreach ($p in $procs) {
  Write-Log "停止 PID $($p.ProcessId)"
  Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}
$stopDeadline = (Get-Date).AddSeconds(10)
while ((@(Get-PanelProcs)).Count -gt 0 -and (Get-Date) -lt $stopDeadline) { Start-Sleep -Milliseconds 200 }
if ((@(Get-PanelProcs)).Count -gt 0) { Write-Log "WARN: 仍有进程未退出，继续尝试启动" }

function Start-Panel {
  Start-Process -FilePath $exe -ArgumentList @('-config', "`"$cfg`"") -WorkingDirectory $Root -WindowStyle Hidden
}
Start-Panel
Write-Log "已拉起 wb2api.exe，等待健康检查（最长 ${HealthTimeoutSeconds}s）…"

$healthy = $false
$hDeadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)
while ((Get-Date) -lt $hDeadline) {
  Start-Sleep -Milliseconds 400
  $st = Get-Status
  if ($st -and $st.healthy -ne $null) { $healthy = $true; break }
}
if ($healthy) {
  Write-Log ("重启成功：healthy=$(Get-InFlight $st) 账号数=$($st.total)，/status OK")
  Write-Log "== deploy 结束 =="
  exit 0
}

# ---- 6. 回滚 ---------------------------------------------------------------
Write-Log "ERROR: 新版本健康检查失败，回滚到 $(Split-Path -Leaf $backup)"
foreach ($p in @(Get-PanelProcs)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500
$cur = Join-Path $Root ("wb2api.exe.bad-{0}" -f (Get-Date -Format 'HHmmss'))
if (Test-Path $backup) {
  if (Test-Path $exe) { Move-Item $exe $cur -ErrorAction SilentlyContinue }   # 留证据，不删
  Move-Item $backup $exe
  Start-Panel
  Start-Sleep -Seconds 3
  $st = Get-Status
  if ($st) { Write-Log "已回滚并恢复服务（in_flight=$(Get-InFlight $st)）；坏版本留在 $(Split-Path -Leaf $cur)" }
  else { Write-Log "CRITICAL: 回滚后仍不可达，请手动检查：$exe -config $cfg" }
} else {
  Write-Log "CRITICAL: 没有可回滚的备份，请手动检查"
}
exit 1
