<#
  职责：生成"发行副本"（只处理 dist/ 下的副本，不动源码）
  用法：./Tools/build/export_release.ps1 [-Export]
        -Export 会尝试调用 Godot 导出 exe（需要已安装导出模板与 export_presets.cfg）
  规矩：
    · 排除清单在 Tools/build/release_exclude.txt；
    · 调试接口 / 测试 / 工具 / 编辑器插件 / 旧卡 不进发行；
    · 任何删除都必须在 dist/ 下，先断言路径。
#>
param([switch]$Export)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Dist = Join-Path $Root "dist"
$Stage = Join-Path $Dist "release"

function Assert-UnderDist([string]$path) {
    $full = [IO.Path]::GetFullPath($path)
    $distFull = [IO.Path]::GetFullPath($Dist)
    if (-not $full.StartsWith($distFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝操作 dist/ 之外的路径：$full"
    }
    return $full
}

Assert-UnderDist $Stage | Out-Null
if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Force -Path $Stage | Out-Null

Write-Host "[release] 复制源码 → dist/release（排除 .git/.godot/_qa/.test_profile/dist）..."
$excludeDirs = @(
    (Join-Path $Root ".git"), (Join-Path $Root ".godot"), (Join-Path $Root "_qa"),
    (Join-Path $Root ".test_profile"), (Join-Path $Root "dist"),
    (Join-Path $Root "Godot"), (Join-Path $Root "NVIDIA Corporation")
)
$rcArgs = @($Root, $Stage, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP", "/XD") + $excludeDirs + @("/XF", "*.log")
& robocopy @rcArgs | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy 失败（$LASTEXITCODE）" }

$excludeFile = Join-Path $Root "Tools/build/release_exclude.txt"
$removed = @()
foreach ($line in Get-Content $excludeFile -Encoding UTF8) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith("#")) { continue }
    $target = Join-Path $Stage $t
    if (Test-Path $target) {
        $safe = Assert-UnderDist $target
        Remove-Item -Recurse -Force $safe
        $removed += $t
        Write-Host "[release] 排除 $t"
    }
}

# 硬门禁：调试接口 / 测试 / 工具 必须真的不在
$mustAbsent = @("Engine/debug", "Tests", "Tools", "addons", "Content/legacy")
$still = @()
foreach ($m in $mustAbsent) {
    if (Test-Path (Join-Path $Stage $m)) { $still += $m }
}
if ($still.Count -gt 0) { throw ("发行副本里仍有排除项：" + ($still -join ", ")) }

$files = Get-ChildItem $Stage -Recurse -File
$manifest = [ordered]@{
    kind = "release"
    built_at = (Get-Date).ToString("s")
    removed = $removed
    file_count = $files.Count
    bytes = ($files | Measure-Object -Property Length -Sum).Sum
}
$manifest | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $Stage "release_manifest.json") -Encoding UTF8
Write-Host ("[release] 完成：{0}（{1} 个文件，{2:N1} MB）" -f $Stage, $files.Count, ($manifest.bytes / 1MB))

if ($Export) {
    $godot = $env:GODOT_BIN
    if (-not $godot) {
        $godot = @(
            "E:/编辑器/tools/godot/Godot_v4.7.2-stable_mono_win64/Godot_v4.7.2-stable_mono_win64_console.exe",
            "E:/Program Files (x86)/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $godot) { throw "找不到 Godot：设置 GODOT_BIN" }
    if (-not (Test-Path (Join-Path $Stage "export_presets.cfg"))) {
        Write-Host "[release] 没有 export_presets.cfg，跳过 exe 导出（副本已就绪）" -ForegroundColor Yellow
    } else {
        & $godot --headless --path $Stage --export-release "Windows Desktop" (Join-Path $Stage "game.exe")
        if ($LASTEXITCODE -ne 0) { throw "导出失败（$LASTEXITCODE）" }
        Write-Host "[release] exe 导出完成"
    }
}
Write-Host "[release] RELEASE PASS"

exit 0
