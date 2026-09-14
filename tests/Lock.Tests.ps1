<#
    scripts\lib\Lock.ps1 的测试（SPEC §8.8.6）

    ⚠️ **这是全项目最不可能在 macOS 上验证的一块。**
    Unix 上 .NET 的 FileShare 与 Windows 的强制锁语义不同。这里只覆盖
    「拿到/没拿到」的 API 契约与释放语义；**真正的跨进程互斥必须在 Windows 上验**
    （§11：计划任务会话 vs Codex 交互会话）。
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

if ([System.IO.Directory]::Exists($script:Root)) { [System.IO.Directory]::Delete($script:Root, $true) }
exit (Invoke-GfTestSummary -Title 'Lock.ps1')
