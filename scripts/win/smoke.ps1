<#
.SYNOPSIS
  在备用端口上把新二进制真正跑起来一次（canary），验证通过即退出。不碰线上服务。

.DESCRIPTION
  `-h` 只能证明"能加载"，证明不了"能启动"——配置解析、auth 目录、落盘路径这类问题
  只有真跑一遍才暴露。所以换文件前先用一份**隔离配置**在空闲端口起一次：

    - listen  → 备用端口（默认 7899），不与线上的 7863 冲突
    - state_file / 数据目录 → 临时目录（不碰线上 data\state.json）
    - schedule.* → 全部关闭（不会重复签到/上报/清扫，避免两次任务打上游）
    - auth_dir 保持真实路径（只读凭证，才能真的查到余额并渲染 /status）

  起来后轮询 /status 拿到 200 即判定通过，随即结束该进程并清理临时目录。
  期间可能对上游产生 1~2 次只读余额查询（与面板 5 分钟一次同性质）。

.EXAMPLE
  pwsh -File scripts\win\smoke.ps1 -Exe bin\wb2api-20261101-204235-6bdbc71.exe
#>
[CmdletBinding()]
param(
  [string]$Root,
  [Parameter(Mandatory = $true)][string]$Exe,
  [int]$Port = 7899,
  [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$Root = (Resolve-Path $Root).Path
if (-not [System.IO.Path]::IsPathRooted($Exe)) { $Exe = Join-Path $Root $Exe }
$Exe = (Resolve-Path $Exe).Path

$tmp = Join-Path $env:TEMP ("wb2api-smoke-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$cfgPath = Join-Path $tmp 'config.json'
$outLog = Join-Path $tmp 'stdout.log'
$errLog = Join-Path $tmp 'stderr.log'

try {
  $cfg = Get-Content (Join-Path $Root 'config.json') -Raw | ConvertFrom-Json
  $cfg.listen = "127.0.0.1:$Port"
  $cfg.state_file = (Join-Path $tmp 'state.json')
  if (-not $cfg.schedule) { $cfg.schedule = [pscustomobject]@{} }
  foreach ($k in 'activity_enabled', 'balance_refresh_enabled', 'blackcat_enabled', 'checkin_enabled',
    'growth_enabled', 'keepalive_enabled', 'travel_enabled', 'task_sweep_enabled') {
    $cfg.schedule | Add-Member -NotePropertyName $k -NotePropertyValue $false -Force
  }
  $cfg | ConvertTo-Json -Depth 12 | Set-Content $cfgPath -Encoding utf8

  Write-Host "[smoke] 启动 $([System.IO.Path]::GetFileName($Exe)) @ 127.0.0.1:$Port（隔离配置：$tmp）"
  $p = Start-Process -FilePath $Exe -ArgumentList @('-config', "`"$cfgPath`"") -WorkingDirectory $Root `
    -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $ok = $false
  $last = ''
  # /status 在配了 api_key 时也走鉴权（否则返回 401，会被误判成"起不来"）。
  $hdr = @{}
  if ($cfg.api_key) { $hdr['Authorization'] = "Bearer $($cfg.api_key)" }
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if ($p.HasExited) { break }
    try {
      $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/status" -UseBasicParsing -TimeoutSec 3 -Headers $hdr
      if ($r.StatusCode -eq 200) { $ok = $true; $last = 'HTTP 200 /status'; break }
    } catch { $last = $_.Exception.Message }
  }

  if ($ok) {
    Write-Host "[smoke] 通过：$last" -ForegroundColor Green
    exit 0
  }

  Write-Host "[smoke] 失败：$last" -ForegroundColor Red
  if ($p.HasExited) { Write-Host "[smoke] 进程已退出，exit=$($p.ExitCode)" -ForegroundColor Red }
  if (Test-Path $errLog) {
    $e = Get-Content $errLog -Raw
    if ($e) { Write-Host "[smoke] stderr:" -ForegroundColor Red; Write-Host $e }
  }
  if (Test-Path $outLog) {
    $o = Get-Content $outLog -Raw
    if ($o) { Write-Host "[smoke] stdout(尾 20 行):"; ($o -split "`n" | Select-Object -Last 20) -join "`n" }
  }
  exit 1
} finally {
  if ($p -and -not $p.HasExited) {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
  }
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
