<#
    scripts\lib\Lock.ps1 的测试（SPEC §8.8.6）

    平台边界（2026-09-29 实测修正）：.NET 在 Unix 上用 flock 实现 FileShare.None，
    **彼此都是 .NET 进程时跨进程互斥是生效的**，所以下面的跨进程用例在 macOS 上
    也能真跑。只能在 Windows 上验的是另两件事：
      · **强制锁**：Windows 连非 .NET 进程也会被挡，Unix 的 flock 是咨询性的
      · **跨会话**：计划任务会话 vs Codex / 人的交互会话（§11）
#>
. "$PSScriptRoot\lib\GfTest.ps1"
. "$PSScriptRoot\..\scripts\lib\Lock.ps1"

$script:Root = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'gflock-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
[void][System.IO.Directory]::CreateDirectory($script:Root)
function LockPath { return [System.IO.Path]::Combine($script:Root, [Guid]::NewGuid().ToString('N').Substring(0,6) + '.lock') }

Test-Case '锁路径：批次级与条目级的形状（§8.8.6）' {
    Assert-Match 'batches.2026-01-01-t\.lock$' (Get-GfBatchLockPath -HubRoot 'D:\GameHub' -BatchId '2026-01-01-t')
    Assert-Match '\.gameflow.\.lock$'          (Get-GfItemLockPath  -ItemDir 'D:\GameHub\games\x')
}

Test-Case '取锁成功后锁文件存在，且写了排查信息' {
    $p = LockPath
    $l = Open-GfLock -LiteralPath $p -RunId 'R1' -Note 'unit'
    try {
        Assert-True ($null -ne $l) '应当拿到锁'
        Assert-True ([System.IO.File]::Exists($p))
    } finally { Close-GfLock -Lock $l }
}

Test-Case '锁文件内容只供人排查，且明确写着不得用于判存活' {
    $p = LockPath
    $l = Open-GfLock -LiteralPath $p -RunId 'R9'
    Close-GfLock -Lock $l
    $txt = [System.IO.File]::ReadAllText($p)
    Assert-Match 'R9' $txt
    Assert-Match '判存活' $txt 'PID 会被复用，锁文件绝不能用于判存活'
}

Test-Case '释放后可以再次取到（没有陈旧锁问题）' {
    $p = LockPath
    $a = Open-GfLock -LiteralPath $p -RunId 'R1'
    Close-GfLock -Lock $a
    $b = Open-GfLock -LiteralPath $p -RunId 'R2'
    try { Assert-True ($null -ne $b) '句柄释放后锁必须立即可用 —— 这是选 FileShare.None 而不是 PID 检测的核心理由' }
    finally { Close-GfLock -Lock $b }
}

Test-Case 'Close-GfLock 接受 $null（调用方普遍在 finally 里无条件调）' {
    Close-GfLock -Lock $null
    Assert-True $true
}

Test-Case 'Invoke-GfWithLock：拿到锁则跑 Body 并返回结果' {
    $r = Invoke-GfWithLock -LiteralPath (LockPath) -RunId 'R1' -Body { 42 }
    Assert-True  $r.Acquired
    Assert-Equal 42 $r.Result
}

Test-Case 'Invoke-GfWithLock：Body 抛异常也要释放锁' {
    $p = LockPath
    try { [void](Invoke-GfWithLock -LiteralPath $p -Body { throw 'boom' }) } catch { }
    $again = Open-GfLock -LiteralPath $p
    try { Assert-True ($null -ne $again) '异常路径下也必须释放 —— 否则一次失败会永久卡住这个条目' }
    finally { Close-GfLock -Lock $again }
}

Test-Case 'Open-GfLock 对不可创建的路径返回 $null 而不抛' {
    # 抢锁失败的姿态：不区分 IOException 与 UnauthorizedAccessException，统一当「没拿到」
    $bad = [System.IO.Path]::Combine($script:Root, 'no-such-file.txt', 'nested', 'x.lock')
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($script:Root, 'no-such-file.txt'), 'x')
    Assert-Equal $null (Open-GfLock -LiteralPath $bad)
}

Test-Case '跨进程：另一个进程持锁时抢不到，放锁后立即可抢（§8.8.6 的核心）' {
    # 用当前宿主自己的可执行文件起子进程：Windows 上是 powershell.exe / pwsh.exe，
    # macOS 上是 pwsh。握手协议而不是「睡几秒赌它已拿到锁」—— 5.1 冷启动常超过 2 秒，
    # 赌输了会报出假 FAIL。
    $lp      = LockPath
    $flag    = "$lp.acquired"
    $release = "$lp.release"
    $lib     = (Resolve-Path "$PSScriptRoot\..\scripts\lib\Lock.ps1").Path
    $child   = [System.IO.Path]::Combine($script:Root, 'holder-' + [Guid]::NewGuid().ToString('N').Substring(0,6) + '.ps1')
    $src = @"
. '$lib'
`$l = Open-GfLock -LiteralPath '$lp' -RunId 'holder'
if (`$null -eq `$l) { exit 9 }
[System.IO.File]::WriteAllText('$flag', 'ok')
`$d = (Get-Date).AddSeconds(60)
while (-not (Test-Path -LiteralPath '$release') -and (Get-Date) -lt `$d) { Start-Sleep -Milliseconds 100 }
Close-GfLock -Lock `$l
exit 0
"@
    [System.IO.File]::WriteAllText($child, $src, (New-Object System.Text.UTF8Encoding($true)))
    $exe = (Get-Process -Id $PID).Path
    $sp  = @{ FilePath = $exe; ArgumentList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$child); PassThru = $true }
    if ($IsWindows -or $env:OS -eq 'Windows_NT') { $sp.WindowStyle = 'Hidden' }
    $proc = Start-Process @sp

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $flag) -and $sw.Elapsed.TotalSeconds -lt 45 -and -not $proc.HasExited) {
        Start-Sleep -Milliseconds 100
    }
    Assert-True (Test-Path -LiteralPath $flag) '持锁子进程必须先确认拿到锁，否则本用例什么也没测到'

    $mine = Open-GfLock -LiteralPath $lp -RunId 'contender'
    Assert-Equal $null $mine '另一个进程持锁时必须抢不到 —— 否则 A 与 B 会同时动同一个条目'
    Close-GfLock -Lock $mine

    [System.IO.File]::WriteAllText($release, 'go')
    [void]$proc.WaitForExit(20000)
    $after = Open-GfLock -LiteralPath $lp -RunId 'after'
    try { Assert-True ($null -ne $after) '持锁进程退出后锁必须立即可用 —— 没有陈旧锁' }
    finally { Close-GfLock -Lock $after }
}

if ([System.IO.Directory]::Exists($script:Root)) { [System.IO.Directory]::Delete($script:Root, $true) }
exit (Invoke-GfTestSummary -Title 'Lock.ps1')
