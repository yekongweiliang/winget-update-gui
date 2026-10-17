# =====================================================================
#  job-runner.ps1 -- 后台批量更新执行器
#  由 update-gui.ps1 以隐藏窗口独立进程启动；关闭 GUI 不会中断它。
#  读取 job\queue.txt（idx<TAB>Id<TAB>Name），逐项执行 winget upgrade，
#  过程中不断刷新 job\status.txt，全部结束写 job\done.txt。
# =====================================================================
$ErrorActionPreference = 'Stop'

$root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$jobDir = Join-Path $root 'job'
$queue  = Join-Path $jobDir 'queue.txt'
$status = Join-Path $jobDir 'status.txt'
$done   = Join-Path $jobDir 'done.txt'
$log    = Join-Path $root 'gui.log'
$tmp    = Join-Path $root 'tmp'
foreach ($d in @($jobDir, $tmp)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

$utf8 = New-Object System.Text.UTF8Encoding($false)

function W([string]$m) {
    try { [System.IO.File]::AppendAllText($log, ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) + "`r`n", $utf8) } catch { }
}

function Get-Text([string]$path) {
    if (-not (Test-Path $path)) { return '' }
    try {
        $b = [System.IO.File]::ReadAllBytes($path)
        if ($b.Length -eq 0) { return '' }
        $u = [System.Text.Encoding]::UTF8.GetString($b)
        if ($u.IndexOf([char]0xFFFD) -ge 0) { $u = [System.Text.Encoding]::GetEncoding(936).GetString($b) }
        return $u.TrimStart([char]0xFEFF)
    } catch { return '' }
}

# 清理一天前的临时输出
try {
    $cut = (Get-Date).AddDays(-1)
    Get-ChildItem $tmp -Filter '*.txt' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cut } | Remove-Item -Force -ErrorAction SilentlyContinue
} catch { }

# 注意：不能用 [ordered]@{} —— PowerShell 会把整数键当位置索引而抛异常
$map = @{}
function Save-Status {
    $lines = @()
    foreach ($k in ($map.Keys | Sort-Object)) {
        $v = $map[$k]
        $ph = ''
        if ($v.phase) { $ph = [string]$v.phase }
        $lines += ("{0}`t{1}`t{2}`t{3}" -f $k, $v.state, $v.note, $ph)
    }
    try { [System.IO.File]::WriteAllText($status, (($lines -join "`r`n") + "`r`n"), $utf8) } catch { }
}

$items = @()
if (Test-Path $queue) {
    foreach ($line in ((Get-Text $queue) -split "`r?`n")) {
        if (-not $line) { continue }
        $p = $line -split "`t"
        if ($p.Count -lt 3) { continue }
        $idx = 0
        if (-not [int]::TryParse($p[0], [ref]$idx)) { continue }
        $items += [pscustomobject]@{ Idx = $idx; Id = $p[1]; Name = $p[2] }
    }
}

W ('后台任务启动：{0} 项' -f $items.Count)
foreach ($it in $items) { $map[$it.Idx] = @{ state = 'wait'; note = '等待中' } }
Save-Status

$wg = (Get-Command winget.exe -ErrorAction SilentlyContinue)
if ($wg) { $wg = $wg.Source }
if (-not $wg) {
    $cand = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path $cand) { $wg = $cand }
}
if (-not $wg) { $wg = 'winget.exe' }

$ok = 0; $skip = 0; $fail = 0
foreach ($it in $items) {
    $map[$it.Idx] = @{ state = 'run'; note = '更新中…'; phase = 'dl' }
    Save-Status
    W ('开始更新：' + $it.Name)

    $stamp = (Get-Date -Format 'HHmmssfff')
    $o = Join-Path $tmp ('o_' + $stamp + '.txt')
    $e = Join-Path $tmp ('e_' + $stamp + '.txt')
    # 不用 Start-Process：它在环境变量存在大小写重名键（如 NO_PROXY / no_proxy）时会抛异常。
    # 这里本来就是独立后台进程，直接同步调用 winget 最简单也最稳。
    #
    # 失败自动换参数重试：per-user 安装的包（如 WorkBuddy、微信）常需要 --scope user
    # 才能被 winget 认成"可升级"，否则报 0x8A15005E（找不到可用升级）。
    $code = -1
    $all = ''
    $attempts = @(
        @('upgrade', '--id', $it.Id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'),
        @('upgrade', '--id', $it.Id, '--exact', '--silent', '--scope', 'user', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'),
        @('upgrade', '--id', $it.Id, '--exact', '--silent', '--include-unknown', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    )
    $tryN = 0
    foreach ($argSet in $attempts) {
        $tryN++
        $code = -1
        $proc = $null
        $o = Join-Path $tmp ('o_' + $stamp + '_' + $tryN + '.txt')
        $e = Join-Path $tmp ('e_' + $stamp + '_' + $tryN + '.txt')
        try {
            $proc = Start-Process -FilePath $wg -ArgumentList $argSet -NoNewWindow -PassThru `
                -RedirectStandardOutput $o -RedirectStandardError $e
        } catch { $proc = $null }
        if ($proc) {
            # 一边跑一边读输出，判断现在在"下载"还是"安装"
            $phase = 'dl'
            while (-not $proc.HasExited) {
                Start-Sleep -Milliseconds 400
                $so = Get-Text $o
                $np = $phase
                if ($so -match '正在安装|正在启动包安装|Starting package install|Installing package') { $np = 'in' }
                elseif ($so -match '正在下载|Downloading') { $np = 'dl' }
                if ($np -ne $phase) {
                    $phase = $np
                    $map[$it.Idx] = @{ state = 'run'; note = '更新中…'; phase = $phase }
                    Save-Status
                    if ($phase -eq 'in') { W ('进入安装阶段：' + $it.Name) } else { W ('进入下载阶段：' + $it.Name) }
                }
            }
            try { $proc.WaitForExit() } catch { }
            $code = $proc.ExitCode
            $all = (Get-Text $o) + "`r`n" + (Get-Text $e)
        } else {
            # 退化路径：拿不到实时输出就同步调用，进度不分阶段但更新照常
            try {
                $all = (& $wg @argSet 2>&1 | Out-String)
                $code = $LASTEXITCODE
            } catch {
                $code = -1
                $all = '调用失败：' + $_.Exception.Message
            }
        }
        if ($code -eq 0) { break }
        if ($all -match 'Successfully installed|已成功安装') { break }
        if ($tryN -lt $attempts.Count) { W ('第 {0} 次尝试失败，换参数重试：{1}' -f $tryN, $it.Id) }
    }

    $u = $code
    if ($u -ne $null -and $u -lt 0) { $u += 4294967296 }
    $out = $all
    $err = ''

    $state = 'fail'; $note = '失败'
    if ($all -match 'install technology is different') {
        $state = 'skip'; $note = '需手动'
        W ('提示：' + $it.Name + ' 的安装方式与 winget 清单不一致，winget 无法直接升级。')
    } elseif ($out -match 'Successfully installed|已成功安装') {
        $state = 'ok'; $note = '已完成'
    } elseif ($out -match 'No applicable upgrade|No newer package|没有可用的升级|已是最新') {
        $state = 'skip'; $note = '已是最新'
    } elseif ($u -eq 2316632107) {
        $state = 'skip'; $note = '已是最新'
    } elseif ($code -eq 0) {
        $state = 'ok'; $note = '已完成'
    } else {
        $state = 'fail'
        $hx = ''
        if ($u -ne $null) { $hx = ('0x{0:X8}' -f [uint32]$u) }
        # 状态列空间有限，把常见错误码翻成人话
        $note = if ($hx) { '失败 ' + $hx } else { '失败' }
        if ($all -match 'certificate|证书') { $note = '失败 证书' }
        elseif ($all -match 'No package found|找不到') { $note = '失败 未找到' }
        elseif ($all -match 'Access is denied|拒绝访问|requires elevation') { $note = '失败 权限' }
        elseif ($all -match 'network|网络|timed out|超时') { $note = '失败 网络' }
        # 从 winget 输出里挑第一行有意义的文字，方便判断原因
        $reason = ''
        foreach ($ln in ($all -split "`r?`n")) {
            $t2 = $ln.Trim()
            if (-not $t2) { continue }
            if ($t2 -match '^[-=]{3,}') { continue }
            if ($t2 -match 'Failed when searching source') { continue }
            if ($t2 -match 'An unexpected error occurred') { continue }
            if ($t2 -match '^Name\s+Id\s+Version') { continue }
            $reason = $t2
            break
        }
        if ($reason.Length -gt 200) { $reason = $reason.Substring(0, 200) }
        W ('失败：' + $it.Name + ' 退出码 ' + $note + '  原因: ' + $reason)
    }

    switch ($state) {
        'ok'   { $ok++ }
        'skip' { $skip++ }
        'fail' { $fail++ }
    }
    $map[$it.Idx] = @{ state = $state; note = $note }
    Save-Status
    if ($state -eq 'ok') { W ('完成：' + $it.Name) }
}

# ---------------- Windows 更新（可选更新 / 驱动） ----------------
$wuItems = @($items | Where-Object { ([string]$_.Id).StartsWith('wu:') })
if ($wuItems.Count -gt 0) {
    W ('开始处理 Windows 更新：{0} 项' -f $wuItems.Count)
    $session = $null
    $byId = @{}
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $res = $searcher.Search('IsInstalled=0 and IsHidden=0')
        foreach ($u in $res.Updates) { $byId[([string]$u.Identity.UpdateID).ToLower()] = $u }
    } catch {
        W ('Windows 更新搜索失败：' + $_.Exception.Message)
        $session = $null
    }
    $picked = @()
    foreach ($it in $wuItems) {
        $key = ([string]$it.Id).Substring(3).Split('|')[0].ToLower()
        if ($session -and $byId.ContainsKey($key)) {
            $picked += [pscustomobject]@{ It = $it; Upd = $byId[$key] }
            $map[$it.Idx] = @{ state = 'run'; note = '更新中…'; phase = 'dl' }
        } else {
            $map[$it.Idx] = @{ state = 'skip'; note = '无需更新' }
            $skip++
        }
    }
    Save-Status
    if ($picked.Count -gt 0) {
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($p in $picked) { try { [void]$coll.Add($p.Upd) } catch { } }
        try {
            $dl = $session.CreateUpdateDownloader()
            $dl.Updates = $coll
            [void]$dl.Download()
            W ('下载完成：{0} 项' -f $picked.Count)
        } catch { W ('下载失败：' + $_.Exception.Message) }
        foreach ($p in $picked) {
            $map[$p.It.Idx] = @{ state = 'run'; note = '更新中…'; phase = 'in' }
            Save-Status
            $state = 'fail'; $note = '失败'
            try {
                $one = New-Object -ComObject Microsoft.Update.UpdateColl
                [void]$one.Add($p.Upd)
                $inst = $session.CreateUpdateInstaller()
                $inst.Updates = $one
                $r = $inst.Install()
                $rc = [int]$r.ResultCode
                if ($rc -eq 2 -or $rc -eq 3) {
                    $state = 'ok'; $note = '已完成'
                    if ([bool]$r.RebootRequired) { $note = '已完成 需重启' }
                } else { $note = ('失败 ' + $rc) }
            } catch { $note = '失败' }
            switch ($state) { 'ok' { $ok++ } 'skip' { $skip++ } 'fail' { $fail++ } }
            $map[$p.It.Idx] = @{ state = $state; note = $note }
            Save-Status
            if ($state -eq 'ok') { W ('完成：' + $p.It.Name) } else { W ('失败：' + $p.It.Name + ' ' + $note) }
        }
    }
}

W ('后台任务结束：成功 {0}，需手动 {1}，失败 {2}' -f $ok, $skip, $fail)
try { [System.IO.File]::WriteAllText($done, ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " ok=$ok skip=$skip fail=$fail"), $utf8) } catch { }
