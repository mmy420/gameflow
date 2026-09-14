<#
    scripts\lib\Paths.ps1 的测试（SPEC §3.2A、§2.5、I6）

    纯字符串/纯路径处理，**在 macOS 与 Windows 上应当给出完全相同的结果**。
    唯一的平台差异是 Test-GfPathWithin 的分隔符，测试里按平台取。
#>
. "$PSScriptRoot\lib\GfTest.ps1"
. "$PSScriptRoot\..\scripts\lib\Paths.ps1"

$ACP_GBK  = 936    # 简体中文
$ACP_SJIS = 932    # 日文
$ACP_UTF8 = 65001  # Beta UTF-8
$ACP_1252 = 1252   # 西欧 —— 仅用于复现 SPEC §3.2A.4 的逐字范例，见下方说明

# ── 规范化链 N1–N7 ───────────────────────────────────────────────────────────

Test-Case 'N1 NFC：NFD 分解形的「ガ」归一成单码点' {
    $nfd = "$([char]0x30AB)$([char]0x3099)"        # カ + 浊点 = 2 码元
    Assert-Equal 2 $nfd.Length '前提：输入确实是分解形'
    $r = Get-GfNormalizedName -Title $nfd
    Assert-Equal 1 $r.Length 'NFC 后应合成单码点 ガ'
    Assert-Equal ([string][char]0x30AC) $r
}

Test-Case 'N2 九个非法字符全部换成全角同形字' {
    $r = Get-GfNormalizedName -Title 'a\b/c:d*e?f"g<h>i|j'
    Assert-Equal "a$([char]0xFF3C)b$([char]0xFF0F)c$([char]0xFF1A)d$([char]0xFF0A)e$([char]0xFF1F)f$([char]0xFF02)g$([char]0xFF1C)h$([char]0xFF1E)i$([char]0xFF5C)j" $r
}

Test-Case 'N2 只换那九个，其它符号一律不动（保可读性）' {
    $r = Get-GfNormalizedName -Title "Fate(stay night)[Realta Nua]#1&2"
    Assert-Equal 'Fate(stay night)[Realta Nua]#1&2' $r
}

Test-Case 'N3 C0 控制字符被删除而不是替换' {
    $r = Get-GfNormalizedName -Title "ab$([char]0x01)cd$([char]0x1F)ef"
    Assert-Equal 'abcdef' $r
}

Test-Case 'N4 折叠 TAB/NBSP/全角空格 的连续段并 Trim' {
    $t = " a$([char]0x09)$([char]0x09)b$([char]0x00A0)c$([char]0x3000)$([char]0x3000)d "
    Assert-Equal 'a b c d' (Get-GfNormalizedName -Title $t)
}

Test-Case 'N5 去掉尾部的点与空格（Windows 会静默吃掉它们）' {
    Assert-Equal 'Game' (Get-GfNormalizedName -Title 'Game. . ..  ')
}

Test-Case 'N6 保留设备名：NUL.txt 命中（比对的是第一个点之前的 stem）' {
    Assert-Equal '_NUL.txt' (Get-GfNormalizedName -Title 'NUL.txt')
}

Test-Case 'N6 保留设备名大小写不敏感' {
    Assert-Equal '_con'  (Get-GfNormalizedName -Title 'con')
    Assert-Equal '_Com1' (Get-GfNormalizedName -Title 'Com1')
}

Test-Case 'N6 上标变体 COM¹ 也要命中' {
    $n = "COM$([char]0x00B9)"
    Assert-Equal "_$n" (Get-GfNormalizedName -Title $n)
}

Test-Case 'N6 不误伤：CONSOLE / NULL 不是设备名' {
    Assert-Equal 'CONSOLE' (Get-GfNormalizedName -Title 'CONSOLE')
    Assert-Equal 'NULL'    (Get-GfNormalizedName -Title 'NULL')
}

Test-Case 'N7 裁到 60 个 UTF-16 码元' {
    $r = Get-GfNormalizedName -Title ('x' * 100)
    Assert-Equal 60 $r.Length
}

Test-Case 'N7 不切断代理对（emoji 是 2 个码元）' {
    # 59 个 x + 一个 4 字节 emoji：加上去会到 61，必须整个丢掉而不是切一半
    $r = Get-GfNormalizedName -Title (('x' * 59) + "$([char]0xD83C)$([char]0xDF38)")
    Assert-Equal 59 $r.Length '应退到字素簇边界'
    Assert-False ([char]::IsSurrogate($r[$r.Length - 1])) '末尾不得是孤立代理项'
}

Test-Case 'N7 之后重跑 N5：裁剪暴露出的尾部空格要去掉' {
    # 第 60 个字符是空格，裁完必须再 Trim 一次
    $r = Get-GfNormalizedName -Title (('y' * 59) + ' ' + ('z' * 20))
    Assert-Equal 59 $r.Length
    Assert-Equal 'y' $r[$r.Length - 1]
}

# ── ACP 往返（§3.2A.3）──────────────────────────────────────────────────────

Test-Case 'ACP 往返：CodePagesEncodingProvider 已注册（.NET Core 上必需）' {
    $enc = [System.Text.Encoding]::GetEncoding($ACP_GBK)
    Assert-Equal 936 $enc.CodePage 'GetEncoding(936) 必须可用，否则整个降级判定失真'
}

Test-Case 'ACP 往返：ASCII 在任何代码页下都可表示' {
    Assert-True (Test-GfAcpRoundTrip -Text 'NEKOPARA Vol.1' -Acp $ACP_GBK)
    Assert-True (Test-GfAcpRoundTrip -Text 'NEKOPARA Vol.1' -Acp $ACP_SJIS)
}

Test-Case 'ACP 往返：简体专用字在 936 可表示、在 932 不可' {
    # 注意选字：'某不知名网友分享' 里的汉字**在 932 里也几乎都有**（JIS X 0208
    # 收了大量汉字），所以它不是好用例。要挑简体专用字形。
    Assert-True  (Test-GfAcpRoundTrip -Text '网关说这' -Acp $ACP_GBK)
    Assert-False (Test-GfAcpRoundTrip -Text '网关说这' -Acp $ACP_SJIS)
}

Test-Case 'ACP 往返：假名在 932 **与 936** 都可表示（实证，与直觉相反）' {
    # GBK 收了完整的平假名/片假名区。后果：**在中文 Windows 上，
    # 日文假名标题根本不会触发降级** —— 降级比 SPEC 原先暗示的罕见得多。
    Assert-True (Test-GfAcpRoundTrip -Text 'ねこぱら' -Acp $ACP_SJIS)
    Assert-True (Test-GfAcpRoundTrip -Text 'ネコぱら' -Acp $ACP_GBK) '实测：936 含假名'
}

Test-Case 'ACP 往返：韩文与 emoji 在 936/932 都不可表示' {
    # 这些才是 936 上真正会触发降级的东西
    Assert-False (Test-GfAcpRoundTrip -Text '한국어' -Acp $ACP_GBK)
    Assert-False (Test-GfAcpRoundTrip -Text '한국어' -Acp $ACP_SJIS)
    Assert-False (Test-GfAcpRoundTrip -Text "$([char]0xD83C)$([char]0xDF38)" -Acp $ACP_GBK)
}

Test-Case 'ACP 往返：65001 下什么都可表示' {
    Assert-True (Test-GfAcpRoundTrip -Text 'ねこぱら某游戏' -Acp $ACP_UTF8)
}

Test-Case 'ACP 往返：必须用 ExceptionFallback —— 不可表示不得被静默替换成 ?' {
    # 这是本条最关键的反向判据：默认 fallback 会把不可表示的字符换成 '?'，
    # 往返「成功」但字符已被改掉，于是该降级的没降级，建出来的目录名是错的。
    $bad = "$([char]0x00E9)$([char]0x4E2D)"        # é + 中
    Assert-False (Test-GfAcpRoundTrip -Text $bad -Acp 437) 'CP437 表示不了它们，必须判 false'
}

# ── 完整 dirname（§3.2A）────────────────────────────────────────────────────

Test-Case 'dirname 正常路径：可表示、预算够、不冲突 → 原样保留' {
    $r = Get-GfDirName -Title 'NEKOPARA Vol.1' -Seq4 '0042' -Acp $ACP_GBK -BudgetE 100
    Assert-Equal 'NEKOPARA Vol.1' $r.dirname
    Assert-False $r.degraded
    Assert-Equal $null $r.reason
}

Test-Case 'dirname 中文标题在 936 下保留（不该无谓降级）' {
    $r = Get-GfDirName -Title '某游戏 第一章' -Seq4 '0001' -Acp $ACP_GBK -BudgetE 100
    Assert-Equal '某游戏 第一章' $r.dirname
    Assert-False $r.degraded
}

Test-Case 'dirname 假名标题在 936 下**不**降级（实证修正）' {
    # SPEC §3.2A.4 原先的范例暗示假名会降级，实测在 936 上不会。
    $r = Get-GfDirName -Title 'ネコぱら Vol.1' -Seq4 '0042' -Acp $ACP_GBK -BudgetE 100
    Assert-False $r.degraded '936 含假名，不该降级'
    Assert-Equal 'ネコぱら Vol.1' $r.dirname
}

Test-Case 'dirname ACP 表示不了时降级（用 1252 复现 SPEC §3.2A.4 范例）' {
    # 用 1252 而不是 936：这里要验的是**算法**，需要一个确实表示不了假名的 ACP。
    $r = Get-GfDirName -Title 'ネコぱら Vol.1' -Seq4 '0042' -Acp $ACP_1252 -BudgetE 100
    Assert-True $r.degraded
    Assert-Equal 'acp_unrepresentable' $r.reason
    Assert-Equal 'g0042-vol-1' $r.dirname 'SPEC §3.2A.4 的逐字范例'
}

Test-Case 'dirname 韩文标题在 936 下降级（936 上真实会发生的情形）' {
    $r = Get-GfDirName -Title '한국어 Game 2' -Seq4 '0099' -Acp $ACP_GBK -BudgetE 100
    Assert-True $r.degraded
    Assert-Equal 'acp_unrepresentable' $r.reason
    Assert-Equal 'g0099-game-2' $r.dirname
}

Test-Case 'dirname 降级 slug：纯 ASCII 标题（SPEC 范例）' {
    # 用一个 ACP 表示不了的方式强制降级：CP437 表示不了全角字符
    $r = Get-GfDirName -Title 'NEKOPARA Vol.1' -Seq4 '0042' -Acp $ACP_GBK -BudgetE 400
    Assert-True $r.degraded 'BudgetE=400 必然超预算'
    Assert-Equal 'path_budget' $r.reason
    Assert-Equal 'g0042-nekopara-vol-1' $r.dirname 'SPEC §3.2A.4 的逐字范例'
}

Test-Case 'dirname 降级 slug：无 ASCII 可留 → h + SHA-1 前 8 位' {
    $r = Get-GfDirName -Title 'ネコぱら' -Seq4 '0042' -Acp $ACP_1252 -BudgetE 100
    Assert-True $r.degraded
    Assert-Match '^g0042-h[0-9a-f]{8}$' $r.dirname 'SPEC §3.2A.4 的形状'
}

Test-Case 'dirname 降级 slug 对同一标题稳定（哈希不能每次变）' {
    $a = Get-GfDirName -Title 'ネコぱら' -Seq4 '0042' -Acp $ACP_1252 -BudgetE 100
    $b = Get-GfDirName -Title 'ネコぱら' -Seq4 '0042' -Acp $ACP_1252 -BudgetE 100
    Assert-Equal $a.dirname $b.dirname '同输入必须同输出，否则重跑会建出第二个目录'
}

Test-Case 'dirname 空串兜底' {
    $r = Get-GfDirName -Title "   $([char]0x01)  ... " -Seq4 '0007' -Acp $ACP_GBK
    Assert-Equal 'g0007' $r.dirname
    Assert-True $r.degraded
    Assert-Equal 'empty_after_normalize' $r.reason
}

Test-Case 'dirname 去重：大小写不敏感（NTFS 语义）' {
    $r = Get-GfDirName -Title 'Game' -Seq4 '0003' -Acp $ACP_GBK -BudgetE 100 -LibIndex @('GAME')
    Assert-True $r.degraded
    Assert-Equal 'collision' $r.reason
    Assert-Match '^Game-[0-9a-f]{8}$' $r.dirname
}

Test-Case 'dirname 去重：不冲突时不加哈希' {
    $r = Get-GfDirName -Title 'Game' -Seq4 '0003' -Acp $ACP_GBK -BudgetE 100 -LibIndex @('OtherGame')
    Assert-Equal 'Game' $r.dirname
    Assert-False $r.degraded
}

Test-Case 'dirname 降级 slug 再撞 → 抛异常，不自动改名（§3.2A.4）' {
    Assert-Throws {
        Get-GfDirName -Title 'ネコぱら Vol.1' -Seq4 '0042' -Acp $ACP_1252 -BudgetE 100 `
                      -LibIndex @('g0042-vol-1')
    }
}

Test-Case 'dirname 降级原因必须被记录（事后要能回答「为什么是一串字母」）' {
    $r = Get-GfDirName -Title 'ネコぱら' -Seq4 '0042' -Acp $ACP_1252 -BudgetE 100
    Assert-Equal $ACP_1252 $r.acp_at_decision
    Assert-Equal 'ネコぱら' $r.normalized_candidate '规范化候选要留痕'
}

# ── 路径预算（§2.5）─────────────────────────────────────────────────────────

Test-Case '预算闸门：17 + 60 + 1 + 170 = 248 恰好放得下' {
    Assert-True (Test-GfPathBudget -DirName ('x' * 60) -BudgetE 170 -PrefixLen 17)
}

Test-Case '预算闸门：再多一个字符就放不下' {
    Assert-False (Test-GfPathBudget -DirName ('x' * 60) -BudgetE 171 -PrefixLen 17)
}

Test-Case '预算闸门：按月分组的前缀 27 会少 10 个字符' {
    # E:\wen\games\hgames\202609\ = 27，比设计基准 17 少 10（SPEC §2.5.3a）
    Assert-True  (Test-GfPathBudget -DirName ('x' * 60) -BudgetE 160 -PrefixLen 27)
    Assert-False (Test-GfPathBudget -DirName ('x' * 60) -BudgetE 161 -PrefixLen 27)
}

# ── I6 路径围栏 ──────────────────────────────────────────────────────────────

$sep  = [System.IO.Path]::DirectorySeparatorChar
$hub  = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'D:\GameHub' } else { '/tmp/GameHub' }
$in   = $hub + $sep + 'games' + $sep + 'x'
$out  = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'D:\Other\x' } else { '/tmp/Other/x' }

Test-Case 'I6 围栏：枢纽内 → true' { Assert-True  (Test-GfPathWithin -Path $in  -Ancestor $hub) }
Test-Case 'I6 围栏：枢纽外 → false' { Assert-False (Test-GfPathWithin -Path $out -Ancestor $hub) }
Test-Case 'I6 围栏：等于枢纽根本身 → true（是否允许删由调用方管）' {
    Assert-True (Test-GfPathWithin -Path $hub -Ancestor $hub)
}
Test-Case 'I6 围栏：前缀相同但不是子目录 → false（最经典的漏判）' {
    Assert-False (Test-GfPathWithin -Path ($hub + 'Evil') -Ancestor $hub) `
        '「D:\GameHubEvil」不在「D:\GameHub」之内，纯字符串 StartsWith 会漏判'
}
Test-Case 'I6 围栏：.. 穿越被规范化后挡住' {
    Assert-False (Test-GfPathWithin -Path ($hub + $sep + '..' + $sep + 'Other') -Ancestor $hub)
}
Test-Case 'I6 围栏：大小写不敏感' {
    Assert-True (Test-GfPathWithin -Path $in.ToUpperInvariant() -Ancestor $hub)
}
Test-Case 'I6 围栏：空串一律 false' {
    Assert-False (Test-GfPathWithin -Path '' -Ancestor $hub)
    Assert-False (Test-GfPathWithin -Path $in -Ancestor '')
}

exit (Invoke-GfTestSummary -Title 'Paths.ps1')
