<#
    scripts\lib\Journal.ps1 的测试（SPEC §3.3）

    Journal 是不变量 I2 的实现载体。这一组用例里**最重要的是三条反向判据**：
      · 按 seq 排序会静默重排历史（重复 seq 用例）
      · 中间坏行不能当成尾行丢弃（corrupt_at 用例）
      · Apply 绝不读文件系统（archive.deleted 对不存在的包也要能重放）
#>
. "$PSScriptRoot\lib\GfTest.ps1"
. "$PSScriptRoot\..\scripts\lib\Journal.ps1"

# 临时工作区。用 GUID 隔离，跑完删掉。
$script:Root = [System.IO.Path]::Combine(
    [System.IO.Path]::GetTempPath(), 'gftest-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
function New-ItemDir {
    $d = [System.IO.Path]::Combine($script:Root, [Guid]::NewGuid().ToString('N').Substring(0,6))
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($d, '.gameflow'))
    return $d
}
function Ev {
    param([string]$Kind, [string]$From, [string]$To, [hashtable]$P, [string]$Item = 'g0001-x')
    return New-GfEvent -Actor 'B' -Trigger 'manual' -RunId 'R1' -BatchId '2026-01-01-t' `
                       -ItemId $Item -Kind $Kind -FromState $From -ToState $To -Payload $P
}
function RawWrite {
    param([string]$Dir, [string]$Content)
    [System.IO.File]::WriteAllText((Get-GfJournalPath -ItemDir $Dir), $Content,
                                   (New-Object System.Text.UTF8Encoding($false)))
}

# ── 事件构造（§3.3.1 的字段约束）─────────────────────────────────────────────

Test-Case 'kind 是封闭枚举，未知 kind 必须抛' {
    Assert-Throws { Ev -Kind 'made.up.kind' }
}

Test-Case '只有 state.entered 可以带 from/to（§3.3.1）' {
    Assert-Throws { Ev -Kind 'run.started' -To 'PLANNED' }
}

Test-Case 'state.entered 必须给 ToState' {
    Assert-Throws { Ev -Kind 'state.entered' -From 'PLANNED' }
}

Test-Case 'run_id 形状：<UTC 紧凑>-<8hex>，不得是带冒号的完整 ISO' {
    Assert-Match '^\d{8}T\d{6}Z-[0-9a-f]{8}$' (New-GfRunId)
}

# ── 写入协议（§3.3.4）────────────────────────────────────────────────────────

Test-Case '写入后：一行一条、compact、LF 结尾、UTF-8 无 BOM' {
    $d = New-ItemDir
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'run.started' -P @{ script = 'x' }))
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'run.ended'   -P @{ exit_code = 0 }))
    $bytes = [System.IO.File]::ReadAllBytes((Get-GfJournalPath -ItemDir $d))
    Assert-False ($bytes[0] -eq 0xEF) '数据文件不得有 BOM'
    Assert-Equal 0x0A $bytes[$bytes.Length-1] '必须以 LF 结尾'
    $txt = [System.Text.Encoding]::UTF8.GetString($bytes)
    Assert-Equal 2 (@($txt -split "`n" | Where-Object { $_ -ne '' }).Count)
    Assert-False ($txt -match '\r') '不得出现 CR（LF 不是 CRLF）'
    Assert-False ($txt -match "`n  ") '不得有缩进（必须 -Compress）'
}

Test-Case 'seq 从 1 开始单调递增' {
    $d = New-ItemDir
    $a = Add-GfEvent -ItemDir $d -Event (Ev -Kind 'run.started' -P @{})
    $b = Add-GfEvent -ItemDir $d -Event (Ev -Kind 'run.ended'   -P @{})
    Assert-Equal 1 $a.seq
    Assert-Equal 2 $b.seq
}

Test-Case '撕裂尾行：下次写入前自动封口并补一条 journal.torn_line_sealed' {
    $d = New-ItemDir
    # 模拟崩溃：一条完整行 + 一条写到一半、没有 LF
    RawWrite $d ('{"schema_version":1,"seq":1,"kind":"run.started","item_id":"g0001-x"}' + "`n" +
                 '{"schema_version":1,"seq":2,"kind":"run.en')
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'archive.tested' -P @{ archive = 'a.7z'; exit = 0 }))

    $r = Read-GfEvents -LiteralPath (Get-GfJournalPath -ItemDir $d)
    $kinds = @($r.events | ForEach-Object { $_.kind })
    Assert-True ($kinds -contains 'journal.torn_line_sealed') '必须留下封口痕迹'
    Assert-True ($kinds -contains 'archive.tested') '新事件要写进去'
    Assert-Equal 0x0A ([System.IO.File]::ReadAllBytes((Get-GfJournalPath -ItemDir $d))[-1])
    # **封口之后每一行都必须可解析** —— 这是「中间行坏 = 真正的损坏」能当可靠
    # 信号的前提。用 LF 补一刀的做法会把良性的崩溃恢复变成 JOURNAL_CORRUPT。
    Assert-Equal $null $r.corrupt_at '封口后不得留下不可解析的中间行'
    Assert-False $r.torn_tail
    $sealed = @($r.events | Where-Object { $_.kind -eq 'journal.torn_line_sealed' })[0]
    Assert-Match 'run\.en' $sealed.payload.discarded_text '被丢弃的碎片要留作取证'
}

Test-Case '序列化结果含换行时拒绝写入（构造错误，不是运行时错误）' {
    $d = New-ItemDir
    $ev = Ev -Kind 'run.started' -P @{ note = "a`nb" }
    # ConvertTo-Json 会把换行转义成 \n（两个字符），所以这条**应当能写**。
    # 真正要挡的是有人手工拼 JSON 字符串。这里验证转义路径没被误伤。
    [void](Add-GfEvent -ItemDir $d -Event $ev)
    $r = Read-GfEvents -LiteralPath (Get-GfJournalPath -ItemDir $d)
    Assert-Equal 1 $r.events.Count
    Assert-Equal "a`nb" $r.events[0].payload.note '换行必须被转义后原样还原'
}

# ── 读取协议（§3.3.5）────────────────────────────────────────────────────────

Test-Case '读取：尾部半行被丢弃并标 torn_tail' {
    $d = New-ItemDir
    RawWrite $d ('{"seq":1,"kind":"run.started","item_id":"g0001-x"}' + "`n" + '{"seq":2,"kind":"run')
    $r = Read-GfEvents -LiteralPath (Get-GfJournalPath -ItemDir $d)
    Assert-Equal 1 $r.events.Count
    Assert-True  $r.torn_tail
    Assert-Equal $null $r.corrupt_at
}

Test-Case '读取：**中间**坏行不是尾行撕裂，必须报 corrupt_at' {
    # 这是最关键的一条反向判据：把中间坏行当成尾行丢弃 = 静默丢失历史
    $d = New-ItemDir
    RawWrite $d ('{"seq":1,"kind":"run.started","item_id":"g0001-x"}' + "`n" +
                 '这不是 JSON' + "`n" +
                 '{"seq":3,"kind":"run.ended","item_id":"g0001-x"}' + "`n")
    $r = Read-GfEvents -LiteralPath (Get-GfJournalPath -ItemDir $d)
    Assert-Equal 2 $r.corrupt_at '第 2 行坏'
    Assert-False $r.torn_tail
}

Test-Case '读取：空文件与不存在的文件都返回空集合，不抛' {
    $d = New-ItemDir
    $r1 = Read-GfEvents -LiteralPath (Get-GfJournalPath -ItemDir $d)
    Assert-Equal 0 $r1.events.Count
    RawWrite $d ''
    $r2 = Read-GfEvents -LiteralPath (Get-GfJournalPath -ItemDir $d)
    Assert-Equal 0 $r2.events.Count
}

# ── 重放（§3.3.5 Rebuild）───────────────────────────────────────────────────

Test-Case '重放：状态按事件推进' {
    $d = New-ItemDir
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'item.registered' -P @{ dirname = 'x' }))
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'state.entered' -To 'PLANNED' -P @{ transition_id='M01' }))
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'state.entered' -From 'PLANNED' -To 'AWAITING_DOWNLOAD' -P @{ transition_id='M02' }))
    $s = Invoke-GfRebuild -ItemDir $d
    Assert-Equal 'AWAITING_DOWNLOAD' $s.state
    Assert-Equal 3 $s.last_event_seq
    Assert-False $s.divergence
}

Test-Case '重放：**按文件行序，不按 seq 排序**（重复 seq 不得重排历史）' {
    # 封口后允许出现一次重复 seq（§3.3.5）。若按 seq 排序，下面两条的先后不确定，
    # 重放结果就不确定 —— I2 失效。行序下结果必然是 EXTRACTED。
    $d = New-ItemDir
    RawWrite $d (
        '{"seq":1,"kind":"item.registered","item_id":"g0001-x","payload":{}}' + "`n" +
        '{"seq":7,"kind":"state.entered","item_id":"g0001-x","from_state":null,"to_state":"VERIFYING","payload":{}}' + "`n" +
        '{"seq":7,"kind":"state.entered","item_id":"g0001-x","from_state":"VERIFYING","to_state":"EXTRACTED","payload":{}}' + "`n")
    $s = Invoke-GfRebuild -ItemDir $d
    Assert-Equal 'EXTRACTED' $s.state '必须取文件里靠后的那条，而不是 seq 排序后的某条'
}

Test-Case '重放：from_state 与快照不一致 → 采用事件的 to_state 并记 divergence' {
    $d = New-ItemDir
    RawWrite $d (
        '{"seq":1,"kind":"item.registered","item_id":"g0001-x","payload":{}}' + "`n" +
        '{"seq":2,"kind":"state.entered","item_id":"g0001-x","from_state":null,"to_state":"PLANNED","payload":{}}' + "`n" +
        '{"seq":3,"kind":"state.entered","item_id":"g0001-x","from_state":"EXTRACTING","to_state":"EXTRACTED","payload":{}}' + "`n")
    $s = Invoke-GfRebuild -ItemDir $d
    Assert-Equal 'EXTRACTED' $s.state 'journal 是真相，重建器无权否决'
    Assert-True  $s.divergence '但必须记下来并在报告里标红'
}

Test-Case '重放：中间坏行 → 不推进任何状态（调用方据此落 JOURNAL_CORRUPT）' {
    $d = New-ItemDir
    RawWrite $d (
        '{"seq":1,"kind":"state.entered","item_id":"g0001-x","from_state":null,"to_state":"PLANNED","payload":{}}' + "`n" +
        'broken' + "`n" +
        '{"seq":3,"kind":"state.entered","item_id":"g0001-x","from_state":"PLANNED","to_state":"EXTRACTED","payload":{}}' + "`n")
    $s = Invoke-GfRebuild -ItemDir $d
    Assert-Equal $null $s.state '坏日志绝不能推进状态'
    Assert-Equal 2 $s.journal_corrupt_at
}

Test-Case '重放：halt 进入与解除' {
    $d = New-ItemDir
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'item.registered' -P @{}))
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'state.entered' -To 'WAITING_FOR_PASSWORD' -P @{}))
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'halt.entered' -P @{ reason_code='NO_PASSWORD'; resume_allowed=@('PREFLIGHT_OK') }))
    $s1 = Invoke-GfRebuild -ItemDir $d
    Assert-Equal 'NO_PASSWORD' $s1.halt.reason_code
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'halt.cleared' -P @{}))
    $s2 = Invoke-GfRebuild -ItemDir $d
    Assert-Equal $null $s2.halt
}

Test-Case '重放：archive 用绝对赋值而非计数，重放两次结果相同（幂等）' {
    $d = New-ItemDir
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'item.registered' -P @{}))
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'archive.verified' -P @{ archive='a.7z'; consumed_by='att1'; sha256='ab12' }))
    $s1 = Invoke-GfRebuild -ItemDir $d
    $s2 = Invoke-GfRebuild -ItemDir $d
    Assert-True $s1.archives['a.7z'].verified
    Assert-Equal 'att1' $s1.archives['a.7z'].consumed_by
    Assert-Equal $s1.archives['a.7z'].sha256 $s2.archives['a.7z'].sha256 '重放必须幂等'
}

Test-Case '重放：Apply 绝不读文件系统（对不存在的包也能重放 archive.deleted）' {
    # 一旦 Apply 去「看一眼盘上现在什么样」，I3 与幂等就破了
    $d = New-ItemDir
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'item.registered' -P @{}))
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'archive.deleted' -P @{ archive='从来不存在.7z'; result='deleted' }))
    $s = Invoke-GfRebuild -ItemDir $d
    Assert-Equal 'deleted' $s.archives['从来不存在.7z'].delete_result
}

Test-Case '重放：复活语义 —— 旧化身的事件折进 history，不参与状态推进' {
    $d = New-ItemDir
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'item.registered' -Item 'g0001-old' -P @{}))
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'state.entered' -To 'ABANDONED' -Item 'g0001-old' -P @{}))
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'item.registered' -Item 'g0002-new' -P @{}))
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'state.entered' -To 'PLANNED' -Item 'g0002-new' -P @{}))
    $s = Invoke-GfRebuild -ItemDir $d
    Assert-Equal 'PLANNED' $s.state '当前化身是 g0002-new'
    Assert-True ($s.history.Count -ge 2) '旧化身的事件要进 history'
}

Test-Case '崩溃探测：run.started 无配对 run.ended（纯 journal 推导，无时间猜测）' {
    $d = New-ItemDir
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'run.started' -P @{}))
    Assert-True (Test-GfCrashedLastRun -ItemDir $d)
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'run.ended' -P @{ exit_code = 0 }))
    Assert-False (Test-GfCrashedLastRun -ItemDir $d)
}

# ── 中文与编码（§8.8.2 的回归）───────────────────────────────────────────────

Test-Case '中文条目名往返无损（数据文件无 BOM + 显式 UTF-8）' {
    $d = New-ItemDir
    [void](Add-GfEvent -ItemDir $d -Event (Ev -Kind 'download.claimed' -P @{ file = '某游戏 第一章.part1.rar' }))
    $s = Read-GfEvents -LiteralPath (Get-GfJournalPath -ItemDir $d)
    Assert-Equal '某游戏 第一章.part1.rar' $s.events[0].payload.file
}

Test-Case 'JSON 深度：第 4 层不被静默截断（§8.8.3）' {
    $deep = @{ a = @{ b = @{ c = @{ d = 'bottom' } } } }
    $back = ConvertFrom-GfJson -Json (ConvertTo-GfJson -InputObject $deep -Compress)
    Assert-Equal 'bottom' $back.a.b.c.d '裸 ConvertTo-Json 的默认 -Depth 2 会在这里静默丢数据'
}

# ── 清理 ─────────────────────────────────────────────────────────────────────
if ([System.IO.Directory]::Exists($script:Root)) {
    [System.IO.Directory]::Delete($script:Root, $true)
}

exit (Invoke-GfTestSummary -Title 'Journal.ps1')
