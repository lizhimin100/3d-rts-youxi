#Requires -Version 5.1
<#
  职责：游戏仓库唯一的"跑一下"入口（开发/体检/推演/截图都走这里）
  用法（在仓库根目录或任意目录）：
    ./Tools/run-game.ps1                          # 正常启动（有窗口）
    ./Tools/run-game.ps1 --check                  # 无窗口体检（失败退出码非 0）
    ./Tools/run-game.ps1 --simulate --games=5     # 只用 Model 跑 5 局，输出数值报告
    ./Tools/run-game.ps1 --shot hud out.png       # 离屏开一个画面、真点一次按钮、存图
    ./Tools/run-game.ps1 --shot main out.png      # 只截图（非交互画面）
    ./Tools/run-game.ps1 --help

  找 Godot 的顺序：环境变量 GODOT_BIN → 本机已知路径 → PATH 里的 godot。
  想固定用某个版本：$env:GODOT_BIN = 'D:\Godot\godot.exe'
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Rest = @()
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot

function Show-Usage {
    @"
用法：
  Tools/run-game.ps1                         正常启动（短局：准备/执行 + CP）
  Tools/run-game.ps1 --long                  旧即时战略（长局金币/木材）
  Tools/run-game.ps1 --short                 显式短局（可叠加 --map=...）
  Tools/run-game.ps1 --check                 无窗口体检（数据/文案/资源/分层/存档隔离/文档）
  Tools/run-game.ps1 --simulate [--games=N]  只用 Model 跑推演并输出数值报告
  Tools/run-game.ps1 --shot <画面> <输出.png> 离屏截图（hud 画面会真点一次「建造」）
  Tools/run-game.ps1 --import                重新扫描资源（加了新类名/新场景后跑一次）
  Tools/run-game.ps1 --round-test            半回合制自检（准备/执行/CP/小队，无窗口）
  Tools/run-game.ps1 --help                  这张表

画面列表：Content/data/screens.json
Godot 路径：环境变量 GODOT_BIN，或本机已知安装路径，或 PATH 里的 godot。
"@ | Write-Host
}

function Find-Godot {
    if ($env:GODOT_BIN) {
        if (Test-Path $env:GODOT_BIN) { return $env:GODOT_BIN }
        throw "GODOT_BIN 指向的文件不存在：$env:GODOT_BIN"
    }
    $candidates = @(
        "E:/编辑器/tools/godot/Godot_v4.7.2-stable_mono_win64/Godot_v4.7.2-stable_mono_win64_console.exe",
        "E:/Program Files (x86)/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    $cmd = Get-Command godot -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "找不到 Godot。请设置 GODOT_BIN，或把 godot 放进 PATH。"
}

$Godot = Find-Godot
$mode = "run"
$pass = @()
$shotName = $null
$shotOut = $null
## 短局/长局开关：必须放在 `--` 之后，OS.get_cmdline_user_args() 才收得到。
$userMode = ""
## 其它游戏参数（--map= / --speed= / --no-adjutant …）：同样必须放在 `--` 之后。
$gameArgs = @()

for ($i = 0; $i -lt $Rest.Count; $i++) {
    $a = $Rest[$i]
    switch ($a) {
        "--help"     { Show-Usage; exit 0 }
        "--check"    { $mode = "check"; continue }
        "--simulate" { $mode = "simulate"; continue }
        "--import"   { $mode = "import"; continue }
        "--round-test" { $mode = "round"; continue }
        "--short"    { $userMode = "--short"; continue }
        "--long"     { $userMode = "--long"; continue }
        # 常见游戏参数：不能当引擎参数传，否则 Game 侧的 OS.get_cmdline_user_args() 收不到。
        "--map=*"     { $gameArgs += $a; continue }
        "--no-map"    { $gameArgs += $a; continue }
        "--no-adjutant" { $gameArgs += $a; continue }
        "--speed=*"   { $gameArgs += $a; continue }
        "--select-id=*" { $gameArgs += $a; continue }
        "--kill-log"  { $gameArgs += $a; continue }
        "--legacy-move" { $gameArgs += $a; continue }
        "--shot" {
            if ($i + 2 -ge $Rest.Count) { throw "--shot 需要两个参数：<画面> <输出.png>" }
            $mode = "shot"
            $shotName = $Rest[$i + 1]
            $shotOut = $Rest[$i + 2]
            $i += 2
            continue
        }
        default { $pass += $a }
    }
}

# 新克隆/刚加资源：没有 .godot 就先扫一遍，否则类名与导入资源都是旧的
$cache = Join-Path $Root ".godot/global_script_class_cache.cfg"
if (-not (Test-Path $cache)) {
    Write-Host "[run-game] 首次运行，扫描资源（--import）..."
    & $Godot --headless --path $Root --import | Out-Null
}

Write-Host "[run-game] Godot: $Godot"

switch ($mode) {
    "import" {
        & $Godot --headless --path $Root --import
        exit $LASTEXITCODE
    }
    "check" {
        & $Godot --headless --path $Root --script "Tests/checks/check_all.gd"
        $code = $LASTEXITCODE
        if ($code -ne 0) { Write-Host "[run-game] 体检失败（退出码 $code）" -ForegroundColor Red }
        exit $code
    }
    "round" {
        & $Godot --headless --path $Root -- --round-test
        exit $LASTEXITCODE
    }
    "simulate" {
        & $Godot --headless --path $Root --script "Tests/sim/run_simulate.gd" -- @pass
        exit $LASTEXITCODE
    }
    "shot" {
        $abs = if ([IO.Path]::IsPathRooted($shotOut)) { $shotOut } else { Join-Path (Get-Location).Path $shotOut }
        $abs = [IO.Path]::GetFullPath($abs)
        $dir = Split-Path -Parent $abs
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        if (Test-Path $abs) { Remove-Item -Force $abs }
        & $Godot --path $Root --resolution 1600x900 --audio-driver Dummy "res://Tests/checks/shot_runner.tscn" -- "--screen=$shotName" "--shot-out=$abs" "--offscreen"
        $code = $LASTEXITCODE
        if ($code -eq 0 -and (Test-Path $abs)) {
            Write-Host "[run-game] 截图：$abs"
        } else {
            Write-Host "[run-game] 截图失败（退出码 $code）" -ForegroundColor Red
        }
        exit $code
    }
    default {
        # 有 --short/--long 时，把开关和剩余参数都放到 `--` 之后；
        # 没有开关时保持原样（正常启动由 Game 默认走短局）。
        if ($userMode -ne "" -or $gameArgs.Count -gt 0) {
            & $Godot --path $Root @pass -- $userMode @gameArgs
        } else {
            & $Godot --path $Root @pass
        }
        exit $LASTEXITCODE
    }
}
