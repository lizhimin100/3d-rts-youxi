# 一键验证 RTS 工程
# 用法：
#   .\工具\验证.ps1                 # 无头编译 + 跑 300 帧 + 报错扫描
#   .\工具\验证.ps1 -Full           # 上面 + 寻路自检 + 交互自检 + 自动试玩（完整验收）
#   .\工具\验证.ps1 -Full -Shot     # 再加实机截图
#   .\工具\验证.ps1 -Shot -Seconds 6 -Out E:\tmp\a.png
# 说明：新增带 class_name 的脚本后 Godot 需要重新扫描（--import），
#       所以这里每次都先 import，再跑，避免"找不到类型"的假报错。
param(
    [switch]$Full,
    [switch]$Shot,
    [float]$Seconds = 4.0,
    [string]$Out = "",
    [int]$Frames = 300
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$godot = 'E:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.cmd'
if (-not (Test-Path $godot)) {
    $found = Get-ChildItem 'C:\Program Files','D:\','E:\' -Filter 'godot*.exe' -Recurse -Depth 4 -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { $godot = $found.FullName } else { Write-Error "找不到 Godot 可执行文件"; exit 1 }
}

$fail = 0
$results = @()

function Report($name, $ok, $detail) {
    if ($ok) {
        Write-Host ("  ✓ " + $name + " " + $detail) -ForegroundColor Green
        $script:results += [pscustomobject]@{ 项目 = $name; 结果 = "通过"; 说明 = $detail }
    } else {
        Write-Host ("  ✗ " + $name + " " + $detail) -ForegroundColor Red
        $script:results += [pscustomobject]@{ 项目 = $name; 结果 = "失败"; 说明 = $detail }
        $script:fail++
    }
}

# --- 1. 重新扫描脚本（注册 class_name）---
Write-Host "[1] Godot --import ..." -ForegroundColor Cyan
$importOut = & $godot --headless --path . --import 2>&1 | Out-String
$parseErrs = $importOut -split "`n" | Select-String -Pattern 'SCRIPT ERROR|Parse Error'
Report "脚本解析" ($parseErrs.Count -eq 0) ("发现 " + $parseErrs.Count + " 条解析错误")
if ($parseErrs.Count -gt 0) {
    $parseErrs | Select-Object -First 15 | ForEach-Object { Write-Host ("    " + $_.Line.Trim()) -ForegroundColor Red }
}

# --- 2. 无头跑帧 ---
Write-Host "[2] 无头运行 $Frames 帧 ..." -ForegroundColor Cyan
$runOut = & $godot --headless --path . --quit-after $Frames 2>&1 | Out-String
# 已知无害噪音（都是「无头 dummy 渲染器」专属，真实窗口下不出现）：
#   material_get_instance_shader_parameters —— dummy 渲染器不支持 ShaderMaterial 实例参数
$errs = $runOut -split "`n" | Select-String -Pattern 'ERROR|SCRIPT ERROR' |
    Where-Object { $_.Line -notmatch 'material_get_instance_shader_parameters' -and $_.Line -notmatch 'Parameter "material" is null' -and $_.Line -notmatch 'resources still in use at exit' }
if ($errs.Count -gt 0) {
    $errs | Select-Object -First 20 | ForEach-Object { Write-Host ("    " + $_.Line.Trim()) -ForegroundColor Red }
}
Report "运行期无报错" ($errs.Count -eq 0) ("发现 " + $errs.Count + " 条 ERROR")
$runOut -split "`n" | Select-String -Pattern '\[主场景\]' | ForEach-Object { Write-Host ("  " + $_.Line.Trim()) -ForegroundColor DarkGray }

if ($Full) {
    # --- 3. 寻路自检 ---
    Write-Host "[3] 寻路自检 ..." -ForegroundColor Cyan
    $pf = & $godot --headless --path . --script 代码/测试/寻路自检.gd 2>&1 | Out-String
    $pfLine = ($pf -split "`n" | Select-String -Pattern '结果：通过').Line
    $pfOk = $pf -match '全部通过'
    Report "寻路自检" $pfOk ($pfLine)
    ($pf -split "`n" | Select-String -Pattern '^\s+✗') | ForEach-Object { Write-Host ("    " + $_.Line.Trim()) -ForegroundColor Red }

    # --- 4. 交互自检（点选/框选/右键/镜头）---
    Write-Host "[4] 交互自检 ..." -ForegroundColor Cyan
    $ia = & $godot --headless --path . --quit-after 2400 -- --interact-test 2>&1 | Out-String
    $iaLine = ($ia -split "`n" | Select-String -Pattern '^INTERACT ').Line
    $iaOk = $ia -match '"结果":"通过"'
    Report "交互自检" $iaOk ($iaLine -replace 'INTERACT ', '')
    if (-not $iaOk) { ($ia -split "`n" | Select-String -Pattern 'ERROR') | Select-Object -First 10 | ForEach-Object { Write-Host ("    " + $_.Line.Trim()) -ForegroundColor Red } }

    # --- 5. 自动试玩（经济/战斗/AI/胜负/重开）---
    Write-Host "[5] 自动试玩 ..." -ForegroundColor Cyan
    # ★ 必须加 --fixed-fps：自动试玩的等待是 create_timer（真实时间），无固定帧率时
    #   机器越快、12000 帧的预算越早用完，会偶发"没跑到结尾就被 --quit-after 掐掉"（实测踩到过）。
    #   定帧 60 后整局约 400 帧、稳定 4 秒跑完，和机器负载无关。
    $at = & $godot --headless --fixed-fps 60 --path . --quit-after 12000 -- --autotest 2>&1 | Out-String
    $atLine = ($at -split "`n" | Select-String -Pattern '^AUTOTEST ').Line
    $atOk = $at -match '"结果":"通过"'
    Report "自动试玩" $atOk ($atLine -replace 'AUTOTEST ', '')
    ($at -split "`n" | Select-String -Pattern '^AUTOTEST-PHASE1 ') | ForEach-Object { Write-Host ("  " + $_.Line.Trim()) -ForegroundColor DarkGray }

    # --- 5.2 采集压力自检（10 农民 / 90 模拟秒，一个都不许卡）---
    Write-Host "[5.2] 采集压力自检 ..." -ForegroundColor Cyan
    $gt = & $godot --headless --fixed-fps 60 --path . --quit-after 7200 -- --gather-test 2>&1 | Out-String
    $gtLine = ($gt -split "`n" | Select-String -Pattern '^GATHERTEST ').Line
    $gtOk = $gt -match '"结果":"通过"'
    Report "采集压力自检" $gtOk ($gtLine -replace 'GATHERTEST ', '')

    # --- 5.4 升级 / 人口自检（铁匠铺研究闭环 + 训练队列不撑爆人口）---
    Write-Host "[5.4] 升级 / 人口自检 ..." -ForegroundColor Cyan
    $rt = & $godot --headless --fixed-fps 60 --path . --quit-after 3000 -- --research-test 2>&1 | Out-String
    $rtLine = ($rt -split "`n" | Select-String -Pattern '^RESEARCHTEST ').Line
    $rtOk = $rt -match '"结果":"通过"'
    Report "升级/人口自检" $rtOk ($rtLine -replace 'RESEARCHTEST ', '')
    if (-not $rtOk) {
        ($rt -split "`n" | Select-String -Pattern 'ERROR|SCRIPT ERROR') | Select-Object -First 10 |
            ForEach-Object { Write-Host ("    " + $_.Line.Trim()) -ForegroundColor Red }
    }

    # --- 5.5 手感自检（60fps 定帧：起速/刹停/缩放/旋转/单位加减速）---
    Write-Host "[5.5] 手感自检 ..." -ForegroundColor Cyan
    $ft = & $godot --headless --fixed-fps 60 --path . -- --feel-test 2>&1 | Out-String
    $ftLine = ($ft -split "`n" | Select-String -Pattern '^FEELTEST ').Line
    $ftOk = $ft -match '"结果":"通过"'
    Report "手感自检" $ftOk ($ftLine -replace 'FEELTEST ', '')

    # --- 5.6 边缘滚动自检（需要真实窗口与真实鼠标）---
    Write-Host "[5.6] 边缘滚动自检 ..." -ForegroundColor Cyan
    $et = & $godot --path . --resolution 1600x900 -- --edge-test 2>&1 | Out-String
    $etLine = ($et -split "`n" | Select-String -Pattern '^EDGETEST ').Line
    $etOk = $et -match '"结果":"通过"'
    # 后台作业/CI 启动时窗口可能拿不到前台焦点，镜头"失焦不滚"是设计行为。
    # 自检会自己报"跳过：窗口未获得焦点"，这种情况不算回归。
    $etSkip = $et -match '"结果":"跳过'
    $etName = if ($etSkip) { "边缘滚动（跳过：窗口无焦点）" } else { "边缘滚动" }
    Report $etName ($etOk -or $etSkip) ($etLine -replace 'EDGETEST ', '')

    # --- 5.7 战斗自检（目标死后收场 / 攻击移动续行 / 待机不锁射程外 / 自动施法不吞指令）---
    Write-Host "[5.7] 战斗自检 ..." -ForegroundColor Cyan
    $ct = & $godot --headless --path . --script 代码/测试/战斗自检.gd 2>&1 | Out-String
    $ctLine = ($ct -split "`n" | Select-String -Pattern '^COMBATTEST ').Line
    # 自检脚本自己也不许报错（以前 _可走格数 里 int(null) 会甩一条 SCRIPT ERROR，结果看起来还是绿的）
    $ctBad = @($ct -split "`n" | Select-String -Pattern 'ERROR' |
        Where-Object { $_.Line -notmatch 'resources still in use at exit' })
    $ctOk = ($ct -match '"结果":"通过"') -and ($ctBad.Count -eq 0)
    Report "战斗自检" $ctOk (($ctLine -replace 'COMBATTEST ', '') + $(if ($ctBad.Count -gt 0) { "（脚本自身报错 " + $ctBad.Count + " 条）" } else { "" }))

    # --- 5.8 建造自检（吸附 / 拒建 / 真造一格兵营 / 只扣一次钱 / 多农民同工地 / 集结点）---
    Write-Host "[5.8] 建造自检 ..." -ForegroundColor Cyan
    $bd = & $godot --headless --path . --script 代码/测试/建造自检.gd 2>&1 | Out-String
    $bdLine = ($bd -split "`n" | Select-String -Pattern '^结果：').Line
    $bdOk = ($bd -match '全部通过') -and ($bd -match '失败 0')
    Report "建造自检" $bdOk $bdLine

    # --- 5.9 界面自检（框选只收己方单位 / 建筑面板 / 训练计时条）---
    Write-Host "[5.9] 界面自检 ..." -ForegroundColor Cyan
    $ui = & $godot --headless --path . --script 代码/测试/界面自检.gd 2>&1 | Out-String
    $uiLine = ($ui -split "`n" | Select-String -Pattern '^结果：').Line
    $uiOk = ($ui -match '全部通过') -and ($ui -match '失败 0')
    Report "界面自检" $uiOk $uiLine

    # --- 5.10 装饰性能自检（规模/面数/确定性指纹 + 装饰场景能否干净实例化）---
    Write-Host "[5.10] 装饰性能自检 ..." -ForegroundColor Cyan
    $dc = & $godot --headless --path . --script 代码/测试/装饰性能自检.gd 2>&1 | Out-String
    $dcLine = ($dc -split "`n" | Select-String -Pattern '^DECORTEST ').Line
    # 这条同时守住"美术/场景/*.tscn 的节点覆盖是否还对得上 GLB"：
    # v3 把模型按材质合并后，场景里残留的 v2 节点名（树/Root/Body/树冠0）会让每次实例化
    # 刷 500+ 条 "Unicode parsing error" + "has vanished"，而且覆盖参数被静默丢弃。
    $dcBad = @($dc -split "`n" | Select-String -Pattern 'Unicode parsing error|has vanished|ERROR')
    $dcOk = ($null -ne $dcLine) -and ($dcBad.Count -eq 0)
    Report "装饰性能自检" $dcOk (($dcLine -replace 'DECORTEST ', '') + "（异常行 " + $dcBad.Count + "）")
    if ($dcBad.Count -gt 0) {
        $dcBad | Select-Object -First 5 | ForEach-Object { Write-Host ("    " + $_.Line.Trim()) -ForegroundColor Red }
    }
}

# --- 6. 可选：实机截图 ---
if ($Shot) {
    Write-Host "[6] 实机截图 ..." -ForegroundColor Cyan
    if ([string]::IsNullOrWhiteSpace($Out)) { $Out = Join-Path $env:TEMP 'rts_shot_auto.png' }
    $dir = Split-Path -Parent $Out
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (Test-Path $Out) { Remove-Item $Out -Force }
    & $godot --path . --resolution 1600x900 -- --shot=$Out --shot-delay=$Seconds --quit-after-shot 2>&1 |
        Select-String -Pattern '截图' | ForEach-Object { Write-Host ("  " + $_.Line.Trim()) -ForegroundColor DarkGray }
    Report "实机截图" (Test-Path $Out) $Out
}

Write-Host ""
$results | Format-Table -AutoSize | Out-String | Write-Host
if ($fail -eq 0) {
    Write-Host "结果：全部通过 ✓" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("结果：有 " + $fail + " 项失败 ✗") -ForegroundColor Red
    exit 1
}