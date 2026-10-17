# install.ps1 -- 装到 %LOCALAPPDATA%\UpdateCheck，并创建桌面快捷方式
# 不需要管理员：应用自己会提权
$ErrorActionPreference = 'Stop'

$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$dst = Join-Path $env:LOCALAPPDATA 'UpdateCheck'
New-Item -ItemType Directory -Path $dst -Force | Out-Null

foreach ($f in @('update-gui.ps1', 'job-runner.ps1', 'wu-scan.ps1', 'launch.vbs', 'icon80.ico')) {
    Copy-Item (Join-Path $src $f) (Join-Path $dst $f) -Force
}

# 配置文件只在第一次安装时放过去，之后不再覆盖，避免冲掉你自己的条目
$cfgSrc = Join-Path $src 'manual-updates.tsv'
$cfgDst = Join-Path $dst 'manual-updates.tsv'
if ((Test-Path $cfgSrc) -and -not (Test-Path $cfgDst)) {
    Copy-Item $cfgSrc $cfgDst -Force
}

# 桌面快捷方式：wscript 拉起 launch.vbs，再由它提权启动 PowerShell（不会闪黑框）
$desk = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desk '应用更新.lnk'
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$lnk.Arguments = '//nologo "' + (Join-Path $dst 'launch.vbs') + '"'
$lnk.WorkingDirectory = $dst
$lnk.IconLocation = (Join-Path $dst 'icon80.ico') + ',0'
$lnk.Description = '应用更新'
$lnk.Save()

Write-Host ''
Write-Host "已安装到：$dst"
Write-Host "桌面快捷方式：$lnkPath"
Write-Host '双击桌面上的「应用更新」即可使用。'
