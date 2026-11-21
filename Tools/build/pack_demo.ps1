<#
  职责：在发布副本上裁 Demo（**只动 dist/demo，不碰源码**）
  用法：./Tools/build/pack_demo.ps1 [-Aggressive]
        -Aggressive 额外裁掉高精度模型（Content/art/模型/精模），需要人工验收可玩性
#>
param([switch]$Aggressive)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Dist = Join-Path $Root "dist"
$Src = Join-Path $Dist "release"
$Demo = Join-Path $Dist "demo"

function Assert-UnderDist([string]$path) {
    $full = [IO.Path]::GetFullPath($path)
    $distFull = [IO.Path]::GetFullPath($Dist)
    if (-not $full.StartsWith($distFull, [StringComparison]::OrdinalIgnoreCase)) { throw "拒绝操作 dist/ 之外的路径：$full" }
    return $full
}

if (-not (Test-Path $Src)) {
    Write-Host "[demo] 没有 dist/release，先跑 export_release.ps1"
    & (Join-Path $PSScriptRoot "export_release.ps1")
    if ($LASTEXITCODE -ne 0) { throw "export_release 失败" }
}

Assert-UnderDist $Demo | Out-Null
if (Test-Path $Demo) { Remove-Item -Recurse -Force $Demo }
New-Item -ItemType Directory -Force -Path $Demo | Out-Null

& robocopy $Src $Demo /E /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy 失败（$LASTEXITCODE）" }

$cuts = @(
    "Content/maps/_自动保存.tres",
    "Content/maps/_编辑器链路自检.tres",
    "Content/maps/_最近地图.cfg"
)
if ($Aggressive) { $cuts += "Content/art/模型/精模"; $cuts += "Content/art/VAT" }

$removed = @()
foreach ($c in $cuts) {
    $target = Join-Path $Demo $c
    if (Test-Path $target) {
        Remove-Item -Recurse -Force (Assert-UnderDist $target)
        $removed += $c
        Write-Host "[demo] 裁掉 $c"
    }
}

# 源码必须一字节没变：这里只做提示，真正的保证是"所有操作路径都在 dist/ 下"
$files = Get-ChildItem $Demo -Recurse -File
[ordered]@{
    kind = "demo"
    built_at = (Get-Date).ToString("s")
    from = "dist/release"
    removed = $removed
    aggressive = [bool]$Aggressive
    file_count = $files.Count
    bytes = ($files | Measure-Object -Property Length -Sum).Sum
} | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $Demo "demo_manifest.json") -Encoding UTF8

Write-Host ("[demo] 完成：{0}（{1} 个文件，{2:N1} MB）" -f $Demo, $files.Count, ((($files | Measure-Object -Property Length -Sum).Sum) / 1MB))
Write-Host "[demo] DEMO PASS"

exit 0
