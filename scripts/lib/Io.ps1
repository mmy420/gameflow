<#
    GameFlow · Io.ps1 —— 文件读写与落盘协议（SPEC §8.8.2、§3.9）

    本项目最容易造成真实数据损坏的一条就在这里。5.1 的三个默认值全是错的：
      Out-File / > / >>      → UTF-16LE（不是 UTF-8）
      -Encoding utf8         → UTF-8 **带 BOM**
      Get-Content 读无 BOM   → 按系统 ANSI 解码 → 中文游戏名变乱码

    所以本模块**不使用**任何 PowerShell 的文件 cmdlet，一律走 .NET API 并显式给编码。

    注意与源码文件的区别（§8.8.2）：
      源码 .ps1  → UTF-8 **带** BOM（给 5.1 的解析器看）
      数据文件   → UTF-8 **无** BOM（本模块负责的就是这一类）
#>

# 无 BOM 的 UTF-8 编码器。每次 new 一个太浪费，且它是不可变的，做成脚本级单例。
$script:GfUtf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-GfUtf8NoBom { return $script:GfUtf8NoBom }

function Read-GfText {
    <# 显式 UTF-8 读。文件不存在返回 $null（不抛）—— 调用方普遍需要区分「没有」与「读坏了」。#>
    param([Parameter(Mandatory)][string]$LiteralPath)
    if (-not [System.IO.File]::Exists($LiteralPath)) { return $null }
    return [System.IO.File]::ReadAllText($LiteralPath, $script:GfUtf8NoBom)
}

function Write-GfText {
    <# 显式 UTF-8 无 BOM 写。目录不存在则建。**不做原子替换**，那是 Write-GfTextAtomic 的事。#>
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $dir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($LiteralPath))
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    [System.IO.File]::WriteAllText($LiteralPath, $Text, $script:GfUtf8NoBom)
}

function Write-GfTextAtomic {
    <#
    .SYNOPSIS
        写临时文件 → 替换目标，**保留 .bak**（SPEC §3.9.2）。
    .DESCRIPTION
        措辞上必须说「可恢复」而不是「原子」：ReplaceFile 官方文档自称只是
        「把几步合进一个函数」并列举了三种部分失败中间态，MoveFileEx 的 Remarks
        全文没有 atomic 字样。真正的崩溃安全来自 I2（events.jsonl 是唯一真相、
        state.json 只是可重建的派生快照），不是来自单次替换的原子性。

        **保留 .bak 不是为了数据冗余，是为了恢复判据的确定性**：ReplaceFile 的
        三种失败态里「有备份」与「无备份」的残留文件命名完全不同，保留之后
        崩溃现场是可判读的。所以绝不给 destinationBackupFileName 传 $null。

        跨卷会抛异常 —— 调用方必须保证 .tmp 与目标同目录（本函数已保证）。
    #>
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $full = [System.IO.Path]::GetFullPath($LiteralPath)
    $dir  = [System.IO.Path]::GetDirectoryName($full)
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }

    $tmp = "$full.tmp-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
    $bak = "$full.bak"
    [System.IO.File]::WriteAllText($tmp, $Text, $script:GfUtf8NoBom)

    if ([System.IO.File]::Exists($full)) {
        [System.IO.File]::Replace($tmp, $full, $bak)     # 保留 .bak
    } else {
        [System.IO.File]::Move($tmp, $full)              # 首次创建，无可替换
    }
}

function Test-GfFileEndsWithLf {
    <# events.jsonl 的封口判定（§3.3.4 第 2 步）：文件非空且最后一字节不是 0x0A = 上次崩溃留了半行。#>
    param([Parameter(Mandatory)][string]$LiteralPath)
    if (-not [System.IO.File]::Exists($LiteralPath)) { return $true }   # 不存在视为「已封口」
    $fs = [System.IO.File]::Open($LiteralPath, [System.IO.FileMode]::Open,
                                 [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        if ($fs.Length -eq 0) { return $true }
        [void]$fs.Seek(-1, [System.IO.SeekOrigin]::End)
        return ($fs.ReadByte() -eq 0x0A)
    } finally { $fs.Dispose() }
}
