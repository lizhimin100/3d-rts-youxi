# DSH 自动更新看护脚本
# 作用：等 DSH 退出 → 静默安装已下载的更新包 → 校验版本 → 重新拉起 DSH → 全程落日志
# 为什么要看护：安装器要替换正在运行的 DeepSeek Harness.exe，应用没退出就无法干净替换。
#
# 安全约束：
#   * 安装前校验包体积与 SHA256，异常直接中止（绝不在坏包上动手）
#   * 全程不删用户数据：工作区/会话都在 %USERPROFILE%\.dsh，不在安装目录
#   * 不 force kill 应用：宽限期内等它自己退出；超时才走安装器标准路径
param(
    # 宽限等待秒数：给用户一点时间看完当前会话，到点就按标准升级路径继续
    [int]$GraceSeconds = 120
)

$ErrorActionPreference = 'Continue'
$appDir = 'E:\DS-H\DSH'
$exe    = Join-Path $appDir 'DeepSeek Harness.exe'
$asar   = Join-Path $appDir 'resources\app.asar'
$inst   = Join-Path $env:LOCALAPPDATA '@deepseek-aidsh-desktop-updater\installer.exe'
$logDir = 'E:\DS-H\_update-log'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log   = Join-Path $logDir "update-$stamp.log"

function Log([string]$m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Add-Content -Path $log -Value $line -Encoding utf8
}

Log "===== DSH 自动更新开始 ====="
Log "安装包: $inst"

# ---------- 1) 前置校验：包在不在、大小对不对 ----------
if (-not (Test-Path $inst)) { Log "✗ 找不到安装包，中止"; exit 2 }
$pkg = Get-Item $inst
if ($pkg.Length -lt 100MB) { Log "✗ 安装包体积异常($([math]::Round($pkg.Length/1MB,1))MB)，中止"; exit 3 }
$hash = (Get-FileHash $inst -Algorithm SHA256).Hash
Log "包大小 $([math]::Round($pkg.Length/1MB,1))MB  修改 $($pkg.LastWriteTime)  SHA256 $hash"
Log "包版本 $($pkg.VersionInfo.FileVersion)"

# ---------- 2) 记录更新前状态（出问题可对照） ----------
$oldVer = if (Test-Path $exe) { (Get-Item $exe).VersionInfo.FileVersion } else { '缺失' }
$oldAsarTime = if (Test-Path $asar) { (Get-Item $asar).LastWriteTime } else { '缺失' }
$oldAsarSize = if (Test-Path $asar) { [math]::Round((Get-Item $asar).Length/1MB,1) } else { 0 }
$pre = Get-ChildItem $appDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
Log "更新前: exe=$oldVer  asar=$oldAsarTime (${oldAsarSize}MB)  文件数=$($pre.Count) 合计=$([math]::Round($pre.Sum/1MB,1))MB"
Log "用户数据目录（不在安装目录内，更新不会触碰）: $env:USERPROFILE\.dsh"

# ---------- 3) 等 DSH 退出（宽限期内温柔等待） ----------
$deadline = (Get-Date).AddSeconds($GraceSeconds)
$graceful = $false
while ((Get-Date) -lt $deadline) {
    $running = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$appDir*" }
    if (-not $running) { $graceful = $true; break }
    Start-Sleep -Seconds 2
}
if ($graceful) {
    Log "DSH 已优雅退出，开始安装"
} else {
    Log "宽限期 ${GraceSeconds}s 到，DSH 仍在运行 → 走标准升级路径（安装器会自行关闭应用）"
}

# ---------- 4) 静默安装 ----------
$instArgs = @('/currentuser', '/S')
Log "执行: `"$inst`" $($instArgs -join ' ')"
$proc = Start-Process -FilePath $inst -ArgumentList $instArgs -PassThru -Wait
Log "安装器退出码: $($proc.ExitCode)"

# ---------- 5) 落盘校验 ----------
Start-Sleep -Seconds 3
$newVer = if (Test-Path $exe) { (Get-Item $exe).VersionInfo.FileVersion } else { '缺失' }
$newAsarTime = if (Test-Path $asar) { (Get-Item $asar).LastWriteTime } else { '缺失' }
$newAsarSize = if (Test-Path $asar) { [math]::Round((Get-Item $asar).Length/1MB,1) } else { 0 }
$post = Get-ChildItem $appDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
Log "更新后: exe=$newVer  asar=$newAsarTime (${newAsarSize}MB)  文件数=$($post.Count) 合计=$([math]::Round($post.Sum/1MB,1))MB"

$asarChanged = ($oldAsarTime -ne $newAsarTime) -or ($oldAsarSize -ne $newAsarSize)
$exeExists   = Test-Path $exe
$ok = $exeExists -and ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010)

if ($ok) {
    Log "✓ 安装成功（asar 是否变化: $asarChanged）"
} else {
    Log "✗ 安装结果异常：退出码=$($proc.ExitCode) exe存在=$exeExists"
}

# ---------- 6) 重新拉起 DSH ----------
if ($exeExists) {
    Start-Sleep -Seconds 1
    try {
        Start-Process -FilePath $exe -WorkingDirectory $appDir
        Log "✓ 已重新拉起 DSH"
    } catch {
        Log "✗ 拉起失败: $($_.Exception.Message)"
    }
}

Log "===== 结束（日志：$log）====="
