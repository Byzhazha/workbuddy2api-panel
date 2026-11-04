<#
.SYNOPSIS
  把本地账号与数据同步到服务器（auths + data + config.json → runtime/）。

.DESCRIPTION
  本地是唯一事实源。同步内容：
    auths/*.json            账号凭证（服务器上多余的旧账号会被删除）
    data/state.json         池状态（积分 / 冷却 / 禁用标记）
    data/usage.json         用量统计
    data/credit-history.json 积分历史
    data/request-logs/      请求日志
    config.json             由本地配置生成，唯一改动是 listen=":7863"
                            （容器内必须监听所有网卡，否则端口映射连不进去）

  服务器侧动作见 scripts/linux/apply-sync.sh：先备份 runtime 到 /root/backups，
  再停容器 → 解包替换 → chown 10001:10001 → 拉起 → 健康检查。

  注意：同步会重启容器（几秒中断），且服务器上原有账号被替换。

.EXAMPLE
  pwsh -File scripts\win\sync-data.ps1
#>
[CmdletBinding()]
param(
  [string]$Root,
  [string]$Server = 'root@38.76.219.235',
  [int]$Port = 3012,
  [string]$RemoteDir = '/opt/workbuddy2api-panel'
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$Root = (Resolve-Path $Root).Path

$authsDir = Join-Path $Root 'auths'
$dataDir = Join-Path $Root 'data'
$cfgFile = Join-Path $Root 'config.json'
foreach ($p in @($authsDir, $dataDir, $cfgFile)) {
  if (-not (Test-Path $p)) { throw "缺少 $p" }
}

$authFiles = @(Get-ChildItem $authsDir -Filter '*.json' -File)
if ($authFiles.Count -eq 0) { throw "$authsDir 下没有账号文件" }
Write-Host "本地账号 $($authFiles.Count) 个：$($authFiles.BaseName -join ', ')"

$stamp = Get-Date -Format 'yyyyMMddHHmmss'
$stage = Join-Path ([IO.Path]::GetTempPath()) "wb2api-sync-$stamp"
$tgz = Join-Path ([IO.Path]::GetTempPath()) "wb2api-sync-$stamp.tgz"
New-Item -ItemType Directory -Force -Path $stage | Out-Null

try {
  # —— 1. 打包 staging ————————————————————————————————————————————————
  Copy-Item $authsDir (Join-Path $stage 'auths') -Recurse -Force
  $stageData = Join-Path $stage 'data'
  New-Item -ItemType Directory -Force -Path $stageData | Out-Null
  foreach ($f in @('state.json', 'usage.json', 'credit-history.json')) {
    $src = Join-Path $dataDir $f
    if (Test-Path $src) { Copy-Item $src (Join-Path $stageData $f) -Force }
  }
  $rl = Join-Path $dataDir 'request-logs'
  if (Test-Path $rl) { Copy-Item $rl (Join-Path $stageData 'request-logs') -Recurse -Force }

  # 服务器配置：以本地为准，仅把 listen 改成容器内全接口。
  $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json
  $cfg.listen = ':7863'
  $cfg | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $stage 'config.json') -Encoding utf8

  Write-Host "打包 → $tgz"
  & tar -czf $tgz -C $stage auths data config.json
  if ($LASTEXITCODE -ne 0) { throw "tar 打包失败（exit $LASTEXITCODE）" }
  $size = '{0:N1} MB' -f ((Get-Item $tgz).Length / 1MB)
  Write-Host "包大小 $size"

  # —— 2. 上传 ——————————————————————————————————————————————————————
  Write-Host "上传 → ${Server}:/tmp/wb2api-sync.tgz"
  & scp -P $Port -q $tgz "${Server}:/tmp/wb2api-sync.tgz"
  if ($LASTEXITCODE -ne 0) { throw "scp 失败（exit $LASTEXITCODE）" }

  # —— 3. 服务器落盘 ————————————————————————————————————————————————
  Write-Host "服务器应用数据（备份 → 停容器 → 替换 → 拉起 → 健康检查）"
  & ssh -p $Port $Server "bash $RemoteDir/scripts/linux/apply-sync.sh /tmp/wb2api-sync.tgz"
  $rc = $LASTEXITCODE
  if ($rc -ne 0) { throw "apply-sync.sh 失败（exit $rc）" }
  Write-Host '✓ 数据同步完成' -ForegroundColor Green
} finally {
  Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $tgz -Force -ErrorAction SilentlyContinue
}
