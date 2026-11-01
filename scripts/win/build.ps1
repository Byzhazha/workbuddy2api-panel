<#
.SYNOPSIS
  编译 wb2api（Windows，不停服务）。

.DESCRIPTION
  产物两份，语义不同：
    bin\wb2api-<时间戳>-<gitsha>.exe   版本化留档（回滚用，永不覆盖）
    wb2api.exe                          正式名（deploy.ps1 负责落到这个名字上）

  为什么"编译+替换"可以不间断：Windows 允许 rename 正在运行的镜像（本机实测
  Win11 + Go 1.25：对运行中的 wb2api.exe 做 Rename-Item 成功，进程与监听端口均不受
  影响）。所以替换只需两次目录项改名，不占停机时间；真正会中断的只有"停进程→
  起进程"那一小段，由 deploy.ps1 在空闲窗口里做。

.EXAMPLE
  # 只编译，不动服务（最安全）
  pwsh -File scripts\win\build.ps1

.EXAMPLE
  # 带自定义标签
  pwsh -File scripts\win\build.ps1 -Tag hotfix-expiry
#>
[CmdletBinding()]
param(
  [string]$Root,
  [string]$Tag
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$Root = (Resolve-Path $Root).Path

$stamp = if ($Tag) { $Tag } else { Get-Date -Format 'yyyyMMdd-HHmmss' }
Push-Location $Root
try {
  $sha = (& git rev-parse --short HEAD 2>$null)
  if ($LASTEXITCODE -eq 0 -and $sha) { $stamp = "$stamp-$sha" }

  $binDir = Join-Path $Root 'bin'
  New-Item -ItemType Directory -Force -Path $binDir | Out-Null
  $out = Join-Path $binDir "wb2api-$stamp.exe"

  $env:CGO_ENABLED = '0'
  Write-Host "[build] go build ./cmd/server → $out"
  & go build -trimpath -ldflags '-s -w' -o $out ./cmd/server
  if ($LASTEXITCODE -ne 0) { throw "go build 失败（exit $LASTEXITCODE）" }

  # smoke：新二进制必须能加载并打印用法（-h 由 flag 包以 exit 2 结束，属正常）。
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $out
  $psi.Arguments = '-h'
  $psi.RedirectStandardError = $true
  $psi.RedirectStandardOutput = $true
  $psi.UseShellExecute = $false
  $p = [System.Diagnostics.Process]::Start($psi)
  $err = $p.StandardError.ReadToEnd()
  $null = $p.StandardOutput.ReadToEnd()
  if (-not $p.WaitForExit(10000)) { $p.Kill(); throw "smoke: 新二进制 10 秒内未退出" }
  if ($err -notmatch 'Usage of') { throw "smoke: 新二进制未能正常加载（stderr=$err）" }

  $hash = (Get-FileHash $out -Algorithm SHA256).Hash
  $size = (Get-Item $out).Length
  Write-Host ("[build] OK  {0}  {1:N0} bytes  sha256={2}" -f (Split-Path -Leaf $out), $size, $hash.Substring(0, 16))
  [pscustomobject]@{
    Path   = $out
    Hash   = $hash
    Size   = $size
    Commit = $sha
  }
} finally {
  Pop-Location
}
