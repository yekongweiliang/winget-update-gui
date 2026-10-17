# uninstall.ps1 -- 卸载：删桌面快捷方式 + 安装目录
$ErrorActionPreference = 'Continue'

$dst = Join-Path $env:LOCALAPPDATA 'UpdateCheck'
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '应用更新.lnk'

if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host "已删除快捷方式：$lnk" }
if (Test-Path $dst) {
    # 日志和临时文件一起删掉
    Remove-Item $dst -Recurse -Force
    Write-Host "已删除安装目录：$dst"
}
Write-Host '完成。'
