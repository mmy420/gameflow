<#
    scripts\lib\SevenZip.ps1 的测试（SPEC §6.2）

    ⚠️ 外推边界：本机是 **macOS 上的 7-Zip 26.03**。
      · 退出码语义、-slt 输出形状、Files/Folders 摘要行 —— 在跨平台公共代码里，
        可外推到 Windows（SPEC §6.2 的【实测，可外推】标注）
      · 路径穿越的落地位置、SFX 的识别、RAR 解码 —— **不可外推**，见 §11
    纯解析器（ConvertFrom-GfSevenZipOutput）不依赖 7z，任何机器上都能测。
#>
. "$PSScriptRoot\lib\GfTest.ps1"
. "$PSScriptRoot\..\scripts\lib\SevenZip.ps1"

$script:Sz = $null
foreach ($n in @('7zz','7z','7za')) {
    $c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { $script:Sz = $c.Source; break }
}
$script:Lab = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'gfsz-' + [Guid]::NewGuid().ToString('N').Substring(0,8))

# ── 参数契约（不需要 7z）─────────────────────────────────────────────────────

Test-Case 'TypeSpec 白名单：具体类型名一律拒绝（T4）' {
    # 传 -tzip 给一个内容其实是 7z 的文件 → exit 2 硬失败。
    # 所以封装里硬拒，不靠调用方的纪律。
    foreach ($bad in @('7z','zip','rar','tcab','*:r')) {
        Assert-Throws { Invoke-SevenZip -Op l -Archive '/tmp/x' -TypeSpec $bad } "TypeSpec=$bad 应被拒"
    }
}

Test-Case 'TypeSpec 白名单：none / * / *:s16m / *:s64m / #:e 是全集' {
    Assert-Equal 5 (Get-GfTypeSpecWhitelist).Count
    Assert-True ((Get-GfTypeSpecWhitelist) -contains 'none') 'none = 不传 -t，走默认内容嗅探'
}

Test-Case 'Op=x 必须给 OutDir（绝不就地解压，T7）' {
    Assert-Throws { Invoke-SevenZip -Op x -Archive '/tmp/x' }
}

Test-Case 'Op≠x 给 OutDir 应拒绝' {
    Assert-Throws { Invoke-SevenZip -Op l -Archive '/tmp/x' -OutDir '/tmp/o' }
}

Test-Case '日志脱敏：-p 后面一律打码' {
    $r = Get-GfRedactedArgv -Argv @('t','-y','-p秘密密码','--','a.7z')
    Assert-True  ($r -contains '-p***')
    Assert-False ($r -contains '-p秘密密码') '密码绝不整体写日志（§9.1）'
}

# ── 解析器（纯函数，不需要 7z）──────────────────────────────────────────────

Test-Case '解析器：归档级块与条目级块分离' {
    $lines = @(
        'Listing archive: plain.7z','','--','Path = plain.7z','Type = 7z','Physical Size = 263',
        '----------','Path = src/a.txt','Size = 12','Attributes = A -rw-r--r--','',
        'Path = src/sub','Size = 0','Attributes = D drwxr-xr-x','')
    $p = ConvertFrom-GfSevenZipOutput -Lines $lines
    Assert-Equal '7z'  $p.ArchiveInfo['Type']
    Assert-Equal '263' $p.ArchiveInfo['Physical Size']
    Assert-Equal 2     $p.Entries.Count
    Assert-Equal 'src/a.txt' $p.Entries[0]['Path']
}

Test-Case '解析器：目录靠 Attributes 含 D 判定' {
    $dir  = [ordered]@{ Path='d'; Attributes='D drwxr-xr-x' }
    $file = [ordered]@{ Path='f'; Attributes='A -rw-r--r--' }
    Assert-True  (Test-GfSevenZipEntryIsDir -Entry $dir)
    Assert-False (Test-GfSevenZipEntryIsDir -Entry $file)
    Assert-Equal 1 (Get-GfSevenZipFileEntryCount -Entries @($dir,$file)) '目录不算进去，否则永远对不上 Files: N'
}

Test-Case '解析器：空值的键不丢（CRC = 与 Method = 都是空值）' {
    $p = ConvertFrom-GfSevenZipOutput -Lines @('--','Path = x','----------','Path = a','CRC =','Method =','')
    Assert-True $p.Entries[0].Contains('CRC')
    Assert-Equal '' $p.Entries[0]['CRC']
}

Test-Case '解析器：Files / Folders 摘要行' {
    $p = ConvertFrom-GfSevenZipOutput -Lines @('Everything is Ok','','Folders: 3','Files: 2','Size: 5012')
    Assert-Equal 2 $p.FilesReported
    Assert-Equal 3 $p.FoldersReported
}

Test-Case '解析器：Open WARNING 行被收集' {
    $p = ConvertFrom-GfSevenZipOutput -Lines @('Open WARNING: Cannot open the file as archive','Files: 1')
    Assert-Equal 1 $p.Warnings.Count
}

# ── SZ-3 成功判据 ───────────────────────────────────────────────────────────

function FakeResult { param($Exit=0,$Files=2,$Warn=@(),$Timeout=$false)
    [pscustomobject]@{ ExitCode=$Exit; TimedOut=$Timeout; FilesReported=$Files; Warnings=$Warn }
}

Test-Case 'SZ-3：exit 0 + 无警告 + Files 对得上 → 成功' {
    $v = Test-GfSevenZipSuccess -Result (FakeResult) -ExpectedFileEntries 2
    Assert-True $v.Ok
}

Test-Case 'SZ-3：**exit 1 一律当失败**（不是 -le 1）' {
    # exit 1 = 「完成了但有东西被静默跳过」。写成 -le 1 就是在部分解压失败时
    # 删掉唯一的源文件 —— 本项目最不可逆的一条数据丢失链。
    $v = Test-GfSevenZipSuccess -Result (FakeResult -Exit 1) -ExpectedFileEntries 2
    Assert-False $v.Ok
    Assert-True ($v.Failures -contains 'EXIT_NOT_ZERO:1')
}

Test-Case 'SZ-3：exit 0 但 Files: 0 → 失败（T1/T2/T3 的解药）' {
    $v = Test-GfSevenZipSuccess -Result (FakeResult -Files 0)
    Assert-False $v.Ok
    Assert-True ($v.Failures -contains 'ZERO_FILES')
}

Test-Case 'SZ-3：Files 与 l 列出的条目数不符 → 失败' {
    $v = Test-GfSevenZipSuccess -Result (FakeResult -Files 2) -ExpectedFileEntries 5
    Assert-False $v.Ok
    Assert-Match 'FILES_MISMATCH' ($v.Failures -join ';')
}

Test-Case 'SZ-3：exit 0 但有未知警告 → 失败（警告与退出码是两条独立信号）' {
    $v = Test-GfSevenZipSuccess -Result (FakeResult -Warn @('WARNING: weird')) -ExpectedFileEntries 2
    Assert-False $v.Ok
}

Test-Case 'SZ-3：白名单内的警告不算失败' {
    $v = Test-GfSevenZipSuccess -Result (FakeResult -Warn @('WARNING: benign thing')) `
                                -ExpectedFileEntries 2 -WarningWhitelist @('benign thing')
    Assert-True $v.Ok
}

Test-Case 'SZ-3：超时算失败' {
    Assert-False (Test-GfSevenZipSuccess -Result (FakeResult -Timeout $true) -ExpectedFileEntries 2).Ok
}

# ── exit 2 文案分流（§6.2.5）────────────────────────────────────────────────

Test-Case 'exit 2 分流：各文案映射到封闭代码' {
    Assert-Equal 'WRONG_PASSWORD'        (Get-GfSevenZipExit2Reason -Lines @('ERROR: Wrong password : a.txt'))
    Assert-Equal 'WRONG_PASSWORD_HEADER' (Get-GfSevenZipExit2Reason -Lines @('Cannot open encrypted archive. Wrong password?'))
    Assert-Equal 'CRC_FAILED'            (Get-GfSevenZipExit2Reason -Lines @('ERROR: CRC Failed : a.txt'))
    Assert-Equal 'UNEXPECTED_END'        (Get-GfSevenZipExit2Reason -Lines @('Unexpected end of archive'))
    Assert-Equal 'DANGEROUS_LINK'        (Get-GfSevenZipExit2Reason -Lines @('Dangerous link path was ignored : a : /etc'))
    Assert-Equal 'NOT_ARCHIVE'           (Get-GfSevenZipExit2Reason -Lines @('Cannot open the file as archive'))
    Assert-Equal 'UNKNOWN'               (Get-GfSevenZipExit2Reason -Lines @('something else'))
}

Test-Case 'exit 2 分流：DATA_ERROR_ENCRYPTED 是**模糊**的，不得自行消歧' {
    # 7z 的 AES-256 数据流没有密码校验值，7-Zip 自己也分不清密码错与密文损坏
    # —— 官方文案里那个问号就是在承认这一点。消歧规则在 §6.3，不在这里猜。
    Assert-Equal 'DATA_ERROR_ENCRYPTED' `
        (Get-GfSevenZipExit2Reason -Lines @('ERROR: Data Error in encrypted file. Wrong password? : a.txt'))
}

# ── 真 7z 集成（有 7z 才跑）─────────────────────────────────────────────────

if (-not $script:Sz) {
    Test-Case '⚠ 跳过真 7z 集成用例（本机无 7z）' { Assert-True $true }
} else {
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($script:Lab,'src','sub'))
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($script:Lab,'src','a.txt'), 'hello world')
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($script:Lab,'src','sub','b.txt'), ('x' * 5000))
    $plain = [System.IO.Path]::Combine($script:Lab,'plain.7z')
    & $script:Sz a -bso0 -bse0 $plain ([System.IO.Path]::Combine($script:Lab,'src')) | Out-Null

    Test-Case '真 7z：l -slt 能解析出归档级块与条目' {
        $r = Invoke-SevenZip -Op l -Archive $plain -SevenZipExe $script:Sz
        Assert-Equal 0 $r.ExitCode
        Assert-Equal '7z' $r.ArchiveInfo['Type']
        Assert-Equal 2 (Get-GfSevenZipFileEntryCount -Entries $r.Entries) '两个文件，目录不算'
    }

    Test-Case '真 7z：t 通过且 Files 与 l 的非目录条目数一致（SZ-3 第 3 条）' {
        $l = Invoke-SevenZip -Op l -Archive $plain -SevenZipExe $script:Sz
        $t = Invoke-SevenZip -Op t -Archive $plain -SevenZipExe $script:Sz
        $n = Get-GfSevenZipFileEntryCount -Entries $l.Entries
        Assert-Equal $n $t.FilesReported
        Assert-True (Test-GfSevenZipSuccess -Result $t -ExpectedFileEntries $n).Ok
    }

    Test-Case '真 7z：T1 —— 过滤器无匹配时 exit 0 但 Files: 0' {
        $r = Invoke-SevenZip -Op t -Archive $plain -Filter 'no-such.xyz' -SevenZipExe $script:Sz
        Assert-Equal 0 $r.ExitCode 'exit 居然是 0'
        Assert-False (Test-GfSevenZipSuccess -Result $r).Ok 'SZ-3 必须把它判成失败'
    }

    Test-Case '真 7z：T5 —— 对不加密的包传 -p 无害' {
        $r = Invoke-SevenZip -Op t -Archive $plain -Password '__sentinel__' -SevenZipExe $script:Sz
        Assert-Equal 0 $r.ExitCode '探测阶段可以统一传非空哨兵值'
    }

    Test-Case '真 7z：空密码时完全不传 -p（T5：裸 -p 会切进交互模式）' {
        $r = Invoke-SevenZip -Op t -Archive $plain -Password '' -SevenZipExe $script:Sz
        Assert-False (($r.Argv -join ' ') -match '(^| )-p') 'Argv 里不得出现 -p'
        Assert-Equal 0 $r.ExitCode
    }

    Test-Case '真 7z：x 解到指定目录，产物齐全' {
        $out = [System.IO.Path]::Combine($script:Lab,'out1')
        $r = Invoke-SevenZip -Op x -Archive $plain -OutDir $out -SevenZipExe $script:Sz
        Assert-Equal 0 $r.ExitCode
        Assert-Equal 2 $r.FilesReported
        Assert-True ([System.IO.File]::Exists([System.IO.Path]::Combine($out,'src','a.txt')))
    }

    Test-Case '真 7z：带密码的包 —— 密码对则通过' {
        $enc = [System.IO.Path]::Combine($script:Lab,'enc.7z')
        & $script:Sz a -bso0 -bse0 '-p正确密码' $enc ([System.IO.Path]::Combine($script:Lab,'src','a.txt')) | Out-Null
        $r = Invoke-SevenZip -Op t -Archive $enc -Password '正确密码' -SevenZipExe $script:Sz
        Assert-Equal 0 $r.ExitCode '中文密码往返正常'
    }

    Test-Case '真 7z：密码错 → exit 2，且文案可分流' {
        $enc = [System.IO.Path]::Combine($script:Lab,'enc.7z')
        $r = Invoke-SevenZip -Op t -Archive $enc -Password '错误密码' -SevenZipExe $script:Sz
        Assert-Equal 2 $r.ExitCode
        $reason = Get-GfSevenZipExit2Reason -Lines $r.Stdout
        Assert-True ($reason -in @('WRONG_PASSWORD','WRONG_PASSWORD_HEADER','DATA_ERROR_ENCRYPTED')) `
                    "应落在密码相关代码，实际 $reason"
    }

    Test-Case '真 7z：不是归档 → exit 2 + NOT_ARCHIVE' {
        $junk = [System.IO.Path]::Combine($script:Lab,'junk.bin')
        [System.IO.File]::WriteAllText($junk, 'not an archive at all')
        $r = Invoke-SevenZip -Op t -Archive $junk -SevenZipExe $script:Sz
        Assert-Equal 2 $r.ExitCode
        Assert-Equal 'NOT_ARCHIVE' (Get-GfSevenZipExit2Reason -Lines $r.Stdout)
    }

    Test-Case '真 7z：内容嗅探 —— 伪装成 .mp4 的 7z 不传 -t 也能打开（U2）' {
        $fake = [System.IO.Path]::Combine($script:Lab,'disguised.mp4')
        [System.IO.File]::Copy($plain, $fake, $true)
        $r = Invoke-SevenZip -Op l -Archive $fake -SevenZipExe $script:Sz
        Assert-Equal 0 $r.ExitCode '默认 -t*:r 会按内容嗅探，改后缀绝大多数情况根本不需要'
        Assert-Equal '7z' $r.ArchiveInfo['Type']
    }

    Test-Case '真 7z：超时会被 Kill 并标 TimedOut' {
        # 用 0 秒超时逼它必然超时（进程还没跑完就被杀）
        $r = Invoke-SevenZip -Op t -Archive $plain -TimeoutSec 0 -SevenZipExe $script:Sz
        Assert-True $r.TimedOut '超时必须可观测 —— 后台挂死一个无输出的进程是最难发现的故障'
    }
}

if ([System.IO.Directory]::Exists($script:Lab)) { [System.IO.Directory]::Delete($script:Lab, $true) }
exit (Invoke-GfTestSummary -Title 'SevenZip.ps1')
