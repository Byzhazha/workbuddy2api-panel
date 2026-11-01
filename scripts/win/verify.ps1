<#
.SYNOPSIS
  校验「开机自启 → 启动的文件 → 运行中的进程」三者是否都是最新的，并给出结论。

.DESCRIPTION
  回答三个具体问题：
    1. 开机自启到底挂在哪儿、它启动的是什么？（启动文件夹 VBS / 计划任务 / 注册表 Run）
    2. 自启指向的 wb2api.exe，是不是我最近一次编译出来的那一份？（比 SHA256）
    3. 现在跑着的进程，用的是新文件还是旧镜像？（比"文件修改时间"与"进程启动时间"）

  判据说明：Windows 允许替换运行中的 exe 镜像文件，所以存在一种常见状态——
  **磁盘上是新版、进程里还是旧版**。此时"exe 文件的写入时间 > 进程启动时间"，
  脚本据此判定「需重启才生效」，而不是拿哈希说"已是最新"。

.EXAMPLE
  pwsh -File scripts\win\verify.ps1

.EXAMPLE
  # 顺便对比某个指定构建产物
  pwsh -File scripts\win\verify.ps1 -Artifact bin\wb2api-20261101-204235-6bdbc71.exe
#>
[CmdletBinding()]
param(
  [string]$Root,
  [string]$Artifact
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$Root = (Resolve-Path $Root).Path
$exe = Join-Path $Root 'wb2api.exe'
$ok = $true

function Line([string]$k, $v) { Write-Host ("  {0,-22} {1}" -f $k, $v) }
function Bad([string]$m) { Write-Host "  ✗ $m" -ForegroundColor Red; $script:ok = $false }
function Good([string]$m) { Write-Host "  ✓ $m" -ForegroundColor Green }

Write-Host "`n=== 1. 开机自启 ===" -ForegroundColor Cyan
$autostart = @()

$startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
if (Test-Path $startup) {
  foreach ($f in @(Get-ChildItem $startup -File -ErrorAction SilentlyContinue)) {
    $hit = $false
    if ($f.Extension -in '.vbs', '.bat', '.cmd', '.ps1') {
      # 不能用 -SimpleMatch：模式里的 | 会被当成字面量。这里按正则匹配两个关键词之一。
      $hit = [bool](Select-String -Path $f.FullName -Pattern 'wb2api|workbuddy2api' -Quiet -ErrorAction SilentlyContinue)
    } elseif ($f.Extension -eq '.lnk') {
      $sh = New-Object -ComObject WScript.Shell
      $hit = $sh.CreateShortcut($f.FullName).TargetPath -match 'wb2api'
    }
    if ($hit) { $autostart += [pscustomobject]@{ Kind = '启动文件夹'; Name = $f.Name; Path = $f.FullName } }
  }
}

foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
  $acts = $t.Actions | Where-Object { $_.Execute -match 'wb2api|powershell|pwsh' -and ($_.Execute + ' ' + $_.Arguments) -match 'wb2api' }
  if ($acts) { $autostart += [pscustomobject]@{ Kind = '计划任务'; Name = $t.TaskName; Path = ($acts.Execute + ' ' + $acts.Arguments) } }
}

foreach ($k in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run')) {
  if (Test-Path $k) {
    (Get-ItemProperty $k).PSObject.Properties | Where-Object { $_.Value -is [string] -and $_.Value -match 'wb2api' } |
      ForEach-Object { $autostart += [pscustomobject]@{ Kind = '注册表 Run'; Name = $_.Name; Path = $_.Value } }
  }
}

$services = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'wb2|workbuddy' })
if ($services.Count -gt 0) {
  foreach ($s in $services) { $autostart += [pscustomobject]@{ Kind = 'Windows 服务'; Name = $s.Name; Path = $s.Status } }
}

if ($autostart.Count -eq 0) {
  Bad '没找到任何开机自启项——重启后不会自动启动'
} else {
  foreach ($a in $autostart) { Line $a.Kind "$($a.Name) → $($a.Path)" }
  Good "找到 $($autostart.Count) 个自启项"
}

# 自启 VBS 的写法检查：是否有防重复实例 + 是否固定工作目录 + 启动的是哪个 exe
$vbs = $autostart | Where-Object { $_.Path -like '*.vbs' } | Select-Object -First 1
if ($vbs) {
  $txt = Get-Content $vbs.Path -Raw
  $launchTarget = ([regex]::Match($txt, '([A-Za-z]:\\[^"]*wb2api[^"]*\.exe)')).Groups[1].Value
  Line 'VBS 启动目标' $launchTarget
  if ($txt -match 'CurrentDirectory') { Good 'VBS 固定了工作目录（相对路径的 auths/data 不会跑偏）' } else { Bad 'VBS 没设置 CurrentDirectory' }
  if ($txt -match 'Win32_Process') { Good 'VBS 有防重复实例保护' } else { Bad 'VBS 没有防重复实例保护' }
  if ($launchTarget) {
    $target = $launchTarget
    if (-not (Test-Path $target)) { Bad "自启指向的 exe 不存在：$target" }
    else { Good "自启指向的 exe 存在：$target" }
  }
}

Write-Host "`n=== 2. 文件：自启目标 vs 最新构建 ===" -ForegroundColor Cyan
$latestBuild = $null
$binDir = Join-Path $Root 'bin'
if (Test-Path $binDir) {
  $latestBuild = Get-ChildItem $binDir -Filter 'wb2api-*.exe' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if ($Artifact) { $latestBuild = Get-Item (Join-Path $Root $Artifact) }

$exeHash = if (Test-Path $exe) { (Get-FileHash $exe -Algorithm SHA256).Hash } else { $null }
if (-not $exeHash) { Bad "找不到 $exe" } else { Line 'wb2api.exe sha256' $exeHash.Substring(0, 16) }
Line 'wb2api.exe 写入时间' $(if (Test-Path $exe) { (Get-Item $exe).LastWriteTime } else { '-' })

if ($latestBuild) {
  $bHash = (Get-FileHash $latestBuild.FullName -Algorithm SHA256).Hash
  Line '最新构建' "$($latestBuild.Name)（$($latestBuild.LastWriteTime)）"
  Line '最新构建 sha256' $bHash.Substring(0, 16)
  if ($exeHash -eq $bHash) { Good '正式名 = 最新构建（字节一致）' }
  else { Bad '正式名 ≠ 最新构建：跑的不是你最后编译的那份' }
} else {
  Write-Host '  （bin\ 里没有版本化产物，跳过对比；先跑 build.ps1 才有）' -ForegroundColor Yellow
}

Write-Host "`n=== 3. 运行中的进程 ===" -ForegroundColor Cyan
$procs = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'wb2api%'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -like "*$Root*" })
if ($procs.Count -eq 0) {
  Bad '当前没有在跑的 wb2api 进程'
} else {
  foreach ($p in $procs) {
    $procPath = $p.ExecutablePath
    Line 'PID' $p.ProcessId
    Line '镜像路径' $procPath
    Line '命令行' $p.CommandLine
    $ost = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
    if ($ost) {
      Line '进程启动时间' $ost.StartTime
      if (Test-Path $exe) {
        $mtime = (Get-Item $exe).LastWriteTime
        if ($mtime -gt $ost.StartTime) {
          Bad "磁盘上的 wb2api.exe（$mtime）比进程启动时间（$($ost.StartTime)）新 → 新版还没生效，需要重启"
        } else {
          Good '进程用的就是磁盘上这份文件（无待生效改动）'
        }
      }
    }
  }
}

Write-Host "`n=== 4. 服务健康 ===" -ForegroundColor Cyan
$cfg = Join-Path $Root 'config.json'
$listen = '127.0.0.1:7863'; $apiKey = ''
if (Test-Path $cfg) {
  try { $c = Get-Content $cfg -Raw | ConvertFrom-Json; if ($c.listen) { $listen = $c.listen }; if ($c.api_key) { $apiKey = $c.api_key } } catch {}
}
$h = @{}; if ($apiKey) { $h['Authorization'] = "Bearer $apiKey" }
try {
  $st = (Invoke-WebRequest -Uri "http://$listen/status" -UseBasicParsing -TimeoutSec 3 -Headers $h).Content | ConvertFrom-Json
  $sum = 0; foreach ($a in $st.accounts) { $sum += [int]$a.in_flight }
  Line '/status' "OK  账号=$($st.total) 健康=$($st.healthy) in_flight=$sum"
  Good '服务在跑'
} catch {
  Bad "健康检查失败：$($_.Exception.Message)"
}

Write-Host ''
if ($ok) { Write-Host '结论：自启、文件、进程三者一致 ✓' -ForegroundColor Green; exit 0 }
else { Write-Host '结论：有项目不一致（见上面 ✗）' -ForegroundColor Red; exit 1 }
