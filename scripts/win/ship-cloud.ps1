<#
.SYNOPSIS
  云端发货：提交 → 测试 → 推送 fork → 服务器拉取重建 → （可选）数据同步 → 自检。

.DESCRIPTION
  这是「本地改 → 服务器改」的唯一入口。链路：

    本地 git commit
      → git push fork/<branch>
        → 服务器上 bash scripts/linux/deploy.sh
            git fetch + reset --hard（只动代码，不碰 runtime/）
            docker build --label wb2api.commit=<sha>
            docker compose up -d（失败自动回滚到 :rollback 镜像）
            健康检查 http://127.0.0.1:7863/healthz
        → （-SyncData 时）scripts\win\sync-data.ps1 同步账号与数据
        → 自检：服务器 git sha == 本地 sha、容器健康、公网 /healthz 可达

  失败语义：任何一步失败都会停下并给出下一步建议；部署失败时服务器已自动回滚，
  线上保持上一个可用版本。

.EXAMPLE
  # 常规发布（有改动时带提交信息）
  pwsh -File scripts\win\ship-cloud.ps1 -Commit "feat(panel): xxx"

.EXAMPLE
  # 只发布代码，同时把本地账号/数据推到服务器
  pwsh -File scripts\win\ship-cloud.ps1 -Commit "feat(panel): xxx" -SyncData

.EXAMPLE
  # 只跑测试，不推送不部署
  pwsh -File scripts\win\ship-cloud.ps1 -NoDeploy
#>
[CmdletBinding()]
param(
  [string]$Root,
  [string]$Commit,
  [string]$Branch = 'codex/code-review-20261030',
  [string]$Remote = 'fork',
  [string]$Server = 'root@38.76.219.235',
  [int]$Port = 3012,
  [string]$RemoteDir = '/opt/workbuddy2api-panel',
  [switch]$SkipTests,
  [switch]$NoDeploy,
  [switch]$NoPush,
  [switch]$SyncData,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$Root = (Resolve-Path $Root).Path
Push-Location $Root
$sw = [System.Diagnostics.Stopwatch]::StartNew()
function Step([string]$m) { Write-Host "`n── $m ──" -ForegroundColor Cyan }

try {
  # —— 1. 提交 ————————————————————————————————————————————————————————
  $porcelain = @(& git status --porcelain)
  if ($porcelain.Count -gt 0) {
    if (-not $Commit) {
      Step '检测到未提交改动，但没给 -Commit 信息'
      & git status --short
      Write-Host "中止：请带 -Commit ""<commit message>"" 一起运行。" -ForegroundColor Yellow
      exit 5
    }
    Step "提交：$Commit"
    & git add -A
    & git commit -m $Commit | Select-Object -First 3
    if ($LASTEXITCODE -ne 0) { Write-Host '提交失败，中止' -ForegroundColor Red; exit 5 }
  } else {
    Step '工作区干净，跳过提交'
  }
  $sha = (& git rev-parse --short HEAD).Trim()

  # —— 2. 测试 ————————————————————————————————————————————————————————
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
    Write-Host "`n仅测试模式：未推送、未部署。用时 $([int]$sw.Elapsed.TotalSeconds)s" -ForegroundColor Yellow
    exit 0
  }

  # —— 3. 推送 ————————————————————————————————————————————————————————
  if ($NoPush) {
    Write-Host '  已指定 -NoPush：跳过推送（服务器只能拉到已推送的提交）' -ForegroundColor Yellow
  } else {
    Step "推送 → $Remote/$Branch"
    & git push -u $Remote $Branch
    if ($LASTEXITCODE -ne 0) {
      Write-Host "推送失败，中止（服务器拿不到新提交）" -ForegroundColor Red
      exit 7
    }
  }

  # —— 4. 服务器部署 ————————————————————————————————————————————————
  Step '服务器：git 拉取 + 构建镜像 + 滚动替换 + 健康检查'
  $forceEnv = if ($Force) { 'FORCE=1 ' } else { '' }
  & ssh -p $Port $Server "${forceEnv}BRANCH=$Branch bash $RemoteDir/scripts/linux/deploy.sh"
  $deployExit = $LASTEXITCODE
  if ($deployExit -ne 0) {
    Write-Host "`n服务器部署失败（exit $deployExit）：部署脚本已自动回滚，线上仍是上一版。" -ForegroundColor Red
    Write-Host "排查：ssh -p $Port $Server 'docker logs --tail 100 workbuddy2api'" -ForegroundColor Yellow
    exit $deployExit
  }

  # —— 5. 数据同步（可选）————————————————————————————————————————————
  if ($SyncData) {
    Step '同步本地账号与数据 → 服务器'
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'sync-data.ps1') -Root $Root -Server $Server -Port $Port -RemoteDir $RemoteDir
    if ($LASTEXITCODE -ne 0) {
      Write-Host '数据同步失败（代码已部署，线上数据未变）' -ForegroundColor Red
      exit 8
    }
  }

  # —— 6. 自检 ————————————————————————————————————————————————————————
  Step '自检（服务器 git sha / 容器 / 公网可达 / 账号数）'
  $statusOut = & ssh -p $Port $Server "bash $RemoteDir/scripts/linux/status.sh" 2>&1
  $map = @{}
  foreach ($line in $statusOut) {
    if ($line -match '^([a-z_]+)=(.*)$') { $map[$Matches[1]] = $Matches[2] }
    Write-Host "  $line"
  }

  $problems = @()
  if ($map['repo_commit'] -ne $sha) { $problems += "服务器代码 $($map['repo_commit']) ≠ 本地 $sha" }
  if ($map['running_label'] -and $map['running_label'] -ne $sha) { $problems += "容器镜像标签 $($map['running_label']) ≠ 本地 $sha" }
  if ($map['container'] -notmatch '^running/healthy') { $problems += "容器状态 $($map['container']) 非 running/healthy" }
  if ($map['healthz'] -match 'unreachable') { $problems += '服务器本地 /healthz 不可达' }
  if ($map['public_healthz'] -match 'unreachable') { $problems += '公网 https://wkapi.jaycode.online/healthz 不可达' }
  if ($SyncData -and $map['auths_files']) {
    $localCount = @(Get-ChildItem (Join-Path $Root 'auths') -Filter '*.json' -File).Count
    if ([int]$map['auths_files'] -ne $localCount) {
      $problems += "服务器账号数 $($map['auths_files']) ≠ 本地 $localCount"
    }
  }

  Write-Host ''
  if ($problems.Count -eq 0) {
    Write-Host "✓ 云端发货完成：commit $sha 正在服务器运行（用时 $([int]$sw.Elapsed.TotalSeconds)s）" -ForegroundColor Green
    exit 0
  }
  Write-Host "✗ 部署完成但自检有 $($problems.Count) 项不一致：" -ForegroundColor Red
  $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  exit 1
} finally {
  Pop-Location
}
