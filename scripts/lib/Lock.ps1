<#
    GameFlow · Lock.ps1 —— 互斥（SPEC §8.8.6）

    主机制是 FileShare.None 独占文件句柄。选它的四条理由：
      · 进程死亡时 OS 自动关句柄释放锁 —— **没有陈旧锁问题**
      · 句柄属于进程不属于线程 —— 没有命名 Mutex 的线程亲和性问题
      · 文件系统**没有会话隔离** —— 计划任务与 Codex 交互会话天然互斥
      · 5.1/7.x 行为一致、零依赖

    **绝不用 lock 文件 + PID 存活检测**：Windows 的 PID 复用很快，Get-Process -Id
    命中的可能是完全无关的新进程；而「超时清理陈旧锁」要引入时间猜测，与本项目
    的确定性偏好直接冲突。锁文件里写 {run_id, host, started_at} 只供人排查，
    **绝不用它判存活**。

    ⚠️ 本模块是全项目**最不可能在 macOS 上验证**的一块：Unix 上 .NET 的 FileShare
    是进程内咨询语义，跨进程互斥与 Windows 的强制锁不同。这里的测试只覆盖
    「同进程内重复抢锁失败」与「释放后可再抢」，**真正的跨进程互斥必须在
    Windows 上验**（见 §11）。
#>

if (-not $script:GfJsonLoaded2) { . "$PSScriptRoot\Json.ps1"; $script:GfJsonLoaded2 = $true }

function Get-GfBatchLockPath {
    param([Parameter(Mandatory)][string]$HubRoot, [Parameter(Mandatory)][string]$BatchId)
    return [System.IO.Path]::Combine($HubRoot, 'batches', "$BatchId.lock")
}

function Get-GfItemLockPath {
    param([Parameter(Mandatory)][string]$ItemDir)
    return [System.IO.Path]::Combine($ItemDir, '.gameflow', '.lock')
}

function Open-GfLock {
    <#
    .SYNOPSIS
        取一把独占锁。拿不到返回 $null（**不抛**）。
    .DESCRIPTION
        抢锁失败的姿态（§8.8.6）：**不区分** IOException（被占用）与
        UnauthorizedAccessException（权限/只读）—— 统一当作「没拿到」。
        区分它们需要比对 HResult，而那个值本身属于【待测】；更重要的是
        两种情况的处置完全相同：停在 LOCKED_BY_ANOTHER_RUN，不等待、不重试。

        锁文件内容只供人排查。**它不参与任何判定** —— 判定完全由句柄本身完成。
    .OUTPUTS
        $null 或 [pscustomobject]@{ Path; Stream; RunId }，用完必须 Close-GfLock。
    #>
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [string]$RunId = '',
        [string]$Note  = ''
    )
    # 建目录也必须在 try 内：契约是「拿不到返回 $null，不抛」，而路径不可建
    # （父级是个文件、权限不足、盘符不存在）与「被别人占着」对调用方是同一件事
    # —— 都停在 LOCKED_BY_ANOTHER_RUN。把它漏在 try 外面会让调用方吃到未捕获异常。
    $fs = $null
    try {
        $dir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($LiteralPath))
        if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
        $fs = [System.IO.File]::Open($LiteralPath,
                  [System.IO.FileMode]::OpenOrCreate,
                  [System.IO.FileAccess]::ReadWrite,
                  [System.IO.FileShare]::None)
    } catch {
        # IOException / UnauthorizedAccessException 一律当「没拿到」，不细分
        return $null
    }

    # 写入排查信息（仅给人看）。失败不影响持锁 —— 锁的效力来自句柄，不来自内容。
    try {
        $meta = ConvertTo-GfJson -InputObject ([ordered]@{
            run_id     = $RunId
            host       = [System.Net.Dns]::GetHostName()
            pid        = $PID
            started_at = [DateTimeOffset]::UtcNow.ToString('o')
            note       = $Note
            _note      = '仅供人排查。绝不用它判存活 —— PID 会被复用（§8.8.6）'
        }) -Compress
        $bytes = (Get-GfUtf8NoBom).GetBytes($meta + "`n")
        $fs.SetLength(0)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush($true)
    } catch { }

    return [pscustomobject]@{ Path = $LiteralPath; Stream = $fs; RunId = $RunId }
}

function Close-GfLock {
    <# 释放锁。传 $null 是合法的 no-op —— 调用方普遍在 finally 里无条件调它。 #>
    param($Lock)
    if ($null -eq $Lock) { return }
    if ($null -ne $Lock.Stream) { try { $Lock.Stream.Dispose() } catch { } }
}

function Invoke-GfWithLock {
    <#
    .SYNOPSIS
        在锁内跑一段代码，无论如何都释放。
    .OUTPUTS
        [pscustomobject]@{ Acquired = $bool; Result = <ScriptBlock 的返回值> }
        Acquired = $false ⇒ 调用方落运行期状况 LOCKED_BY_ANOTHER_RUN
        （**不落盘、不进状态机**，§4.2；批次级失败时进程退出码 75，不等待不重试）
    #>
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][scriptblock]$Body,
        [string]$RunId = ''
    )
    $lock = Open-GfLock -LiteralPath $LiteralPath -RunId $RunId
    if ($null -eq $lock) { return [pscustomobject]@{ Acquired = $false; Result = $null } }
    try {
        return [pscustomobject]@{ Acquired = $true; Result = (& $Body) }
    } finally {
        Close-GfLock -Lock $lock
    }
}

function Test-GfLockFree {
    <#
        探一下锁是否空闲。**这不是「先查后取」的授权** —— 查完到取之间有竞态窗口。
        它只用于对账报告里显示「这个条目现在被别人占着」，判定一律靠 Open-GfLock
        本身的成败。
    #>
    param([Parameter(Mandatory)][string]$LiteralPath)
    $l = Open-GfLock -LiteralPath $LiteralPath -Note 'probe'
    if ($null -eq $l) { return $false }
    Close-GfLock -Lock $l
    return $true
}
