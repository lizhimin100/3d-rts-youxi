<#
  职责：调试接口的自动化验收（启动 → health/state/action → quit → 重启 → 确认是新进程）
  用法：./Tools/qa/bridge_probe.ps1 [-Port 18779]
  规矩（AGENTS.md）：重启后必须确认 pid + boot_id 都变了，不能"看起来连上了"就算。
#>
param(
    [int]$Port = 18778,
    [string]$Godot = ""
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

if (-not $Godot) {
    if ($env:GODOT_BIN -and (Test-Path $env:GODOT_BIN)) { $Godot = $env:GODOT_BIN }
}
if (-not $Godot) {
    $c = @(
        "E:/编辑器/tools/godot/Godot_v4.7.2-stable_mono_win64/Godot_v4.7.2-stable_mono_win64_console.exe",
        "E:/Program Files (x86)/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    $Godot = $c
}
if (-not $Godot) { throw "找不到 Godot：设置 GODOT_BIN" }

function Start-Game([int]$p) {
    $a = @("--headless", "--path", $Root, "--", "--debug-bridge", "--debug-port=$p")
    return Start-Process -FilePath $Godot -ArgumentList $a -PassThru -WindowStyle Hidden
}

function Wait-Health([int]$p, [int]$tries = 60) {
    for ($i = 0; $i -lt $tries; $i++) {
        try { return Invoke-RestMethod -Uri "http://127.0.0.1:$p/health" -TimeoutSec 2 } catch { Start-Sleep -Milliseconds 500 }
    }
    return $null
}

function Quit-Game([int]$p) {
    try { Invoke-RestMethod -Uri "http://127.0.0.1:$p/quit" -Method Post -ContentType "application/json" -Body "{}" -TimeoutSec 3 | Out-Null } catch {}
}

$p1 = $null
$p2 = $null
$fail = 0
try {
    Write-Host "[bridge] 第一次启动..."
    $p1 = Start-Game $Port
    $h1 = Wait-Health $Port
    if (-not $h1) { throw "第一次启动后 /health 不可达（端口 $Port）" }
    Write-Host ("[bridge] health pid={0} boot={1} test={2}" -f $h1.pid, $h1.boot_id, $h1.test)

    $s = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/state" -TimeoutSec 5
    $unit_sum = ($s.state.factions | ForEach-Object { $_.units } | Measure-Object -Sum).Sum
    Write-Host ("[bridge] state phase={0} factions={1} units={2}" -f $s.state.phase, $s.state.factions.Count, $unit_sum)

    $a = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/action" -Method Post -ContentType "application/json" -Body '{"name":"select_all","args":{}}' -TimeoutSec 5
    Write-Host ("[bridge] action select_all ok={0} selected={1}" -f $a.ok, $a.selected)
    if (-not $a.ok -or [int]$a.selected -le 0) { throw "select_all 没选中任何单位" }

    Quit-Game $Port
    if (-not $p1.WaitForExit(8000)) { throw "POST /quit 后进程没退出" }
    Write-Host "[bridge] 第一次进程已退出"

    Start-Sleep -Seconds 1
    Write-Host "[bridge] 第二次启动（验证连到的是新进程）..."
    $p2 = Start-Game $Port
    $h2 = Wait-Health $Port
    if (-not $h2) { throw "第二次启动后 /health 不可达" }
    if ([int]$h1.pid -eq [int]$h2.pid -or [string]$h1.boot_id -eq [string]$h2.boot_id) {
        throw ("连到的还是旧进程：pid {0}->{1}, boot {2}->{3}" -f $h1.pid, $h2.pid, $h1.boot_id, $h2.boot_id)
    }
    Write-Host ("[bridge] 新进程确认：pid {0}->{1}，boot {2}->{3}" -f $h1.pid, $h2.pid, $h1.boot_id, $h2.boot_id)
    Quit-Game $Port
    if (-not $p2.WaitForExit(8000)) { $p2 | Stop-Process -Force }
    Write-Host "[bridge] BRIDGE PASS"
} catch {
    $fail = 1
    Write-Host ("[bridge] BRIDGE FAIL: " + $_.Exception.Message) -ForegroundColor Red
} finally {
    if ($p1 -and -not $p1.HasExited) { $p1 | Stop-Process -Force }
    if ($p2 -and -not $p2.HasExited) { $p2 | Stop-Process -Force }
}
exit $fail