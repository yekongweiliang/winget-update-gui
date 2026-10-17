# =====================================================================
#  update-gui.ps1 -- 应用更新（基于 winget）
#  v3: 图标列 / 字体 +1 / 后台任务（关窗口不中断）/ 无黑框（由 launch.vbs 拉起）
# =====================================================================
param(
    [switch]$Preview,          # 仅用于界面自测：填样例数据、不提权、不调 winget
    [int]$AutoClose = 0,       # 自测用：N 秒后自动关闭
    [string]$Shot = '',        # 自测用：把窗口渲染成 PNG 存到该路径后自动关闭
    [switch]$NoElevate         # 自测用：跳过提权
)

# ===================== 启动信标 / 错误可见化 =====================
# 双击后如果"什么都没发生"，看 %TEMP%\DSH-update-start.txt 就能知道断在哪一步。
$script:beacon = Join-Path $env:TEMP 'DSH-update-start.txt'
function Beacon([string]$step) {
    try {
        [System.IO.File]::AppendAllText($script:beacon,
            ((Get-Date).ToString('HH:mm:ss.fff') + '  [' + $PID + ']  ' + $step + "`r`n"),
            (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}
trap {
    $msg = ($_ | Out-String)
    Beacon ('致命错误: ' + ($msg -replace '\s+', ' '))
    # 不弹窗：能写日志窗口就写，同时追加到 gui.log，然后退出
    try { if ($script:txtLog) { $script:txtLog.AppendText(('启动失败：' + $msg) + "`r`n") } } catch { }
    try {
        $lp = Join-Path (Split-Path -Parent $PSCommandPath) 'gui.log'
        [System.IO.File]::AppendAllText($lp,
            ((Get-Date -Format 'HH:mm:ss') + ' 启动失败：' + ($msg -replace "`r?`n", ' ') + "`r`n"),
            (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    exit 1
}
Beacon ('脚本已执行; PSCommandPath=' + $PSCommandPath)

# ===================== DPI 感知（200% 缩放下不再模糊） =====================
$dpiSrc = @'
using System;
using System.Runtime.InteropServices;
public static class DshDpi {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SHDefExtractIconW(string pszIconFile, int iIndex, uint uFlags,
        out IntPtr phiconLarge, out IntPtr phiconSmall, uint nIconSize);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
}
'@
try { Add-Type -TypeDefinition $dpiSrc -Language CSharp -ErrorAction SilentlyContinue } catch { }
try { [void][DshDpi]::SetProcessDPIAware() } catch { }
$script:S = 1.0
try {
    $d = [DshDpi]::GetDpiForSystem()
    if ($d -gt 0) { $script:S = [double]$d / 96.0 }
} catch { $script:S = 1.0 }
if ($script:S -lt 1) { $script:S = 1.0 }

# 从 EXE 提取可用的最大图标（最高 256x256），保证高 DPI 下清晰
function Get-BigIcon([string]$path) {
    if (-not $path) { return $null }
    # 逐级降级：先要 256，失败再试 128/96/64/48/32。很多 EXE 只嵌了较小尺寸。
    foreach ($px in 256, 128, 96, 64, 48, 32) {
        $hL = [IntPtr]::Zero
        $hS = [IntPtr]::Zero
        $size = [uint32](($px -shl 16) -bor $px)
        try {
            [void][DshDpi]::SHDefExtractIconW($path, 0, 0, [ref]$hL, [ref]$hS, $size)
            if ($hL -ne [IntPtr]::Zero) {
                $ico = [System.Drawing.Icon]::FromHandle($hL)
                $copy = $ico.Clone()
                $ico.Dispose()
                try { [void][DshDpi]::DestroyIcon($hL) } catch { }
                if ($hS -ne [IntPtr]::Zero) { try { [void][DshDpi]::DestroyIcon($hS) } catch { } }
                if ($copy.Width -ge 32) { return $copy }
                $copy.Dispose()
            }
            if ($hS -ne [IntPtr]::Zero) { try { [void][DshDpi]::DestroyIcon($hS) } catch { } }
        } catch { }
    }
    return $null
}

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# ---------------------------------------------------------------- 路径
$script:dir        = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:logPath    = Join-Path $script:dir 'gui.log'
$script:wuScan     = Join-Path $script:dir 'wu-scan.ps1'
$script:jobDir     = Join-Path $script:dir 'job'
$script:tmpDir     = Join-Path $script:dir 'tmp'
$script:iconDir    = Join-Path $script:dir 'icons'
$script:statusFile = Join-Path $script:jobDir 'status.txt'
$script:doneFile   = Join-Path $script:jobDir 'done.txt'
$script:queueFile  = Join-Path $script:jobDir 'queue.txt'
Beacon ('目录准备: ' + $script:dir)
foreach ($d in @($script:jobDir, $script:tmpDir, $script:iconDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ---------------------------------------------------------------- 提权
function Test-Elevated {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}
if (-not $Preview -and -not $NoElevate -and -not (Test-Elevated)) {
    $me = $MyInvocation.MyCommand.Path
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $me + '"')) `
        -Verb RunAs | Out-Null
    exit
}

# ---------------------------------------------------------------- 配色
$cAccent   = [System.Drawing.ColorTranslator]::FromHtml('#2563EB')
$cAccentDk = [System.Drawing.ColorTranslator]::FromHtml('#1D4ED8')
$cInk      = [System.Drawing.ColorTranslator]::FromHtml('#111827')
$cMuted    = [System.Drawing.ColorTranslator]::FromHtml('#6B7280')
$cLine     = [System.Drawing.ColorTranslator]::FromHtml('#DBE2EE')
$cBg       = [System.Drawing.ColorTranslator]::FromHtml('#F6F8FC')
$cBlueSoft = [System.Drawing.ColorTranslator]::FromHtml('#EEF4FF')
$cSelBg    = [System.Drawing.ColorTranslator]::FromHtml('#DBEAFE')
$cRowAlt   = [System.Drawing.ColorTranslator]::FromHtml('#FBFDFF')
$cOk       = [System.Drawing.ColorTranslator]::FromHtml('#15803D')
$cBad      = [System.Drawing.ColorTranslator]::FromHtml('#B91C1C')
$cWarn     = [System.Drawing.ColorTranslator]::FromHtml('#B45309')
$cGhost    = [System.Drawing.ColorTranslator]::FromHtml('#9CA3AF')
$cWhite    = [System.Drawing.Color]::White

# ---------------------------------------------------------------- 字体（全部微软雅黑，整体 +1 号）
$fn        = 'Microsoft YaHei UI'
$fTitle    = New-Object System.Drawing.Font($fn, 14, [System.Drawing.FontStyle]::Bold)
$fBody     = New-Object System.Drawing.Font($fn, 10, [System.Drawing.FontStyle]::Regular)
$fBold     = New-Object System.Drawing.Font($fn, 10, [System.Drawing.FontStyle]::Bold)
$fSmall    = New-Object System.Drawing.Font($fn, 9.5, [System.Drawing.FontStyle]::Regular)
$fSmallB   = New-Object System.Drawing.Font($fn, 9.5, [System.Drawing.FontStyle]::Bold)
$fLog      = New-Object System.Drawing.Font($fn, 9.5, [System.Drawing.FontStyle]::Regular)

# ---------------------------------------------------------------- 日志
$script:txtLog = $null
function Write-Log([string]$msg) {
    $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $msg)
    try {
        $u = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($script:logPath, $line + "`r`n", $u)
    } catch { }
    try { if ($script:txtLog) { $script:txtLog.AppendText($line + "`r`n"); $script:txtLog.SelectionStart = $script:txtLog.TextLength; $script:txtLog.ScrollToCaret() } } catch { }
}

# ---------------------------------------------------------------- 文本/表格工具
function Read-TextAuto([string]$path) {
    if (-not (Test-Path $path)) { return '' }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        if ($bytes.Length -eq 0) { return '' }
        $u = [System.Text.Encoding]::UTF8.GetString($bytes)
        if ($u.IndexOf([char]0xFFFD) -ge 0) { return [System.Text.Encoding]::GetEncoding(936).GetString($bytes) }
        return $u.TrimStart([char]0xFEFF)
    } catch { return '' }
}

function Parse-UpgradeTable([string]$text) {
    # winget 的列间距会变：Id 和版本之间有时只有一个空格，
    # 所以不能按"两空格切列"，改成从行尾往前取：可选源 / 可用版本 / 当前版本 / Id / 名字
    $rows = @()
    if (-not $text) { return $rows }
    $rx = '^(?<left>.+?)\s+(?<cur>\S+)\s+(?<new>\S+)(?:\s+(?<src>winget|msstore))?\s*$'
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*-{5,}') { continue }
        if ($line -match '^\s*(Name|名称)\s+') { continue }
        if ($line -match 'available|可用的升级|没有可用') { continue }
        if ($line.Trim().Length -eq 0) { continue }
        $m = [regex]::Match($line, $rx)
        if (-not $m.Success) { continue }
        $left = $m.Groups['left'].Value.Trim()
        $cur = $m.Groups['cur'].Value.Trim()
        $new = $m.Groups['new'].Value.Trim()
        $mm = [regex]::Match($left, '^(?<name>.+?)\s+(?<id>\S+)$')
        if (-not $mm.Success) { continue }
        $name = $mm.Groups['name'].Value.Trim()
        $id = $mm.Groups['id'].Value.Trim()
        if ($id -notmatch '\.') { continue }
        if ($cur -ne 'Unknown' -and $cur -notmatch '^[\d\.\-\+]+$') { continue }
        $rows += [pscustomobject]@{ Name = $name; Id = $id; Cur = $cur; New = $new }
    }
    return $rows
}

# ---------------------------------------------------------------- 图标
$script:uninstall = $null
function Get-UninstallEntries {
    if ($script:uninstall) { return $script:uninstall }
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $list = New-Object System.Collections.ArrayList
    foreach ($k in $keys) {
        try {
            Get-ItemProperty $k -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.DisplayName -and $_.DisplayIcon) {
                    [void]$list.Add([pscustomobject]@{ Name = [string]$_.DisplayName; Icon = [string]$_.DisplayIcon })
                } elseif ($_.DisplayName -and $_.InstallLocation -and (Test-Path -LiteralPath $_.InstallLocation)) {
                    try {
                        $exe = Get-ChildItem -LiteralPath $_.InstallLocation -Filter '*.exe' -ErrorAction SilentlyContinue |
                            Sort-Object Length -Descending | Select-Object -First 1
                        if ($exe) {
                            [void]$list.Add([pscustomobject]@{ Name = [string]$_.DisplayName; Icon = [string]$exe.FullName })
                        }
                    } catch { }
                }
            }
        } catch { }
    }
    $script:uninstall = $list
    return $list
}

function Clean-IconPath([string]$s) {
    if (-not $s) { return '' }
    $s = $s.Trim()
    $s = $s -replace ',\s*-?\d+\s*$', ''
    $s = $s.Trim().Trim('"').Trim()
    return $s
}

function New-Avatar([string]$text, [string]$path) {
    # 没有可用图标时：画一个规整圆环 + 首字母。64px 抗锯齿，高 DPI 下也清楚。
    $ch = '?'
    if ($text) { $ch = $text.Substring(0, 1).ToUpper() }
    $px = 64
    $bmp = New-Object System.Drawing.Bitmap $px, $px
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $fill = New-Object System.Drawing.SolidBrush $cBlueSoft
    $pen = New-Object System.Drawing.Pen $cLine, 2
    $g.FillEllipse($fill, 2, 2, ($px - 5), ($px - 5))
    $g.DrawEllipse($pen, 2, 2, ($px - 5), ($px - 5))
    $font = New-Object System.Drawing.Font($fn, [float]($px * 0.50), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $brush = New-Object System.Drawing.SolidBrush $cAccentDk
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString($ch, $font, $brush, (New-Object System.Drawing.RectangleF 0, 0, $px, $px), $sf)
    $g.Dispose(); $fill.Dispose(); $pen.Dispose(); $font.Dispose(); $brush.Dispose()
    try { $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png) } catch { }
    $bmp.Dispose()
}

function Resolve-Icon([string]$name, [string]$id) {
    $safe = ($id -replace '[^\w\.\-]', '_')
    $cache = Join-Path $script:iconDir ($safe + '.png')
    if (Test-Path $cache) {
        try { if ((Get-Item $cache).Length -gt 300) { return $cache } } catch { }
    }
    $exe = ''
    try {
        $un = Get-UninstallEntries
        $hit = $un | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if (-not $hit) { $hit = $un | Where-Object { $_.Name -like ($name + '*') } | Select-Object -First 1 }
        if (-not $hit) {
            $key = ($name -replace '\s*[\(\（].*$', '').Trim().ToLower()
            if ($key.Length -ge 4) {
                $hit = $un | Where-Object { $_.Name -and $_.Name.ToLower().StartsWith($key) } | Select-Object -First 1
            }
        }
        if ($hit) {
            $p = Clean-IconPath $hit.Icon
            if ($p -and (Test-Path -LiteralPath $p)) { $exe = $p }
        }
    } catch { }
    if ($exe) {
        $ico = $null
        try {
            $ico = Get-BigIcon $exe
            if (-not $ico) { $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($exe) }
        } catch { $ico = $null }
        if ($ico) {
            try {
                $px = 32
                if ($ico.Width -gt $px) { $px = $ico.Width }
                if ($px -gt 256) { $px = 256 }
                $bmp = New-Object System.Drawing.Bitmap $px, $px
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                $g.Clear([System.Drawing.Color]::Transparent)
                $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $g.DrawIcon($ico, (New-Object System.Drawing.Rectangle 0, 0, $px, $px))
                $g.Dispose()
                $bmp.Save($cache, [System.Drawing.Imaging.ImageFormat]::Png)
                $bmp.Dispose()
                $ico.Dispose()
                return $cache
            } catch { try { $ico.Dispose() } catch { } }
        }
    }
    New-Avatar $name $cache
    return $cache
}

function New-IconFromExe([string]$exe) {
    # 指定 exe 直接抽图标，64px 画布，透明底
    try {
        $ico = $null
        try { $ico = Get-BigIcon $exe } catch { $ico = $null }
        if (-not $ico) { $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($exe) }
        if (-not $ico) { return $null }
        $px = 64
        $bmp = New-Object System.Drawing.Bitmap $px, $px
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawIcon($ico, (New-Object System.Drawing.Rectangle 0, 0, $px, $px))
        $g.Dispose()
        return $bmp
    } catch { return $null }
}

function Load-IconImage([string]$path) {
    # 不要预缩放到 24px：交给表格 Zoom 布局按当前 DPI 现算，才不会模糊。
    try {
        $src = [System.Drawing.Image]::FromFile($path)
        $bmp = New-Object System.Drawing.Bitmap $src
        $src.Dispose()
        return $bmp
    } catch { return (New-Object System.Drawing.Bitmap 32, 32) }
}

function Get-ShortName([string]$name) {
    if (-not $name) { return '' }
    $s = $name -replace '\s+-\s+v?[\d\.]+\s*$', ''
    if ($s.Trim().Length -lt 4) { return $name }
    return $s.Trim()
}

# ===================================================================== 界面
$form = New-Object System.Windows.Forms.Form
$form.Text = '应用更新'
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.ClientSize = New-Object System.Drawing.Size([int](1000 * $script:S), [int](672 * $script:S))
$form.MinimumSize = New-Object System.Drawing.Size([int](760 * $script:S), [int](520 * $script:S))
$form.StartPosition = 'CenterScreen'
$form.BackColor = $cBg
$form.Font = $fBody
$form.ForeColor = $cInk
$form.ShowIcon = $false
$form.MaximizeBox = $true

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'
$root.ColumnCount = 1
$root.RowCount = 4
$root.BackColor = $cBg
[void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, [int](52 * $script:S))))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, [int](58 * $script:S))))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, [int](140 * $script:S))))
$form.Controls.Add($root)

# ---- 顶部
$head = New-Object System.Windows.Forms.Panel
$head.Dock = 'Fill'
$head.BackColor = $cBg
$root.Controls.Add($head, 0, 0)

$bar = New-Object System.Windows.Forms.Panel
        $bar.Location = New-Object System.Drawing.Point([int](16 * $script:S), [int](12 * $script:S))
        $bar.Size = New-Object System.Drawing.Size([int](4 * $script:S), [int](24 * $script:S))
$bar.BackColor = $cAccent
$head.Controls.Add($bar)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = '应用更新'
$lblTitle.Font = $fTitle
$lblTitle.ForeColor = $cInk
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point([int](30 * $script:S), [int](12 * $script:S))
$head.Controls.Add($lblTitle)


$flowRight = New-Object System.Windows.Forms.FlowLayoutPanel
$flowRight.FlowDirection = 'RightToLeft'
$flowRight.WrapContents = $false
$flowRight.AutoSize = $true
$flowRight.Dock = 'Right'
$flowRight.BackColor = $cBg
$flowRight.Padding = New-Object System.Windows.Forms.Padding(0, [int](8 * $script:S), [int](16 * $script:S), 0)
$head.Controls.Add($flowRight)

$lblCount = New-Object System.Windows.Forms.Label
$lblCount.Text = '（正在读取…）'
$lblCount.Font = $fBody
$lblCount.ForeColor = $cAccent
$lblCount.AutoSize = $false
$lblCount.Size = New-Object System.Drawing.Size([int](210 * $script:S), [int](28 * $script:S))
$lblCount.TextAlign = 'MiddleRight'
$lblCount.Margin = New-Object System.Windows.Forms.Padding(0, [int](4 * $script:S), [int](14 * $script:S), 0)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '刷新'
$btnRefresh.Font = $fBody
$btnRefresh.FlatStyle = 'Flat'
$btnRefresh.FlatAppearance.BorderSize = 1
$btnRefresh.FlatAppearance.BorderColor = $cLine
$btnRefresh.BackColor = $cWhite
$btnRefresh.ForeColor = $cAccentDk
$btnRefresh.Size = New-Object System.Drawing.Size([int](84 * $script:S), [int](28 * $script:S))
$btnRefresh.Margin = New-Object System.Windows.Forms.Padding(0, [int](4 * $script:S), 0, 0)
$btnRefresh.Cursor = [System.Windows.Forms.Cursors]::Hand
$flowRight.Controls.Add($btnRefresh)
        $flowRight.Controls.Add($lblCount)

# ---- 表格
$gridPanel = New-Object System.Windows.Forms.Panel
$gridPanel.Dock = 'Fill'
$gridPanel.BackColor = $cWhite
$gridPanel.Padding = New-Object System.Windows.Forms.Padding([int](16 * $script:S), 0, [int](16 * $script:S), 0)
$root.Controls.Add($gridPanel, 0, 1)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.BackgroundColor = $cWhite
$grid.BorderStyle = 'None'
$grid.Font = $fBody
$grid.ForeColor = $cInk
$grid.EnableHeadersVisualStyles = $false
$grid.Font = New-Object System.Drawing.Font($fn, 13, [System.Drawing.FontStyle]::Regular)
$grid.RowTemplate.Height = [int](54 * $script:S)
$grid.ColumnHeadersHeight = [int](42 * $script:S)
$grid.AutoSizeRowsMode = [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::None
$grid.ColumnHeadersBorderStyle = 'Single'
$grid.ColumnHeadersDefaultCellStyle.BackColor = $cBlueSoft
$grid.ColumnHeadersDefaultCellStyle.ForeColor = $cInk
$grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $cBlueSoft
$grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = $cInk
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font($fn, 14, [System.Drawing.FontStyle]::Bold)
$grid.ColumnHeadersDefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(4, 0, 4, 0)
$grid.ColumnHeadersHeight = [int](42 * $script:S)
$grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.AllowUserToResizeColumns = $false
$grid.RowHeadersVisible = $false
$grid.MultiSelect = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.GridColor = $cLine
$grid.CellBorderStyle = 'SingleHorizontal'
$grid.RowTemplate.Height = [int](54 * $script:S)
$grid.AlternatingRowsDefaultCellStyle.BackColor = $cRowAlt
$grid.DefaultCellStyle.SelectionBackColor = $cSelBg
$grid.DefaultCellStyle.SelectionForeColor = $cInk
$grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(4, 0, 4, 0)
$grid.ScrollBars = 'Both'
$gridPanel.Controls.Add($grid)

$colChk = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colChk.Name = 'chk'; $colChk.HeaderText = ''; $colChk.Width = [int](46 * $script:S)
$colChk.ReadOnly = $false
$colChk.SortMode = 'NotSortable'
$colChk.DefaultCellStyle.Alignment = 'MiddleCenter'
$colChk.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(0)
[void]$grid.Columns.Add($colChk)

$colIcon = New-Object System.Windows.Forms.DataGridViewImageColumn
$colIcon.ImageLayout = [System.Windows.Forms.DataGridViewImageCellLayout]::Zoom
$colIcon.Name = 'ico'; $colIcon.HeaderText = ''
$colIcon.Width = [int](44 * $script:S)
$colIcon.ReadOnly = $true; $colIcon.SortMode = 'NotSortable'
$colIcon.ImageLayout = 'Zoom'
$colIcon.DefaultCellStyle.Alignment = 'MiddleCenter'
$colIcon.DefaultCellStyle.NullValue = $null
[void]$grid.Columns.Add($colIcon)

$colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colName.Name = 'name'; $colName.HeaderText = '应用'
$colName.AutoSizeMode = 'Fill'; $colName.FillWeight = 54; $colName.MinimumWidth = [int](230 * $script:S)
$colName.ReadOnly = $true; $colName.SortMode = 'NotSortable'
[void]$grid.Columns.Add($colName)

$colProg = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colProg.Name = 'prog'; $colProg.HeaderText = '进度'
$colProg.AutoSizeMode = 'None'; $colProg.Width = [int](130 * $script:S)
$colProg.MinimumWidth = [int](100 * $script:S)
$colProg.ReadOnly = $true; $colProg.SortMode = 'NotSortable'
$colProg.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(0)
[void]$grid.Columns.Add($colProg)

$colCur = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colCur.Name = 'cur'; $colCur.HeaderText = '当前版本'; $colCur.AutoSizeMode = 'AllCells'
$colCur.ReadOnly = $true; $colCur.SortMode = 'NotSortable'
$colCur.DefaultCellStyle.ForeColor = $cMuted
[void]$grid.Columns.Add($colCur)

$colNew = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colNew.Name = 'new'; $colNew.HeaderText = '可用版本'; $colNew.AutoSizeMode = 'AllCells'
$colNew.ReadOnly = $true; $colNew.SortMode = 'NotSortable'
$colNew.DefaultCellStyle.ForeColor = $cAccentDk
[void]$grid.Columns.Add($colNew)

$colState = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colState.Name = 'state'; $colState.HeaderText = '状态'; $colState.AutoSizeMode = 'None'
$colState.ReadOnly = $true; $colState.SortMode = 'NotSortable'
$colState.Width = [int](150 * $script:S); $colState.MinimumWidth = [int](130 * $script:S)
[void]$grid.Columns.Add($colState)

# ---- 按钮行
$btnPanel = New-Object System.Windows.Forms.Panel
$btnPanel.Dock = 'Fill'
$btnPanel.BackColor = $cBg
$root.Controls.Add($btnPanel, 0, 2)

$btnUpdate = New-Object System.Windows.Forms.Button
$btnUpdate.Text = '更新勾选的项'
$btnUpdate.Font = $fBody
$btnUpdate.FlatStyle = 'Flat'
$btnUpdate.FlatAppearance.BorderSize = 1
$btnUpdate.FlatAppearance.BorderColor = $cLine
$btnUpdate.BackColor = $cWhite
$btnUpdate.ForeColor = $cMuted
$btnUpdate.Size = New-Object System.Drawing.Size([int](200 * $script:S), [int](34 * $script:S))
$btnUpdate.Location = New-Object System.Drawing.Point([int](16 * $script:S), [int](10 * $script:S))
$btnUpdate.Anchor = 'Top,Left'
$btnUpdate.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnUpdate.Enabled = $false
$btnPanel.Controls.Add($btnUpdate)

$btnAll = New-Object System.Windows.Forms.Button
$btnAll.Text = '全选'
$btnAll.Font = $fBody
$btnAll.FlatStyle = 'Flat'
$btnAll.FlatAppearance.BorderSize = 1
$btnAll.FlatAppearance.BorderColor = $cLine
$btnAll.BackColor = $cWhite
$btnAll.ForeColor = $cInk
$btnAll.Size = New-Object System.Drawing.Size([int](92 * $script:S), [int](34 * $script:S))
$btnAll.Location = New-Object System.Drawing.Point([int](228 * $script:S), [int](10 * $script:S))
$btnAll.Anchor = 'Top,Left'
$btnAll.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnAll.Enabled = $false
$btnPanel.Controls.Add($btnAll)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = '关闭'
$btnClose.Font = $fBody
$btnClose.FlatStyle = 'Flat'
$btnClose.FlatAppearance.BorderSize = 1
$btnClose.FlatAppearance.BorderColor = $cLine
$btnClose.BackColor = $cWhite
$btnClose.ForeColor = $cInk
$btnClose.Size = New-Object System.Drawing.Size([int](92 * $script:S), [int](34 * $script:S))
$btnClose.Location = New-Object System.Drawing.Point([int](826 * $script:S), [int](10 * $script:S))
$btnClose.Anchor = 'Top,Right'
$btnClose.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnPanel.Controls.Add($btnClose)

# ---- 日志
$logPanel = New-Object System.Windows.Forms.Panel
$logPanel.Dock = 'Fill'
$logPanel.BackColor = $cBg
$logPanel.Padding = New-Object System.Windows.Forms.Padding([int](16 * $script:S), 0, [int](16 * $script:S), [int](10 * $script:S))
$root.Controls.Add($logPanel, 0, 3)

$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.Dock = 'Fill'
$txtLog.Font = $fLog
$txtLog.ForeColor = $cInk
$txtLog.BackColor = $cWhite
$txtLog.BorderStyle = 'None'
$txtLog.ReadOnly = $true
$txtLog.DetectUrls = $false
$txtLog.ScrollBars = 'Vertical'
$txtLog.WordWrap = $true
$logPanel.Controls.Add($txtLog)
$script:txtLog = $txtLog

# ===================================================================== 状态
$script:mode = 'idle'          # idle | reading | updating
$script:listProc = $null
$script:oFile = ''
$script:eFile = ''
$script:jobSeen = $false
$script:itemTotal = 0

function Get-WingetPath {
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $p) { return $p }
    return 'winget.exe'
}

$script:prog = @{}
$script:sweep = 0
$script:armed = $false
$script:wuScanning = $false
$script:wuOut = ''
$script:wuStart = $null

function Set-State([int]$i, [string]$text, [System.Drawing.Color]$color) {
    if ($i -lt 0 -or $i -ge $grid.Rows.Count) { return }
    $cell = $grid.Rows[$i].Cells[6]
    if ($cell.Value -ne $text) { $cell.Value = $text }
    $cell.Style.ForeColor = $color
    # 进度条状态：wait 空 / dl 下载中 / in 安装中 / ok 绿 / fail 红 / skip 黄
    if ($text -match '等待') {
        $script:prog[$i] = 'wait'
    } elseif ($text -match '安装中') {
        $script:prog[$i] = 'in'
    } elseif ($text -match '下载中' -or $text -match '更新中') {
        $script:prog[$i] = 'dl'
    } elseif ($color -eq $cOk) {
        $script:prog[$i] = 'ok'
    } elseif ($color -eq $cBad) {
        $script:prog[$i] = 'fail'
    } elseif ($color -eq $cWarn) {
        $script:prog[$i] = 'skip'
    }
    if ($grid.IsHandleCreated) { $grid.InvalidateRow($i) }
}

function Update-Buttons {
    # 读取/更新期间禁止再改勾选，避免中途改队列造成状态错乱
    $colChk.ReadOnly = ($script:mode -ne 'idle')
    $n = 0
    foreach ($r in $grid.Rows) { if ($r.Cells[0].Value -eq $true) { $n++ } }
    if ($script:mode -eq 'updating') {
        # 保持"蓝底白字"：禁用会让 Windows 把字改成灰的，所以这里只拦点击不置灰
        $btnUpdate.Text = '更新中…'
        $btnUpdate.Enabled = $true
        $btnUpdate.BackColor = $cAccent
        $btnUpdate.ForeColor = $cWhite
        $btnUpdate.FlatAppearance.BorderSize = 0
        $btnAll.Enabled = $false
        $btnRefresh.Enabled = $false
    } else {
        if ($n -gt 0 -and $script:armed) { $btnUpdate.Text = ('确认更新 ' + $n + ' 项？') }
        elseif ($n -gt 0) { $btnUpdate.Text = ('更新勾选的 ' + $n + ' 项') }
        else { $btnUpdate.Text = '更新勾选的项' }
        $btnUpdate.Enabled = ($n -gt 0 -and $script:mode -eq 'idle')
        # 没勾选时不要蓝底（避免看起来像可点的实心按钮），勾选后才蓝底白字
        if ($n -gt 0) {
            $btnUpdate.BackColor = $cAccent
            $btnUpdate.ForeColor = $cWhite
            $btnUpdate.FlatAppearance.BorderSize = 0
        } else {
            $btnUpdate.BackColor = $cWhite
            $btnUpdate.ForeColor = $cMuted
            $btnUpdate.FlatAppearance.BorderSize = 1
            $btnUpdate.FlatAppearance.BorderColor = $cLine
        }
        $btnAll.Enabled = ($grid.Rows.Count -gt 0 -and $script:mode -eq 'idle')
        $btnRefresh.Enabled = ($script:mode -eq 'idle')
    }
}

# ---------------------------------------------------------------- 读取列表
function Start-Refresh {
    if ($script:mode -ne 'idle') { return }
    $script:mode = 'reading'
    $script:itemTotal = 0
    Update-Buttons
    $lblCount.Text = '（正在读取…）'
    $grid.Rows.Clear()
    $script:prog = @{}
    $script:armed = $false
    $script:armTimer.Stop()
    Start-WuScan
    $stamp = (Get-Date -Format 'HHmmssfff')
    $script:oFile = Join-Path $script:tmpDir ('o_' + $stamp + '.txt')
    $script:eFile = Join-Path $script:tmpDir ('e_' + $stamp + '.txt')
    $wg = Get-WingetPath
    Write-Log '开始读取可更新列表...'
    try {
        $script:listProc = Start-Process -FilePath $wg `
            -ArgumentList @('upgrade', '--include-unknown', '--accept-source-agreements', '--disable-interactivity') `
            -NoNewWindow -PassThru -RedirectStandardOutput $script:oFile -RedirectStandardError $script:eFile
    } catch {
        Write-Log ('读取失败：' + $_.Exception.Message)
        $script:mode = 'idle'
        $lblCount.Text = '（读取失败）'
        Update-Buttons
    }
}

function Finish-Reading {
    $script:mode = 'idle'
    $text = Read-TextAuto $script:oFile
    $rows = @(Parse-UpgradeTable $text)
    # 排除自带更新器的项目（winget 无法升级，且会误报失败）
    $rows = @($rows | Where-Object { $_.Id -notmatch '^Microsoft\.Edge' -and $_.Id -notmatch 'EdgeWebView2' })
    $grid.Rows.Clear()
    $i = 0
    foreach ($r in $rows) {
        $i++
        $iconPath = ''
        try { $iconPath = Resolve-Icon $r.Name $r.Id } catch { }
        $img = $null
        if ($iconPath) { $img = Load-IconImage $iconPath }
        $idx = $grid.Rows.Add($false, $img, (Get-ShortName $r.Name), '', $r.Cur, $r.New, '待更新')
        $grid.Rows[$idx].Cells[6].Style.ForeColor = $cAccentDk
        $grid.Rows[$idx].Tag = [pscustomobject]@{ Id = $r.Id; Name = $r.Name }
        $grid.Rows[$idx].Cells[2].ToolTipText = $r.Name
    }
    $grid.ClearSelection()
    $script:itemTotal = $rows.Count
    if ($rows.Count -eq 0) {
        $err = Read-TextAuto $script:eFile
        if ($err -and $err.Trim().Length -gt 0) {
            $lblCount.Text = '（读取失败）'
            Write-Log '读取失败，详见下方 winget 输出。'
        } else {
            $lblCount.Text = '（已是最新）'
            Write-Log '读取完成：没有可更新的项目。'
        }
    } else {
        $lblCount.Text = ('（{0} 项可更新）' -f $rows.Count)
        Write-Log ('读取完成：{0} 项可更新。' -f $rows.Count)
    }
    Add-ManualRows
    if ($grid.Rows.Count -gt 0) { $lblCount.Text = ('（{0} 项可更新）' -f $grid.Rows.Count) }
    Update-Buttons
}

# ---------------------------------------------------------------- 执行更新
function Start-Updates {
    if ($script:mode -ne 'idle') { return }
    $picked = @()
    foreach ($r in $grid.Rows) {
        if ($r.Cells[0].Value -eq $true) { $picked += $r }
    }
    if ($picked.Count -eq 0) {
        Write-Log '请先在上方勾选要更新的应用。'
        return
    }

    $lines = @()
    foreach ($r in $picked) {
        $t = $r.Tag
        $lines += ("{0}`t{1}`t{2}" -f $r.Index, $t.Id, $t.Name)
        Set-State $r.Index '等待中' $cGhost
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($script:queueFile, (($lines -join "`r`n") + "`r`n"), $utf8)
    Remove-Item -LiteralPath $script:statusFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:doneFile -Force -ErrorAction SilentlyContinue
    $script:jobSeen = $false
    $script:mode = 'updating'
    Update-Buttons
    Write-Log ('开始更新 {0} 个应用' -f $picked.Count)
    $lblCount.Text = '（更新中…）'
    $runner = Join-Path $script:dir 'job-runner.ps1'
    if (-not (Test-Path $runner)) {
        Write-Log '缺少 job-runner.ps1，无法在后台执行。'
        $script:mode = 'idle'
        Update-Buttons
        return
    }
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $runner + '"')
    ) | Out-Null
}

function Poll-Job {
    if ($script:mode -ne 'updating') { return }
    if (Test-Path $script:statusFile) {
        $txt = Read-TextAuto $script:statusFile
        foreach ($line in ($txt -split "`r?`n")) {
            if (-not $line) { continue }
            $p = $line -split "`t"
            if ($p.Count -lt 3) { continue }
            $i = 0
            if (-not [int]::TryParse($p[0], [ref]$i)) { continue }
            $st = $p[1]; $note = $p[2]
            switch ($st) {
                'run'  {
                    $ph = 'dl'
                    if ($p.Count -ge 4 -and $p[3]) { $ph = [string]$p[3] }
                    if ($ph -eq 'in') { Set-State $i '安装中…' $cAccent }
                    else { Set-State $i '下载中…' $cAccent }
                }
                'ok'   { Set-State $i $note $cOk }
                'skip' { Set-State $i $note $cWarn }
                'fail' { Set-State $i $note $cBad }
                default { Set-State $i $note $cGhost }
            }
        }
    }
    if (-not $script:jobSeen -and (Test-Path $script:doneFile)) {
        $script:jobSeen = $true
        Finish-Job
    }
}

function Get-RegVersion([string]$pat) {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($k in $keys) {
        try {
            $hit = Get-ItemProperty $k -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -and $_.DisplayName -match $pat } | Select-Object -First 1
            if ($hit -and $hit.DisplayVersion) { return [string]$hit.DisplayVersion }
        } catch { }
    }
    return ''
}

function Get-DevVersion([string]$pat) {
    try {
        $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        foreach ($k in (Get-ChildItem $base -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if ($p.DriverDesc -and $p.DriverDesc -match $pat -and $p.DriverVersion) { return [string]$p.DriverVersion }
        }
    } catch { }
    return ''
}

# 需要手动更新、但能给出官网入口的项（驱动、国产软件等）
function Add-ManualRows {
    $cfg = Join-Path $script:dir 'manual-updates.tsv'
    if (-not (Test-Path $cfg)) { return }
    $txt = Read-TextAuto $cfg
    $n = 0
    foreach ($line in ($txt -split "`r?`n")) {
        if (-not $line) { continue }
        if ($line.TrimStart().StartsWith('#')) { continue }
        $p = $line -split "`t"
        if ($p.Count -lt 5) { continue }
        $name = $p[0]; $kind = $p[1]; $pat = $p[2]; $latest = $p[3]; $url = $p[4]
        $cur = ''
        try {
            if ($kind -eq 'dev') { $cur = Get-DevVersion $pat } else { $cur = Get-RegVersion $pat }
        } catch { }
        if (-not $cur) { continue }
        $state = '需手动'
        $stc = $cWarn
        $ver = '官网'
        if ($latest -and $latest -ne $cur) { $state = '有新版本'; $ver = $latest; $stc = $cAccentDk }
        $img = $null
        if ($p.Count -ge 6 -and $p[5]) {
            try {
                $hit = @(Get-ChildItem -Path ([string]$p[5]) -ErrorAction SilentlyContinue | Select-Object -First 1)
                if ($hit.Count -gt 0) { $img = New-IconFromExe $hit[0].FullName }
            } catch { }
        }
        if (-not $img) {
            $ico = ''
            try { $ico = Resolve-Icon $name ('manual.' + $name) } catch { }
            if ($ico) { $img = Load-IconImage $ico }
        }
        $idx = $grid.Rows.Add($false, $img, $name, '', $cur, $ver, $state)
        $grid.Rows[$idx].Cells[6].Style.ForeColor = $stc
        $grid.Rows[$idx].Cells[0].ReadOnly = $true
        $grid.Rows[$idx].Tag = [pscustomobject]@{ Id = ''; Name = $name; Url = $url; Source = 'manual' }
        $grid.Rows[$idx].Cells[2].ToolTipText = $name
        $grid.Rows[$idx].Cells[6].ToolTipText = '双击这一行打开官网；链接：' + $url
        $n++
    }
    if ($n -gt 0) { Write-Log ('已加入 {0} 项需手动更新的应用。' -f $n) }
}

function Start-WuScan {
    if (-not (Test-Path $script:wuScan)) { return }
    if ($script:mode -eq 'updating') { return }
    $stamp = (Get-Date -Format 'HHmmssfff')
    $script:wuOut = Join-Path $script:tmpDir ('wu_' + $stamp + '.tsv')
    Remove-Item -LiteralPath $script:wuOut -Force -ErrorAction SilentlyContinue
    $script:wuStart = Get-Date
    $script:wuScanning = $true
    try {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:wuScan + '"'),
            '-Out', ('"' + $script:wuOut + '"')
        ) | Out-Null
        Write-Log '开始扫描 Windows 可选更新与驱动…'
    } catch {
        $script:wuScanning = $false
        Write-Log ('系统更新扫描启动失败：' + $_.Exception.Message)
    }
}

function Finish-WuScan {
    $script:wuScanning = $false
    $txt = Read-TextAuto $script:wuOut
    foreach ($line in ($txt -split "`r?`n")) {
        if ($line -like '#ERROR*') { Write-Log ('系统更新扫描失败：' + $line.Substring(6).Trim()) }
    }
    $rows = @()
    foreach ($line in ($txt -split "`r?`n")) {
        if (-not $line) { continue }
        if ($line.StartsWith('#')) { continue }
        $p = $line -split "`t"
        if ($p.Count -lt 6) { continue }
        $kb = ''
        if ($p.Count -ge 7) { $kb = $p[6] }
        $rows += [pscustomobject]@{ Uid = $p[0]; Rev = $p[1]; Title = $p[2]; MB = $p[3]; Kind = $p[4]; KB = $kb }
    }
    if ($rows.Count -eq 0) {
        Write-Log '系统更新扫描完成：没有可选更新或驱动更新。'
    } else {
        $drv = 0
        foreach ($r in $rows) {
            if ($r.Kind -eq 'D') { $drv++ }
            $ver = ''
            if ($r.KB) { $ver = $r.KB }
            elseif ([double]$r.MB -gt 0) { $ver = ('{0} MB' -f $r.MB) }
            $ico2 = ''
            try { $ico2 = Resolve-Icon $r.Title ('wu.' + $r.Uid) } catch { }
            $img2 = $null
            if ($ico2) { $img2 = Load-IconImage $ico2 }
            $idx = $grid.Rows.Add($false, $img2, $r.Title, '', '—', $ver, '待安装')
            $grid.Rows[$idx].Cells[6].Style.ForeColor = $cWarn
            $grid.Rows[$idx].Tag = [pscustomobject]@{ Id = ('wu:' + $r.Uid + '|' + $r.Rev); Name = $r.Title; Source = 'wu' }
            $grid.Rows[$idx].Cells[2].ToolTipText = $r.Title
        }
        Write-Log ('系统更新扫描完成：{0} 项，其中驱动 {1} 项。' -f $rows.Count, $drv)
    }
    $grid.ClearSelection()
    if ($script:mode -eq 'idle') { $lblCount.Text = ('（{0} 项可更新）' -f $grid.Rows.Count) }
    Update-Buttons
}

function Finish-Job {
    # 先把最后一次状态全部落到表格上，避免收尾时把刚成功的行误判成"未完成"
    try { Poll-Job } catch { }
    $st = @{}
    if (Test-Path $script:statusFile) {
        foreach ($line in ((Read-TextAuto $script:statusFile) -split "`r?`n")) {
            if (-not $line) { continue }
            $p = $line -split "`t"
            if ($p.Count -lt 2) { continue }
            $i0 = 0
            if (-not [int]::TryParse($p[0], [ref]$i0)) { continue }
            $st[$i0] = $p[1]
        }
    }
    $script:mode = 'idle'
    Update-Buttons
    # 兜底：收尾时还停在"更新中"的行标红，避免进度条一直转
    foreach ($k in @($script:prog.Keys)) {
        if ([string]$script:prog[$k] -eq 'run') { Set-State ([int]$k) '未完成' $cBad }
    }
    # 结果只在最下方日志说一句：成功的写“安装成功”，失败的写“安装失败”，其余不写
    foreach ($i0 in ($st.Keys | Sort-Object)) {
        $nm = ''
        if ($i0 -ge 0 -and $i0 -lt $grid.Rows.Count) {
            $nm = [string]$grid.Rows[$i0].Cells[2].Value
            $tg = $grid.Rows[$i0].Tag
            if ($tg -and $tg.Name) { $nm = [string]$tg.Name }
        }
        if (-not $nm) { continue }
        if ($st[$i0] -eq 'ok') { Write-Log ($nm + ' 安装成功') }
        elseif ($st[$i0] -eq 'fail') { Write-Log ($nm + ' 安装失败') }
    }
    # 更新完把右上角的条数同步一下：只数还没处理掉的
    $left = 0
    foreach ($r in $grid.Rows) {
        $sv = [string]$r.Cells[6].Value
        if ($sv -notmatch '已完成|已是最新|无需更新|已安装') { $left++ }
    }
    if ($left -gt 0) { $lblCount.Text = ('（{0} 项可更新）' -f $left) }
    else { $lblCount.Text = '（已是最新）' }
}

# ---------------------------------------------------------------- 事件
$grid.Add_CurrentCellDirtyStateChanged({
    try { if ($grid.IsCurrentCellDirty) { [void]$grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) } } catch { }
})
$grid.Add_CellValueChanged({
    param($s, $e)
    if ($e.ColumnIndex -eq 0) {
        if ($script:armed) { $script:armed = $false; $script:armTimer.Stop() }
        Update-Buttons
    }
})
# 双击"需手动"的行：打开官网
$grid.Add_CellDoubleClick({
    param($s, $e)
    if ($e.RowIndex -lt 0) { return }
    $tg = $grid.Rows[$e.RowIndex].Tag
    if ($tg -and $tg.Url) {
        Write-Log ('打开官网：' + [string]$tg.Url)
        # 用 explorer 转交给当前登录用户，避免浏览器跟着提权
        try { Start-Process 'explorer.exe' ([string]$tg.Url) } catch { Write-Log ('打开失败：' + $_.Exception.Message) }
    }
})

# 双保险：更新/读取期间连"开始编辑勾选框"这一步都不允许
$grid.Add_CellBeginEdit({
    param($s, $e)
    if ($e.ColumnIndex -eq 0 -and $script:mode -ne 'idle') { $e.Cancel = $true }
})

# 「进度」列自绘：跑马灯表示正在下载/安装，结束后填满成绿/红/黄
$grid.Add_CellPainting({
    param($s, $e)
    if ($null -eq $e) { return }
    # 需手动更新的行不画勾选框，只留空白
    if ($e.ColumnIndex -eq 0) {
        if ($e.RowIndex -ge 0 -and $e.RowIndex -lt $grid.Rows.Count) {
            $tg0 = $grid.Rows[$e.RowIndex].Tag
            if ($tg0 -and $tg0.Source -eq 'manual') {
                $rc = $e.CellBounds
                $e.PaintBackground($rc, $true)
                $e.Handled = $true
            }
        }
        return
    }
    if ($e.ColumnIndex -ne 3) { return }
    if ($e.RowIndex -lt 0) { return }
    $ph = ''
    if ($script:prog.ContainsKey($e.RowIndex)) { $ph = [string]$script:prog[$e.RowIndex] }
    $r = $e.CellBounds
    $e.PaintBackground($r, $true)
    if ($ph -and $ph -ne 'wait') {
        $h = [int](12 * $script:S)
        $padX = [int](14 * $script:S)
        $tw = $r.Width - 2 * $padX
        if ($tw -gt [int](20 * $script:S)) {
            $ty = $r.Y + [int](($r.Height - $h) / 2)
            $bt = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(233, 237, 243))
            $e.Graphics.FillRectangle($bt, ($r.X + $padX), $ty, $tw, $h)
            $bt.Dispose()
            $fill = $cAccent
            if ($ph -eq 'ok') { $fill = [System.Drawing.Color]::FromArgb(46, 160, 67) }
            elseif ($ph -eq 'fail') { $fill = [System.Drawing.Color]::FromArgb(214, 69, 69) }
            elseif ($ph -eq 'skip') { $fill = [System.Drawing.Color]::FromArgb(203, 142, 40) }
            $bf = New-Object System.Drawing.SolidBrush $fill
            if ($ph -eq 'dl' -or $ph -eq 'in') {
                # 下载阶段填到 45%，安装阶段填到 88%：这是真实阶段，不是猜的百分比
                $frac = 0.45
                if ($ph -eq 'in') { $frac = 0.88 }
                $w = [int]($tw * $frac)
                if ($w -lt 6) { $w = 6 }
                $e.Graphics.FillRectangle($bf, ($r.X + $padX), $ty, $w, $h)
            } else {
                $e.Graphics.FillRectangle($bf, ($r.X + $padX), $ty, $tw, $h)
            }
            $bf.Dispose()
        }
    }
    $e.PaintContent($r)
    $e.Handled = $true
})

# 防手滑：第一下只是"上膛"，5 秒内不再点就自动退回
$script:armTimer = New-Object System.Windows.Forms.Timer
$script:armTimer.Interval = 5000
$script:armTimer.Add_Tick({
    $script:armTimer.Stop()
    if ($script:armed) { $script:armed = $false; Update-Buttons }
})

# 进度条不再做动画：按阶段静态填充

$btnRefresh.Add_Click({ Start-Refresh })

function Toggle-All {
    # 只对"能自动更新"的行生效：需手动的行一律不参与全选
    $sel = @($grid.Rows | Where-Object {
        (-not $_.Cells[0].ReadOnly) -and -not ($_.Tag -and $_.Tag.Source -eq 'manual')
    })
    $allChecked = $true
    foreach ($r in $sel) { if ($r.Cells[0].Value -ne $true) { $allChecked = $false; break } }
    $target = -not $allChecked
    if ($grid.Rows.Count -gt 0) { $grid.EndEdit() }
    foreach ($r in $sel) { $r.Cells[0].Value = $target }
    $btnAll.Text = if ($target) { '取消全选' } else { '全选' }
    Update-Buttons
}

$btnAll.Add_Click({ Toggle-All })

$btnUpdate.Add_Click({
    if ($script:mode -ne 'idle') { return }
    $n = 0
    foreach ($r in $grid.Rows) { if ($r.Cells[0].Value -eq $true) { $n++ } }
    if ($n -le 0) { Write-Log '请先在上方勾选要更新的应用。'; return }
    if (-not $script:armed) {
        $script:armed = $true
        Update-Buttons
        Write-Log ('已选 {0} 项，再点一次「确认更新」开始。' -f $n)
        $script:armTimer.Stop()
        $script:armTimer.Start()
        return
    }
    $script:armed = $false
    $script:armTimer.Stop()
    Update-Buttons
    Start-Updates
})
$btnClose.Add_Click({ $form.Close() })

# 关闭窗口不再二次确认：更新本来就在独立后台进程里跑，关窗不影响

$pump = New-Object System.Windows.Forms.Timer
$pump.Interval = 400
$pump.Add_Tick({
    try {
        if ($script:mode -eq 'reading') {
            if ($script:listProc -and $script:listProc.HasExited) {
                $script:listProc = $null
                Finish-Reading
            }
        } elseif ($script:mode -eq 'updating') {
            Poll-Job
        }
        if ($script:wuScanning) {
            $wt = ''
            if ($script:wuOut -and (Test-Path $script:wuOut)) { $wt = Read-TextAuto $script:wuOut }
            if ($wt -match '#DONE') {
                Finish-WuScan
            } elseif ($script:wuStart -and ((Get-Date) - $script:wuStart).TotalSeconds -gt 240) {
                # 扫描进程挂了、或者压根没写出文件，也要能收场，不能一直挂着"扫描中"
                $script:wuScanning = $false
                Write-Log '系统更新扫描超时，本次放弃。'
            }
        }
    } catch {
        Write-Log ('内部错误：' + $_.Exception.Message)
    }
})
$pump.Start()

$form.Add_Shown({
    if ($Preview) {
        $lblCount.Text = '（预览）'
        $i = 0
        foreach ($s in $script:samples) {
            $i++
            $ip = ''
            try { $ip = Resolve-Icon $s.Name $s.Id } catch { }
            $img = $null
            if ($ip) { $img = Load-IconImage $ip }
            $idx = $grid.Rows.Add($false, $img, $s.Name, '', $s.Cur, $s.New, '待更新')
            $grid.Rows[$idx].Tag = [pscustomobject]@{ Id = $s.Id; Name = $s.Name }
            $grid.Rows[$idx].Cells[2].ToolTipText = $s.Name
            $grid.Rows[$idx].Cells[6].Style.ForeColor = $cAccentDk
        }
        Set-State 2 '下载中…' $cAccent
        Set-State 5 '已完成' $cOk
        Set-State 7 '需手动' $cWarn
        Set-State 9 '失败 安装程序 1603' $cBad
        $grid.ClearSelection()
        $lblCount.Text = ('（{0} 项可更新）' -f $grid.Rows.Count)
        Update-Buttons
        Write-Log '预览模式：仅用于界面自测，不调用 winget。'
    } else {
        try { Start-Refresh } catch { Write-Log ('启动读取失败：' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber) }
    }
    if ($Shot) {
        $script:t3 = New-Object System.Windows.Forms.Timer
        $script:t3.Interval = 3500
        $script:t3.Add_Tick({
            try { $script:t3.Stop() } catch { }
            try {
                $rh = 0; if ($grid.Rows.Count -gt 0) { $rh = $grid.Rows[0].Height }
                Write-Log ('界面自检：缩放 ' + $script:S + 'x，字号 ' + $grid.Font.Size + 'pt ' + $grid.Font.Height + 'px，行高 ' + $rh + 'px，表头 ' + $grid.ColumnHeadersHeight + 'px')
                $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
                $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
                $bmp.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png)
                $bmp.Dispose()
                $form.TopMost = $true
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 450
                $b = $form.Bounds
                $bmp2 = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
                $g2 = [System.Drawing.Graphics]::FromImage($bmp2)
                $g2.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
                $g2.Dispose()
                $shot2 = ($Shot -replace '\.png$', '') + '-screen.png'
                $bmp2.Save($shot2, [System.Drawing.Imaging.ImageFormat]::Png)
                $bmp2.Dispose()
            } catch { Write-Log ('自检截图失败：' + $_.Exception.Message) }
            $form.Close()
        })
        $script:t3.Start()
    }
})

$script:samples = @(
    [pscustomobject]@{ Name = 'Anaconda3 2025.12-2 (Python 3.13.9 64-bit)'; Id = 'Anaconda.Anaconda3'; Cur = '2025.12-2'; New = '2026.07-1' },
    [pscustomobject]@{ Name = 'App Installer'; Id = 'Microsoft.AppInstaller'; Cur = '1.29.379.0'; New = '1.29.380' },
    [pscustomobject]@{ Name = 'Microsoft Visual C++ v14 Redistributable (x64)'; Id = 'Microsoft.VCRedist.2015+.x64'; Cur = '14.50.35719.0'; New = '14.51.36247.0' },
    [pscustomobject]@{ Name = 'Microsoft Visual C++ v14 Redistributable (x86)'; Id = 'Microsoft.VCRedist.2015+.x86'; Cur = '14.50.35719.0'; New = '14.51.36247.0' },
    [pscustomobject]@{ Name = 'Microsoft Windows Desktop Runtime - 6.0.27 (x64)'; Id = 'Microsoft.DotNet.DesktopRuntime.6'; Cur = '6.0.27'; New = '6.0.36' },
    [pscustomobject]@{ Name = 'Microsoft Windows Desktop Runtime 10.0.0 (x86)'; Id = 'Microsoft.DotNet.DesktopRuntime.10'; Cur = '10.0.0'; New = '10.0.13' },
    [pscustomobject]@{ Name = 'Python 3.14.6 (64-bit)'; Id = 'Python.Python.3.14'; Cur = '3.14.6'; New = '3.14.7' },
    [pscustomobject]@{ Name = 'Windows 终端'; Id = 'Microsoft.WindowsTerminal'; Cur = '1.24.12741.0'; New = '1.25.2733.0' },
    [pscustomobject]@{ Name = 'WorkBuddy 5.5.6'; Id = 'Tencent.WorkBuddy'; Cur = '5.5.6'; New = '5.6.2' },
    [pscustomobject]@{ Name = '微信'; Id = 'Tencent.WeChat.Universal'; Cur = '4.1.15.13'; New = '4.1.15.53' }
)

if ($AutoClose -gt 0) {
    $t2 = New-Object System.Windows.Forms.Timer
    $t2.Interval = $AutoClose * 1000
    $t2.Add_Tick({ $t2.Stop(); $form.Close() })
    $t2.Start()
}

[void]$form.ShowDialog()
$pump.Stop()
$form.Dispose()
