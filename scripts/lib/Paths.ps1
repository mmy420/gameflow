<#
    GameFlow · Paths.ps1

    dirname 生成算法（SPEC §3.2A，全 SPEC 唯一权威）
    MAX_PATH 预算断言（§2.5）
    I6 路径围栏（§1.2.2）

    这三样共同的特点：**写错了是静默的**。
    dirname 算错 → 目录建出来但查不到；预算算错 → 解压到一半才炸；
    围栏算错 → 删到枢纽外面去。所以每一条都有对应测试。

    本文件是纯字符串/纯路径处理，不碰文件系统（除了 Test-GfPathWithin 可选的
    reparse 检查），因此**可以在 macOS 上完整测试**。
#>

# .NET Core（pwsh 6+）默认只带 Unicode 系列编码，GetEncoding(936/932) 会抛
# NotSupportedException。.NET Framework（Windows PowerShell 5.1）自带全套。
# 这里无条件注册，5.1 上是 no-op，7.x 上是必需的。
if (-not ([System.Text.Encoding]::GetEncodings() | Where-Object { $_.CodePage -eq 936 })) {
    try {
        [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
    } catch {
        # 5.1 上 CodePagesEncodingProvider 不存在，也不需要 —— 忽略
    }
}

# SPEC §3.2A.2：Win32 保留字符全集，逐字写死，不多不少
$script:GfIllegalMap = @{
    [char]0x005C = [char]0xFF3C   # \  →  ＼
    [char]0x002F = [char]0xFF0F   # /  →  ／
    [char]0x003A = [char]0xFF1A   # :  →  ：
    [char]0x002A = [char]0xFF0A   # *  →  ＊
    [char]0x003F = [char]0xFF1F   # ?  →  ？
    [char]0x0022 = [char]0xFF02   # "  →  ＂
    [char]0x003C = [char]0xFF1C   # <  →  ＜
    [char]0x003E = [char]0xFF1E   # >  →  ＞
    [char]0x007C = [char]0xFF5C   # |  →  ｜
}

# SPEC §3.2A.1 N6：保留设备名 + 上标变体。全部大写存放，比对时大写化。
$script:GfDeviceNames = @(
    'CON','PRN','AUX','NUL','CONIN$','CONOUT$'
) + (1..9 | ForEach-Object { "COM$_" }) + (1..9 | ForEach-Object { "LPT$_" }) + @(
    # COM¹ COM² COM³ / LPT¹ LPT² LPT³ —— U+00B9 U+00B2 U+00B3
    "COM$([char]0x00B9)", "COM$([char]0x00B2)", "COM$([char]0x00B3)",
    "LPT$([char]0x00B9)", "LPT$([char]0x00B2)", "LPT$([char]0x00B3)"
)

function Get-GfSha1Hex {
    <# SHA-1 的前 N 位十六进制小写。此处**只作短标识，不作安全用途**（§3.2A.1 N8）。 #>
    param([Parameter(Mandatory)][string]$Text, [int]$Length = 8)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash  = $sha.ComputeHash($bytes)
        return (([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()).Substring(0, $Length)
    } finally { $sha.Dispose() }
}

function Get-GfGraphemeTruncated {
    <#
        裁到至多 $Max 个 UTF-16 码元，但**不切断字素簇**（§3.2A.1 N7）。
        代理对（emoji）与组合序列（か + 浊点）都算一个簇，切一半会产生
        不可显示的孤立码元，某些 API 还会直接报错。
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [int]$Max)
    if ($Text.Length -le $Max) { return $Text }
    $sb = New-Object System.Text.StringBuilder
    $e  = [System.Globalization.StringInfo]::GetTextElementEnumerator($Text)
    while ($e.MoveNext()) {
        $el = [string]$e.Current
        if ($sb.Length + $el.Length -gt $Max) { break }
        [void]$sb.Append($el)
    }
    return $sb.ToString()
}

function Remove-GfTrailingDotSpace {
    <# N5：循环去掉尾部的 '.' 与 ' '。Windows 会静默吃掉它们 → 建的名字 ≠ 查的名字。 #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $s = $Text
    while ($s.Length -gt 0) {
        $last = $s[$s.Length - 1]
        if ($last -eq '.' -or $last -eq ' ') { $s = $s.Substring(0, $s.Length - 1) } else { break }
    }
    return $s
}

function Get-GfNormalizedName {
    <#
        SPEC §3.2A.1 的规范化链 N1–N7（N8 去重与 N9 兜底由 Get-GfDirName 处理）。
        **九条的顺序不可换**：N5 必须在 N4 之后（折叠空白可能暴露新的尾部空格），
        N7 之后必须**重跑 N5**（裁剪可能切出新的尾部点或空格）。
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Title, [int]$MaxLength = 60)

    # N1 NFC —— 网页抓来的日文常是 NFD 分解形，建目录与查目录必须同形
    $s = $Title.Normalize([System.Text.NormalizationForm]::FormC)

    # N2 非法字符 → 全角同形字（只换这九个，其余一律不动，保可读性）
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if ($script:GfIllegalMap.ContainsKey($ch)) { [void]$sb.Append($script:GfIllegalMap[$ch]) }
        else { [void]$sb.Append($ch) }
    }
    $s = $sb.ToString()

    # N3 删除 C0 控制字符，**但保留 TAB/LF/CR** 交给 N4 折叠。
    # 原 SPEC 的 N3 删 U+0000..U+001F 全段，而 N4 又说要折叠 U+0009 ——
    # 两条互相矛盾，TAB 永远活不到 N4。实测暴露：'a<TAB>b' 会变成 'ab' 而不是 'a b'。
    # 语义上 TAB/换行是词分隔符，该折成空格而不是让两个词粘在一起。
    $s = -join ($s.ToCharArray() | Where-Object {
            $c = [int]$_
            ($c -gt 0x1F) -or ($c -eq 0x09) -or ($c -eq 0x0A) -or ($c -eq 0x0D)
        })

    # N4 折叠空白：TAB/LF/CR / SPACE / NBSP / 全角空格 的连续段 → 单个半角空格，再 Trim
    $s = [regex]::Replace($s, "[\u0009\u000A\u000D\u0020\u00A0\u3000]+", ' ').Trim()

    # N5 去尾部点与空格
    $s = Remove-GfTrailingDotSpace $s

    # N6 保留设备名防御：取第一个 '.' 之前的 stem 比对（所以 NUL.txt 也会命中）
    if ($s.Length -gt 0) {
        $dot  = $s.IndexOf('.')
        $stem = if ($dot -ge 0) { $s.Substring(0, $dot) } else { $s }
        if ($script:GfDeviceNames -contains $stem.ToUpperInvariant()) { $s = '_' + $s }
    }

    # N7 裁到 MaxLength 个 UTF-16 码元，不切断字素簇；然后**重跑 N5**
    $s = Get-GfGraphemeTruncated -Text $s -Max $MaxLength
    $s = Remove-GfTrailingDotSpace $s

    return $s
}

function Test-GfAcpRoundTrip {
    <#
        SPEC §3.2A.3：ACP strict 往返。
        **必须用 ExceptionFallback 这一对** —— GetEncoding(int) 的默认 fallback 是
        「替换」，不可表示的字符会悄悄变成 '?'，往返会「成功」而字符已被改掉，
        那正是我们要检出的情况。
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][int]$Acp)
    if ($Text.Length -eq 0) { return $true }
    try {
        $enc = [System.Text.Encoding]::GetEncoding(
                   $Acp,
                   [System.Text.EncoderExceptionFallback]::new(),
                   [System.Text.DecoderExceptionFallback]::new())
    } catch {
        # 取不到该代码页（.NET Core 未注册 provider，或 ACP 本身无效）
        # → 判为不可表示，走降级。保守，但不会产生建不出来的目录。
        return $false
    }
    try {
        $rt = $enc.GetString($enc.GetBytes($Text))
        return [string]::Equals($rt, $Text, [System.StringComparison]::Ordinal)
    } catch {
        return $false        # EncoderFallbackException / DecoderFallbackException
    }
}

function Get-GfAsciiSlugTail {
    <#
        SPEC §3.2A.4 降级 slug 的 tail：
        [A-Za-z0-9] 段保留、其余折成单个 '-'、小写、去首尾 '-'、裁到 24。
        **不做假名/汉字 → 罗马字的转写** —— 那需要词典且会猜错读音，与「不猜」冲突。
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [int]$Max = 24)
    $t = [regex]::Replace($Text, '[^A-Za-z0-9]+', '-').Trim('-').ToLowerInvariant()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max).Trim('-') }
    return $t
}

function Get-GfDirName {
    <#
    .SYNOPSIS
        SPEC §3.2A 的完整实现：title → dirname + 降级记录。
    .PARAMETER Title      人填的真实标题
    .PARAMETER Seq4       item.id 里的 4 位序号（降级 slug 与空串兜底要用）
    .PARAMETER Acp        系统 ANSI 代码页（Preflight 的 PF-08）
    .PARAMETER BudgetE    归档内部最长相对路径（§2.5 的 E）
    .PARAMETER PrefixLen  落地前缀字符数，默认 17 = "D:\GameHub\games\"
    .PARAMETER LibIndex   库内已存在的 dirname 集合，用于去重
    .OUTPUTS
        [ordered]@{ dirname; degraded; reason; acp_at_decision; normalized_candidate }
        reason ∈ null | acp_unrepresentable | path_budget | collision | empty_after_normalize
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Title,
        [Parameter(Mandatory)][string]$Seq4,
        [Parameter(Mandatory)][int]$Acp,
        [int]$BudgetE = 0,
        [int]$PrefixLen = 17,
        [string[]]$LibIndex = @()
    )

    $upperIndex = @{}
    foreach ($x in $LibIndex) { $upperIndex[$x.ToUpperInvariant()] = $true }
    function Test-Taken { param([string]$N) return $upperIndex.ContainsKey($N.ToUpperInvariant()) }

    $result = [ordered]@{
        dirname              = $null
        degraded             = $false
        reason               = $null
        acp_at_decision      = $Acp
        normalized_candidate = $null
    }

    # ── N1–N7 ────────────────────────────────────────────────────────────────
    $nfc  = $Title.Normalize([System.Text.NormalizationForm]::FormC)
    $cand = Get-GfNormalizedName -Title $Title
    $result.normalized_candidate = $cand

    # ── N9 空串兜底 ──────────────────────────────────────────────────────────
    if ($cand.Length -eq 0) {
        $result.dirname  = "g$Seq4"
        $result.degraded = $true
        $result.reason   = 'empty_after_normalize'
        return $result
    }

    # ── 降级判定：ACP 往返 → 路径预算 ────────────────────────────────────────
    $degradeReason = $null
    if (-not (Test-GfAcpRoundTrip -Text $cand -Acp $Acp)) {
        $degradeReason = 'acp_unrepresentable'
    } elseif (($PrefixLen + $cand.Length + 1 + $BudgetE) -gt 248) {
        # 248 = MAX_PATH − 12，建目录的实际上限，不是 260（§2.5）
        $degradeReason = 'path_budget'
    }

    if (-not $degradeReason) {
        # ── N8 去重：大小写不敏感（NTFS 语义）──────────────────────────────
        if (-not (Test-Taken $cand)) {
            $result.dirname = $cand
            return $result
        }
        $body = Get-GfGraphemeTruncated -Text $cand -Max 51
        $body = Remove-GfTrailingDotSpace $body
        $withHash = "$body-$(Get-GfSha1Hex -Text $nfc)"
        if (-not (Test-Taken $withHash)) {
            $result.dirname  = $withHash
            $result.degraded = $true
            $result.reason   = 'collision'
            return $result
        }
        # 加了哈希还撞 —— 不自动改名，交给调用方报错退出（§3.2A.4）
        throw "dirname 冲突且加 SHA-1 短哈希后仍冲突：$withHash。请人工指定标题或目录名。"
    }

    # ── 降级 slug ────────────────────────────────────────────────────────────
    $tail = Get-GfAsciiSlugTail -Text $nfc
    if ($tail.Length -eq 0) { $tail = 'h' + (Get-GfSha1Hex -Text $nfc) }
    $slug = "g$Seq4-$tail"

    if (Test-Taken $slug) {
        throw "降级 slug 冲突：$slug。§3.2A.4 规定此时不自动改名，请人工处理。"
    }
    $result.dirname  = $slug
    $result.degraded = $true
    $result.reason   = $degradeReason
    return $result
}

function Test-GfPathWithin {
    <#
    .SYNOPSIS
        不变量 I6 的路径围栏：$Path 是否位于 $Ancestor 之内。
    .DESCRIPTION
        规范化全路径 + 大小写不敏感前缀比对。**不跟随 reparse point**：
        调用方必须先用 -RejectReparse 或自行拒绝含 reparse 的路径，
        否则一个 junction 就能把「枢纽内」指到枢纽外（§6.6）。

        注意 $Path 与 $Ancestor 相等时返回 $true —— 删除枢纽根自身
        由调用方另行禁止，这里只回答「在不在里面」。
    #>
    param(
        # AllowEmptyString：围栏必须能对空串给出 $false 而不是抛绑定异常 ——
        # 调用方传进来的可能就是一个没算出来的路径，那正是最该挡住的情况。
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Ancestor
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Ancestor)) { return $false }
    try {
        $p = [System.IO.Path]::GetFullPath($Path)
        $a = [System.IO.Path]::GetFullPath($Ancestor)
    } catch { return $false }

    $sep = [System.IO.Path]::DirectorySeparatorChar
    $p = $p.TrimEnd($sep)
    $a = $a.TrimEnd($sep)
    if ($p.Equals($a, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $p.StartsWith($a + $sep, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-GfPathBudget {
    <#
        §2.5 的预算闸门。返回 $true = 放得下。
        prefix + dirname + 分隔符 + 内部最长相对路径 ≤ 248
    #>
    param(
        [Parameter(Mandatory)][string]$DirName,
        [int]$BudgetE = 0,
        [int]$PrefixLen = 17,
        [int]$Ceiling = 248
    )
    return (($PrefixLen + $DirName.Length + 1 + $BudgetE) -le $Ceiling)
}
