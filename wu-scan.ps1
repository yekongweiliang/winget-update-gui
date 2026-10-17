# wu-scan.ps1 -- 扫描 Windows 更新里的“可选更新”和驱动更新
# 输出 TSV，一行一个更新：
#   UpdateID <TAB> Revision <TAB> Title <TAB> SizeMB <TAB> Kind(D=驱动 O=可选) <TAB> BrowseOnly <TAB> KB
# 另有 #START / #COUNT / #ERROR / #DONE 标记行，方便调用方判断结束。
param([string]$Out = '')

$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Out) { $Out = Join-Path $dir 'wu-scan.tsv' }

$utf8 = New-Object System.Text.UTF8Encoding($false)
function W([string]$m) {
    try { [System.IO.File]::AppendAllText($Out, $m + "`r`n", $utf8) } catch { }
}

W ('#START ' + (Get-Date).ToString('HH:mm:ss'))
try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $result = $searcher.Search('IsInstalled=0 and IsHidden=0')
    $n = 0
    foreach ($u in $result.Updates) {
        try {
            $isDriver = ([int]$u.Type -eq 2)
            $browse = [bool]$u.BrowseOnly
            # 只要“可选更新”和“驱动”；普通安全更新交给 Windows 自己
            if (-not $isDriver -and -not $browse) { continue }
            $title = ([string]$u.Title) -replace "`t", ' ' -replace "`r?`n", ' '
            $kb = ''
            try { $kb = ((@($u.KBArticleIDs)) | ForEach-Object { 'KB' + $_ }) -join ',' } catch { }
            $mb = 0
            try { $mb = [math]::Round([double]$u.MaxDownloadSize / 1MB, 1) } catch { }
            $kind = 'O'
            if ($isDriver) { $kind = 'D' }
            W ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f $u.Identity.UpdateID, $u.Identity.RevisionNumber, $title, $mb, $kind, $browse, $kb)
            $n++
        } catch { }
    }
    W ('#COUNT ' + $n)
} catch {
    W ('#ERROR ' + ($_.Exception.Message -replace "`r?`n", ' '))
}
W ('#DONE ' + (Get-Date).ToString('HH:mm:ss'))
