<#
    GameFlow · Journal.ps1 —— events.jsonl 的写入、读取与重放（SPEC §3.3）

    这是不变量 I2 的实现载体：**events.jsonl 是唯一真相，state.json 只是可以
    随时删掉重建的派生快照**。写错这里，整个状态机的地基就塌了。

    三条最容易写错、且错了是静默的：
      1. 忘了 -Compress  → 多行 JSON 彻底毁掉「一行一条」的可恢复性
      2. 按 seq 排序重放 → 封口后允许出现重复 seq，排序会静默重排历史
      3. 保持长开 StreamWriter → 进程被强杀时缓冲区全丢
#>

if (-not $script:GfJsonLoaded) { . "$PSScriptRoot\Json.ps1"; $script:GfJsonLoaded = $true }

# §3.3.2 的 kind 闭集。**不是自由文本** —— 自由文本会逼对账脚本做模糊匹配。
$script:GfEventKinds = @(
    'run.started','run.ended','item.registered','env.snapshot',
    'download.claimed','download.gate','volume.group.formed','archive.identified',
    'expected.declared','password.attempted','archive.tested',
    'extract.attempt.started','extract.attempt.finished','verify.entry.mismatch',
    'staging.promoted','staging.discarded','archive.verified','archive.deleted',
    'defender.scanned','engine.detected','delivery.started','delivery.finished',
    'state.entered','halt.entered','halt.cleared','state.rebuilt',
    'journal.torn_line_sealed','report.written','vault.updated','human.action'
)

function Get-GfEventKinds { return $script:GfEventKinds }

function New-GfRunId {
    <# §3.3.1：<UTC yyyyMMddTHHmmssZ>-<8hex>。报告 front-matter 用的也是这个形状。 #>
    return ('{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'),
                         [Guid]::NewGuid().ToString('N').Substring(0,8))
}

function New-GfEvent {
    <#
        构造一条符合 §3.3.1 的事件。seq 留 0，由 Add-GfEvent 在写入时确定
        —— seq 是「本文件内」的序号，构造时还不知道要写进哪个文件。
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('A','B','C','human')][string]$Actor,
        [Parameter(Mandatory)][ValidateSet('scheduled','manual','codex')][string]$Trigger,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$BatchId,
        [Parameter(Mandatory)][string]$ItemId,
        [Parameter(Mandatory)][string]$Kind,
        [string]$FromState,
        [string]$ToState,
        [hashtable]$Payload,
        [hashtable]$Evidence
    )
    if ($script:GfEventKinds -notcontains $Kind) {
        throw "未知 kind '$Kind'。§3.3.2 是封闭枚举，新增 kind 必须先改 SPEC。"
    }
    # §3.3.1：只有 state.entered 的 from/to 非 null，其余一律 null
    if ($Kind -ne 'state.entered' -and ($FromState -or $ToState)) {
        throw "kind='$Kind' 不得带 from_state/to_state（§3.3.1：只有 state.entered 可以）"
    }
    if ($Kind -eq 'state.entered' -and -not $ToState) {
        throw "kind='state.entered' 必须给 ToState"
    }
    return [ordered]@{
        schema_version = 1
        seq            = 0
        ts             = [DateTimeOffset]::UtcNow.ToString('o')
        actor          = $Actor
        trigger        = $Trigger
        run_id         = $RunId
        batch_id       = $BatchId
        item_id        = $ItemId
        kind           = $Kind
        from_state     = $(if ($FromState) { $FromState } else { $null })
        to_state       = $(if ($ToState)   { $ToState }   else { $null })
        payload        = $(if ($Payload)  { $Payload }  else { @{} })
        evidence       = $(if ($Evidence) { $Evidence } else { $null })
    }
}

function Get-GfJournalPath {
    param([Parameter(Mandatory)][string]$ItemDir)
    return [System.IO.Path]::Combine($ItemDir, '.gameflow', 'events.jsonl')
}

function Add-GfEvent {
    <#
    .SYNOPSIS
        §3.3.4 的写入协议，照着实现。
    .DESCRIPTION
        开 → （必要时封口）→ 算 seq → 序列化 → 组装成一个 byte[] → 写 → Flush(true) → 关。
        **每条事件独立开关文件**：保持长开的 StreamWriter 在进程被强杀时会丢缓冲区。
    .OUTPUTS
        写入后的事件对象（seq 已填）。
    #>
    param(
        [Parameter(Mandatory)][string]$ItemDir,
        [Parameter(Mandatory)]$Event,
        [switch]$NoSeal          # 内部递归写封口事件时用，避免无限递归
    )
    $path = Get-GfJournalPath -ItemDir $ItemDir
    $dir  = [System.IO.Path]::GetDirectoryName($path)
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }

    # 第 2 步：上次崩溃留下半行 → **截断掉它**，再记一条 journal.torn_line_sealed。
    #
    # 注意这里与 SPEC 原文的差异（2026-09-14 由测试抓出，SPEC 已同步修正）：
    # 原文说「写入单字节 0x0A 封口」。那样做的后果是把「尾行撕裂」（良性、
    # 每次崩溃都会发生）变成「中间行不可解析」（致命，落 JOURNAL_CORRUPT）——
    # 下一次读取会把一次普通的崩溃恢复报成日志损坏。
    #
    # 改为截断到最后一个完整行，于是得到一条强不变量：
    # **events.jsonl 里每一行永远可解析**。这让「中间行坏 = 真正的损坏」
    # 成为一个可靠信号，而不是崩溃的副产物。
    # 被丢弃的半行是 JSON 碎片、本来就无法解析，其内容原样记进封口事件的
    # payload 留作取证，比留在文件里当一行坏数据更有用。
    if (-not $NoSeal -and -not (Test-GfFileEndsWithLf -LiteralPath $path)) {
        $discarded = ''
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open,
                                     [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $len = [int]$fs.Length
            $buf = New-Object byte[] $len
            [void]$fs.Read($buf, 0, $len)
            $lastLf = [System.Array]::LastIndexOf($buf, [byte]0x0A)
            $keep   = $lastLf + 1                      # 没有 LF 时 lastLf = -1 → keep = 0
            $discarded = (Get-GfUtf8NoBom).GetString($buf, $keep, $len - $keep)
            $fs.SetLength($keep)
            $fs.Flush($true)
        } finally { $fs.Dispose() }

        if ($discarded.Length -gt 400) { $discarded = $discarded.Substring(0, 400) + '…(truncated)' }
        $sealEv = New-GfEvent -Actor $Event.actor -Trigger $Event.trigger -RunId $Event.run_id `
                              -BatchId $Event.batch_id -ItemId $Event.item_id `
                              -Kind 'journal.torn_line_sealed' `
                              -Payload @{
                                  note           = '上次运行被中断，尾部半行已截断'
                                  discarded_text = $discarded
                              }
        [void](Add-GfEvent -ItemDir $ItemDir -Event $sealEv -NoSeal)
    }

    # 第 3 步：seq = 本文件全部**可解析行**的 max(seq) + 1
    $Event.seq = (Get-GfNextSeq -LiteralPath $path)

    # 第 4 步：-Compress 是硬要求；并断言行内不含换行
    $line = ConvertTo-GfJson -InputObject $Event -Compress
    if ($line.IndexOf([char]0x0A) -ge 0 -or $line.IndexOf([char]0x0D) -ge 0) {
        throw "序列化结果含换行符，会毁掉「一行一条」。这是构造错误，不写入。"
    }

    # 第 5–6 步：组装成**一个** byte[] 一次写完，然后 Flush($true)
    $bytes = (Get-GfUtf8NoBom).GetBytes($line + "`n")
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Append,
                                 [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush($true)      # 唯一真正有断电保证的一步（对应 Win32 FlushFileBuffers）
    } finally { $fs.Dispose() }

    return $Event
}

function Get-GfNextSeq {
    param([Parameter(Mandatory)][string]$LiteralPath)
    if (-not [System.IO.File]::Exists($LiteralPath)) { return 1 }
    $max = 0
    foreach ($line in (Read-GfText -LiteralPath $LiteralPath) -split "`n") {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $ev = ConvertFrom-GfJson -Json $line
        if ($null -ne $ev -and $null -ne $ev.seq -and [int]$ev.seq -gt $max) { $max = [int]$ev.seq }
    }
    return $max + 1
}

function Read-GfEvents {
    <#
    .SYNOPSIS
        §3.3.5 的读取协议。
    .OUTPUTS
        [ordered]@{ events = @(); torn_tail = $bool; corrupt_at = $int|null }
        corrupt_at 非 null ⇒ 中间行坏了 ⇒ 调用方必须落 JOURNAL_CORRUPT（§4.3），
        **不是**运行期状况：运行期状况下次运行还是坏的，条目会永久静默停在原地。
    #>
    param([Parameter(Mandatory)][string]$LiteralPath)
    $res = [ordered]@{ events = @(); torn_tail = $false; corrupt_at = $null }
    $text = Read-GfText -LiteralPath $LiteralPath
    if ($null -eq $text) { return $res }

    $lines = $text -split "`n"
    # 按 0x0A 切分后，正常封口的文件最后一段必然是空串，去掉它
    $lastIdx = $lines.Count - 1
    if ($lastIdx -ge 0 -and $lines[$lastIdx] -eq '') { $lines = $lines[0..($lastIdx-1)]; $lastIdx-- }
    if ($lastIdx -lt 0) { return $res }

    $acc = New-Object System.Collections.ArrayList
    for ($i = 0; $i -le $lastIdx; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $ev = ConvertFrom-GfJson -Json $line
        if ($null -eq $ev) {
            if ($i -eq $lastIdx) { $res.torn_tail = $true; break }   # 崩溃留下的半行，丢弃
            $res.corrupt_at = $i + 1                                  # 中间坏行 = 真正的损坏
            break
        }
        [void]$acc.Add($ev)
    }
    $res.events = @($acc)
    return $res
}

function Invoke-GfRebuild {
    <#
    .SYNOPSIS
        从 events.jsonl 重建 state（§3.3.5 的 Rebuild）。
    .DESCRIPTION
        三条硬规则：
          · **重放顺序 = 文件行序，绝不按 seq 排序。** seq 只用于人读与断裂检测；
            封口后允许出现一次重复值，排序会让这两条的先后不确定 ⇒ 重放结果不确定。
          · **Apply 绝不读文件系统。** 一旦「看一眼盘上现在什么样」，I3 与幂等就破了。
          · **事件是真相**：from_state 与快照不一致时采用事件的 to_state 继续，
            但要记 divergence 并在报告里标红 —— 重建器没有资格否决 append-only 日志。
    #>
    param([Parameter(Mandatory)][string]$ItemDir)

    $path = Get-GfJournalPath -ItemDir $ItemDir
    $read = Read-GfEvents -LiteralPath $path

    $s = [ordered]@{
        schema_version = 1
        state          = $null
        entered_at     = $null
        halt           = $null
        archives       = @{}
        last_event_seq = 0
        last_run       = $null
        divergence     = $false
        tail_discarded = [bool]$read.torn_tail
        journal_corrupt_at = $read.corrupt_at
        history        = @()
        rebuilt_at     = [DateTimeOffset]::UtcNow.ToString('o')
    }
    if ($null -ne $read.corrupt_at) { return $s }   # 调用方据此落 JOURNAL_CORRUPT
    if ($read.events.Count -eq 0)   { return $s }

    # §4.8.3 复活语义：以**最后一条 item.registered** 声明的 item_id 为当前化身，
    # 之前化身的事件全部折进 history，不参与状态推进。
    $active = $null
    foreach ($ev in $read.events) { if ($ev.kind -eq 'item.registered') { $active = $ev.item_id } }
    if ($null -eq $active) { $active = $read.events[-1].item_id }

    $hist = New-Object System.Collections.ArrayList
    foreach ($ev in $read.events) {
        if ($ev.item_id -ne $active) {
            [void]$hist.Add([ordered]@{ seq = $ev.seq; ts = $ev.ts; item_id = $ev.item_id; kind = $ev.kind })
            continue
        }
        switch ($ev.kind) {
            'state.entered' {
                if ($null -ne $s.state -and $ev.from_state -ne $s.state) { $s.divergence = $true }
                $s.state      = $ev.to_state
                $s.entered_at = $ev.ts
                $s.halt       = $null          # 进入任何状态都先清 halt，由随后的 halt.entered 重新置上
            }
            'halt.entered' {
                $s.halt = [ordered]@{
                    reason_code        = $ev.payload.reason_code
                    resume_allowed     = $ev.payload.resume_allowed
                    cleared_by_allowed = $ev.payload.cleared_by_allowed
                }
            }
            'halt.cleared'   { $s.halt = $null }
            'archive.verified' {
                # **绝对赋值，不是计数** —— 记「+1」会在重放时累加出错误结果
                $s.archives[[string]$ev.payload.archive] = [ordered]@{
                    verified    = $true
                    consumed_by = $ev.payload.consumed_by
                    sha256      = $ev.payload.sha256
                    deleted_at  = $null
                }
            }
            'archive.deleted' {
                $k = [string]$ev.payload.archive
                if (-not $s.archives.ContainsKey($k)) { $s.archives[$k] = [ordered]@{ verified = $false } }
                $s.archives[$k].deleted_at = $ev.ts
                $s.archives[$k].delete_result = $ev.payload.result
            }
            'run.started' { $s.last_run = [ordered]@{ run_id = $ev.run_id; started_at = $ev.ts; ended_at = $null } }
            'run.ended'   { if ($s.last_run -and $s.last_run.run_id -eq $ev.run_id) { $s.last_run.ended_at = $ev.ts } }
        }
        $s.last_event_seq = [int]$ev.seq
    }
    $s.history = @($hist)
    return $s
}

function Test-GfCrashedLastRun {
    <#
        上次崩溃的探测器 = 有 run.started 而无配对 run.ended（§3.3.5）。
        **纯 journal 推导，无时间猜测** —— 不看进程、不看时间戳、不设超时。
    #>
    param([Parameter(Mandatory)][string]$ItemDir)
    $read = Read-GfEvents -LiteralPath (Get-GfJournalPath -ItemDir $ItemDir)
    $open = @{}
    foreach ($ev in $read.events) {
        if ($ev.kind -eq 'run.started') { $open[[string]$ev.run_id] = $true }
        if ($ev.kind -eq 'run.ended')   { [void]$open.Remove([string]$ev.run_id) }
    }
    return ($open.Keys.Count -gt 0)
}
