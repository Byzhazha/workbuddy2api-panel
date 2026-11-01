<#
.SYNOPSIS
  一条命令发货：提交 → 测试 → 编译 → canary → 替换 → 空闲重启 → 自检。

.DESCRIPTION
  这是本仓库在 Windows 上的**唯一部署入口**。改完代码就运行它，不要人工手工部署：

      pwsh -File scripts\win\ship.ps1 -Commit "fix(pool): xxx"

  步骤与失败语义（任何一步失败都停下，且尽量不留下坏状态）：

    1. -Commit <msg>  有改动就先 `git add -A && git commit -m <msg>`；不改动则跳过。
                      先提交再编译，保证 bin\wb2api-<时间戳>-<git sha>.exe 的 sha 与
                      代码版本一一对应（能追「这版二进制是哪次提交」）。
    2. go vet ./... && go test ./...    测试不过 → 直接中止，线上服务与文件都不动。
    3. deploy.ps1      编译 → 隔离配置 canary（备用端口真启动一次）→ 两次 rename
                       完成替换（不停服务）→ 等 in_flight 连续为 0 → 停/起 →
                       健康检查 → 起不来自动回滚。
    4. verify.ps1      校验「自启项 → 磁盘文件 → 运行进程」三者一致，退出码即结论。

  为什么可以在这个会话里跑（实测 2026-11-01 21:33）：工具调用发生在两次模型请求
  之间，deploy 又会先等 in_flight=0 才动手，所以重启落在请求间隙里，会话不受影响；
  实测停机窗口 0.3~0.5s，探针 150ms 粒度下零条失败。

.EXAMPLE
  # 完整发货（有改动时带上提交信息）
  pwsh -File scripts\win\ship.ps1 -Commit "fix(pool): 到期紧迫度加权"

.EXAMPLE
  # 只验证现有代码仍能编译部署（不提交）
  pwsh -File scripts\win\ship.ps1

.EXAMPLE
  # 只跑测试，不部署
  pwsh -File scripts\win\ship.ps1 -NoDeploy
#>
[CmdletBinding()]
param(
  [string]$Root,
  [string]$Commit,
  [switch]$SkipTests,
  [switch]$NoDeploy,
  [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$Root = (Resolve-Path $Root).Path
Push-Location $Root
$sw = [System.Diagnostics.Stopwatch]::StartNew()
function Step([string]$m) { Write-Host "`n── $m ──" -ForegroundColor Cyan }

try {
  # ---- 1. 提交 --------------------------------------------------------------
  $dirty = (& git status --porcelain) -ne $null -and (& git status --porcelain | Measure-Object).Count -gt 0
  if ($dirty) {
    if (-not $Commit) {
      Step '检测到未提交改动，但没给 -Commit 信息'
      & git status --short
      Write-Host "中止：请带 -Commit ""<commit message>"" 一起运行（先提交再编译，二进制才能对应到提交）。" -ForegroundColor Yellow
      exit 5
    }
    Step "提交：$Commit"
    & git add -A
    & git commit -m $Commit | Select-Object -First 3
    if ($LASTEXITCODE -ne 0) { Write-Host '提交失败，中止' -ForegroundColor Red; exit 5 }
  } else {
    Step '工作区干净，跳过提交'
  }

  # ---- 2. 测试 --------------------------------------------------------------
  if (-not $SkipTests) {
    Step 'go vet ./...'
    & go vet ./...
    if ($LASTEXITCODE -ne 0) { Write-Host 'vet 失败，中止（线上未改动）' -ForegroundColor Red; exit 6 }
    Step 'go test ./...'
    $testOut = & go test ./... 2>&1
    $testOut | Select-String -Pattern '^(ok|FAIL|---)' | ForEach-Object { Write-Host "  $($_.Line)" }
    if ($LASTEXITCODE -ne 0) { Write-Host '测试失败，中止（线上未改动）' -ForegroundColor Red; exit 6 }
  }

  if ($NoDeploy) {
    Write-Host "`n仅测试模式：未部署。用时 $([int]$sw.Elapsed.TotalSeconds)s" -ForegroundColor Yellow
    exit 0
  }

  # ---- 3. 编译 + 部署（含 canary 与回滚） -----------------------------------
  Step '编译 + canary + 替换 + 空闲重启'
  $deployArgs = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'deploy.ps1'), '-Root', $Root)
  if ($NoRestart) { $deployArgs += '-NoRestart' }
  & pwsh @deployArgs 2>&1 | ForEach-Object { Write-Host "  $_" }
  $deployExit = $LASTEXITCODE
  if ($deployExit -ne 0) {
    Write-Host "`ndeploy 退出码 $deployExit（2=等不到空闲窗口，文件已就位待下次重启；3=canary 失败已中止；1=回滚；4=替换失败）" -ForegroundColor Red
    exit $deployExit
  }

  # ---- 4. 自检 --------------------------------------------------------------
  Step '自检（自启 / 文件 / 进程 三者一致）'
  & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'verify.ps1') -Root $Root 2>&1 | ForEach-Object { Write-Host "  $_" }
  $verifyExit = $LASTEXITCODE

  $sha = (& git rev-parse --short HEAD)
  Write-Host ''
  if ($verifyExit -eq 0) {
    Write-Host "✓ 发货完成：commit $sha 已在跑（用时 $([int]$sw.Elapsed.TotalSeconds)s）" -ForegroundColor Green
    exit 0
  }
  Write-Host "✗ 部署完成但自检不一致，见上面 ✗ 项" -ForegroundColor Red
  exit 1
} finally {
  Pop-Location
}
