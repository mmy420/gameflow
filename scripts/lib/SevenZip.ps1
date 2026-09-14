<#
    GameFlow · SevenZip.ps1 —— 全项目唯一的 7-Zip 封装（SPEC §6.2）

    项目内**禁止**在任何地方直接拼 7-Zip 命令行。理由不是洁癖：§6.2.4 那九个陷阱
    每一个都会导致「看起来成功、实际没干活」，而下游是「测通过 → 删源包」这条
    不可逆的链。把它们堵在一个函数里，比指望每个调用点都记得强。

    ⚠️ 执行环境（契约 SZ-4）：**必须 pwsh 7.4+**。
    5.1 下不存在任何安全的方式把含空格/引号/$/`/% 的密码与路径传给 7z.exe ——
    Start-Process -ArgumentList 只用单空格拼接，而 ProcessStartInfo.ArgumentList
    在 .NET Framework 上根本不存在。Preflight 探测不到 pwsh 时 B 拒绝运行，不降级。
#>

if (-not $script:GfIoLoaded3) { . "$PSScriptRoot\Io.ps1"; $script:GfIoLoaded3 = $true }

# §6.2.1：-TypeSpec 白名单。**永不出现具体类型名**（-t7z/-tzip/-trar…）——
# 那会关闭内容嗅探，把本可自动处理的情况变成 exit 2 硬失败。
$script:GfTypeSpecWhitelist = @('none', '*', '*:s16m', '*:s64m', '#:e')

function Get-GfTypeSpecWhitelist { return $script:GfTypeSpecWhitelist }

function Invoke-SevenZip {
    <#
    .SYNOPSIS
        §6.2.1 的唯一入口。
    .PARAMETER Op        只有 l / t / x 三个命令，永不用 a/u/d/rn
    .PARAMETER Archive   **单个**绝对路径。永不传第二个位置归档参数（陷阱 T2）
    .PARAMETER Filter    归档内条目路径；用后必须校验 Files: 1
    .PARAMETER OutDir    仅 Op='x'
    .PARAMETER Password  $null 或 '' → **完全不传 -p**（陷阱 T5）
    .PARAMETER TypeSpec  白名单之一；'none' = 不传 -t，走默认 -t*:r 内容嗅探
    .OUTPUTS
        ExitCode / TimedOut / Stdout / FilesReported / FoldersReported / Warnings / Entries / ArchiveInfo / Argv
    #>
    # PSScriptAnalyzer 会对 [string]$Password 报 PSAvoidUsingPlainTextForPassword。
    # **这里是刻意的，不是疏忽**，理由写在下面，所以显式豁免而不是让它变成常驻噪音
    # （常驻告警会掩盖以后真正该看的那条）：
    #   · 7-Zip **只能**经 -p 接受密码（官方 password.htm 只有这一种语法，
    #     管道/文件重定向/环境变量均实测证伪）→ 明文进程命令行不可消除
    #   · §6.3 的等价展开要做 UTF-8↔GBK 的**字节**转换，本身就必须拿到明文，
    #     SecureString 在这个边界上买不到任何实际收益，只会把解包点往前挪一格
    #   · 这条暴露面已在 §9.1 作为「不可控」诚实写明，并给出了可控的那一半：
    #     不进清单/日志/报告/Git，Argv 写日志前必过 Get-GfRedactedArgv
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = '7-Zip 只接受命令行 -p；§6.3 的等价展开本就需要明文。暴露面见 §9.1。')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('l','t','x')][string]$Op,
        [Parameter(Mandatory)][string]$Archive,
        [string]$Filter,
        [string]$OutDir,
        [AllowEmptyString()][AllowNull()][string]$Password,
        [string]$TypeSpec = 'none',
        [int]$TimeoutSec = 1800,
        [string]$SevenZipExe
    )

    if ($script:GfTypeSpecWhitelist -notcontains $TypeSpec) {
        throw "TypeSpec '$TypeSpec' 不在白名单 $($script:GfTypeSpecWhitelist -join '|')。具体类型名会关闭内容嗅探（§6.2.1 T4）。"
    }
    if ($Op -ne 'x' -and $OutDir) { throw "-OutDir 只对 Op='x' 有意义" }
    if ($Op -eq 'x' -and -not $OutDir) { throw "Op='x' 必须给 -OutDir（绝不就地解压，§6.2.4 T7）" }

    $exe = $SevenZipExe
    if (-not $exe) {
        foreach ($n in @('7z','7zz','7za')) {
            $c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($c) { $exe = $c.Source; break }
        }
    }
    if (-not $exe) { throw '找不到 7-Zip 可执行文件。正式运行必须由 Preflight 给出绝对路径，不依赖 PATH。' }

    # ── 组装参数（逐参数投递，绝不拼字符串）────────────────────────────────
    $argv = New-Object System.Collections.Generic.List[string]
    $argv.Add($Op)
    $argv.Add('-y')             # 无提示。注意默认即「无提示覆盖全部」，所以 -o 必须是我们建的空目录
    $argv.Add('-bso1')          # stdout 与 stderr 都并进 stdout，解析器只需一个状态机
    $argv.Add('-bse1')
    if ($Op -eq 'l') { $argv.Add('-slt') }
    if ($Op -eq 'x') { $argv.Add('-aoa'); $argv.Add('-snz') }
    if ($TypeSpec -ne 'none') { $argv.Add("-t$TypeSpec") }
    # 密码为空时**完全不传 -p**：裸 -p 会让 7-Zip 切进交互模式并表现成「密码错」（T5）
    if (-not [string]::IsNullOrEmpty($Password)) { $argv.Add("-p$Password") }
    if ($Op -eq 'x') { $argv.Add("-o$OutDir") }
    $argv.Add('--')             # 终止开关解析，防止以 - 开头的归档名被当成开关
    $argv.Add($Archive)
    if ($Filter) { $argv.Add($Filter) }

    # ── 启动 ────────────────────────────────────────────────────────────────
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $exe
    $psi.UseShellExecute        = $false      # 必须：否则拿不到重定向
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $true       # 立刻关掉 → 加密包见到 EOF 而不是挂住（T6）
    $psi.StandardOutputEncoding = (Get-GfUtf8NoBom)
    $psi.StandardErrorEncoding  = (Get-GfUtf8NoBom)
    if (-not $psi.PSObject.Properties['ArgumentList']) {
        throw 'ProcessStartInfo.ArgumentList 不可用 —— 本模块要求 pwsh 7.4+（契约 SZ-4）。5.1 下无法安全传参。'
    }
    foreach ($a in $argv) { $psi.ArgumentList.Add($a) }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    [void]$proc.Start()
    try { $proc.StandardInput.Close() } catch { }

    # 先异步收流再等退出，避免管道写满导致的死锁
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    $timedOut = $false
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        $timedOut = $true
        try { $proc.Kill($true) } catch { }
        [void]$proc.WaitForExit(5000)
    }
    $stdout = ''
    $stderr = ''
    try { $stdout = $outTask.GetAwaiter().GetResult() } catch { }
    try { $stderr = $errTask.GetAwaiter().GetResult() } catch { }
    $exit = -1
    try { $exit = $proc.ExitCode } catch { }
    $proc.Dispose()

    # §6.2.1：按 \r 与 \n **同时**切分。7-Zip 的进度行用 \r 回车覆盖，
    # 只按 \n 切会把整段进度粘成一行巨长的字符串。
    $lines = @(($stdout + "`n" + $stderr) -split "[`r`n]+" | Where-Object { $_ -ne '' })

    $parsed = ConvertFrom-GfSevenZipOutput -Lines $lines -Op $Op
    return [pscustomobject]@{
        ExitCode        = $exit
        TimedOut        = $timedOut
        Stdout          = $lines
        FilesReported   = $parsed.FilesReported
        FoldersReported = $parsed.FoldersReported
        Warnings        = $parsed.Warnings
        Entries         = $parsed.Entries
        ArchiveInfo     = $parsed.ArchiveInfo
        Argv            = @($argv)          # 供日志脱敏后记录；**绝不整体写日志**（含 -p）
    }
}

function ConvertFrom-GfSevenZipOutput {
    <#
    .SYNOPSIS
        解析 7-Zip 的输出。拆成独立函数，好处是**不需要真的跑 7z 就能测**。
    .DESCRIPTION
        -slt 的输出形状（实测 26.03）：

            Listing archive: plain.7z
            --                      ← 归档级块开始
            Path = plain.7z
            Type = 7z
            Physical Size = 263
            ----------              ← 条目级块开始
            Path = src
            Size = 0
            Attributes = D drwxr-xr-x     ← 含 D 即目录
            <空行分隔下一条>

        目录判定看 Attributes 是否含 D —— §6.2.4 的 SZ-3 要拿「非目录条目数」
        与 `Files: N` 对账，把目录算进去就永远对不上。
    #>
    # AllowEmptyString 是必需的：**空行正是 -slt 分隔条目的方式**，
    # 少了它解析器连自己要解析的格式都收不下。
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [string]$Op = 'l'
    )

    $res = [ordered]@{
        FilesReported = $null; FoldersReported = $null
        Warnings = @(); Entries = @(); ArchiveInfo = $null
    }
    $warnings = New-Object System.Collections.ArrayList
    $entries  = New-Object System.Collections.ArrayList

    $section = 'head'          # head → archive → entries
    $cur     = $null
    $inWarnBlock = $false

    foreach ($raw in $Lines) {
        $line = $raw.TrimEnd()

        # 摘要行
        if ($line -match '^Files:\s+(\d+)\s*$')   { $res.FilesReported   = [int]$Matches[1]; continue }
        if ($line -match '^Folders:\s+(\d+)\s*$') { $res.FoldersReported = [int]$Matches[1]; continue }

        # 警告：`WARNINGS:` 段 与 `Open WARNING:` 行（§6.2.3：它与退出码是两条独立信号）
        if ($line -match '^WARNINGS?:\s*$') { $inWarnBlock = $true; continue }
        if ($line -match '^(Open WARNING|WARNING):\s*(.+)$') { [void]$warnings.Add($line); continue }
        if ($inWarnBlock) {
            if ($line -eq '') { $inWarnBlock = $false } else { [void]$warnings.Add($line) }
            continue
        }

        # 分段标记
        if ($line -eq '--')         { $section = 'archive'; $cur = [ordered]@{}; continue }
        if ($line -match '^-{5,}$') {
            if ($section -eq 'archive' -and $cur -and $cur.Count) { $res.ArchiveInfo = $cur }
            $section = 'entries'; $cur = $null; continue
        }

        if ($section -eq 'head') { continue }

        if ($line -eq '') {
            if ($section -eq 'entries' -and $cur -and $cur.Count) { [void]$entries.Add($cur); $cur = $null }
            continue
        }

        # Key = Value（值可以为空）
        $eq = $line.IndexOf(' = ')
        if ($eq -lt 0) {
            if ($line.EndsWith(' =')) { $eq = $line.Length - 2 } else { continue }
        }
        $k = $line.Substring(0, $eq).Trim()
        $v = if ($eq + 3 -le $line.Length) { $line.Substring($eq + 3) } else { '' }

        if ($section -eq 'archive') {
            if ($null -eq $cur) { $cur = [ordered]@{} }
            $cur[$k] = $v
        } else {
            # 新条目的起点永远是 Path
            if ($k -eq 'Path') {
                if ($cur -and $cur.Count) { [void]$entries.Add($cur) }
                $cur = [ordered]@{}
            }
            if ($null -eq $cur) { $cur = [ordered]@{} }
            $cur[$k] = $v
        }
    }
    if ($section -eq 'archive' -and $cur -and $cur.Count) { $res.ArchiveInfo = $cur }
    if ($section -eq 'entries' -and $cur -and $cur.Count) { [void]$entries.Add($cur) }

    $res.Warnings = @($warnings)
    $res.Entries  = @($entries)
    return $res
}

function Test-GfSevenZipEntryIsDir {
    <# Attributes 含 D 即目录（实测 26.03：`Attributes = D drwxr-xr-x`）。 #>
    param([Parameter(Mandatory)]$Entry)
    $a = ''
    if ($Entry -is [System.Collections.IDictionary] -and $Entry.Contains('Attributes')) { $a = [string]$Entry['Attributes'] }
    return ($a -match '(^|\s)D')
}

function Get-GfSevenZipFileEntryCount {
    <# 非目录条目数 —— SZ-3 第 3 条要拿它与 `Files: N` 对账。 #>
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Entries)
    return @($Entries | Where-Object { -not (Test-GfSevenZipEntryIsDir -Entry $_) }).Count
}

function Test-GfSevenZipSuccess {
    <#
    .SYNOPSIS
        契约 SZ-3：t / x 判成功需要三条**同时**成立。
    .DESCRIPTION
        1. ExitCode -eq 0 **严格相等**。不是 -ne 2，不是 -le 1。
           exit 1 的字面含义是「完成了但有东西被静默跳过」，映射到本项目就是
           「解压『成功』→ 删掉源包 → 游戏缺文件 → 源包已经没了」这条不可逆的链。
        2. Warnings 为空，或全部命中白名单。
           **Warnings 与退出码是两条独立信号** —— 可以报了 warning 而 exit 仍是 0。
        3. Files: N 存在、N > 0、且等于同一 TypeSpec 下 l -slt 的非目录条目数。
           这一条是 T1/T2/T3（exit 0 却零文件的四种情形）的唯一解药。
    .OUTPUTS
        [ordered]@{ Ok; Failures[] }
    #>
    param(
        [Parameter(Mandatory)]$Result,
        [int]$ExpectedFileEntries = -1,
        [string[]]$WarningWhitelist = @()
    )
    $f = New-Object System.Collections.ArrayList
    if ($Result.TimedOut)      { [void]$f.Add('TIMED_OUT') }
    if ($Result.ExitCode -ne 0) { [void]$f.Add("EXIT_NOT_ZERO:$($Result.ExitCode)") }

    foreach ($w in @($Result.Warnings)) {
        $hit = $false
        foreach ($p in $WarningWhitelist) { if ($w -match $p) { $hit = $true; break } }
        if (-not $hit) { [void]$f.Add("UNKNOWN_WARNING:$w") }
    }

    if ($null -eq $Result.FilesReported) { [void]$f.Add('NO_FILES_LINE') }
    elseif ($Result.FilesReported -le 0) { [void]$f.Add('ZERO_FILES') }
    elseif ($ExpectedFileEntries -ge 0 -and $Result.FilesReported -ne $ExpectedFileEntries) {
        [void]$f.Add("FILES_MISMATCH:reported=$($Result.FilesReported),listed=$ExpectedFileEntries")
    }

    return [ordered]@{ Ok = ($f.Count -eq 0); Failures = @($f) }
}

function Get-GfSevenZipExit2Reason {
    <#
        §6.2.5 的 exit 2 文案分流表。返回封闭代码，**不是自由文本**。
        注意 `DATA_ERROR_ENCRYPTED` 是**模糊**的：7z 的 AES-256 数据流没有密码
        校验值，7-Zip 自己也分不清「密码错」与「密文损坏」—— 官方文案里那个
        问号就是在承认这一点。消歧规则见 §6.3，不在这里猜。
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)
    $text = ($Lines -join "`n")
    # ⚠ **顺序不可换：具体文案必须排在通用文案之前。**
    # 'Cannot open encrypted archive. Wrong password?' 与
    # 'Data Error in encrypted file. Wrong password? : <path>' 都含子串 'Wrong password'。
    # 若先匹配通用的，模糊的 DATA_ERROR_ENCRYPTED 会被误判成确定的 WRONG_PASSWORD，
    # 状态机就会跳过 EXTRACT_FAILED_AMBIGUOUS 直奔 WAITING_FOR_PASSWORD ——
    # 丢掉「也可能是数据损坏」这一半，而那正是 §6.2.5 反复强调要保留的信息。
    if ($text -match 'Cannot open encrypted archive')          { return 'WRONG_PASSWORD_HEADER' }
    if ($text -match 'Data Error in encrypted file')           { return 'DATA_ERROR_ENCRYPTED' }  # 模糊
    if ($text -match 'Wrong password')                         { return 'WRONG_PASSWORD' }
    if ($text -match 'CRC Failed')                             { return 'CRC_FAILED' }
    if ($text -match 'Unexpected end of archive')              { return 'UNEXPECTED_END' }        # 截断或缺卷
    if ($text -match 'Dangerous link path was ignored')        { return 'DANGEROUS_LINK' }
    if ($text -match 'Unsupported Method')                     { return 'UNSUPPORTED_METHOD' }
    if ($text -match 'Is not archive|Cannot open the file as archive') { return 'NOT_ARCHIVE' }
    return 'UNKNOWN'
}

function Get-GfRedactedArgv {
    <# 日志脱敏：-p 后面的东西一律打码。**Argv 绝不整体写日志**（§9.1）。 #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Argv)
    return @($Argv | ForEach-Object { if ($_ -like '-p*') { '-p***' } else { $_ } })
}
