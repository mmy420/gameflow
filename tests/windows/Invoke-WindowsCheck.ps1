<#
.SYNOPSIS
    GameFlow Windows 侧检测 —— 一条命令，一份输出，贴回来即可。

.DESCRIPTION
    本项目在 macOS 上开发，以下几类事实**在开发机上无法验证**，
    只能在目标机做。这个脚本把它们打包成一次运行：

      · 环境真相（PLAN 0.1 #1 / §11 #1）
      · lib 模块在 **Windows PowerShell 5.1** 与 **pwsh** 下的行为差异
      · 跨进程互斥（§8.8.6）—— 强制锁与跨会话只能在 Windows 上验
      · Shift-JIS ZIP 的落地文件名形态（§11 #11）
      · 路径穿越条目在 Windows 上的落地位置（§11 #13）
      · -mcp=932 对 x/l 是否真的生效（§11 #20，三方证据互相矛盾）
      · 加密包在 stdin 重定向自 NUL 时是否仍会挂起（§11 #7，CONIN$ 疑云）
      · -snz 的 MOTW 传播默认值（§11 #6）
      · 长路径实际行为（§11 #16）

    **只读 + 临时目录。** 除了 -OutFile 与系统临时目录下的工作区，不写任何地方，
    不改注册表，不装东西，不碰你的游戏库。

.PARAMETER HubRoot
    枢纽根，默认 D:\GameHub。不存在也能跑（会记成 absent）。

.PARAMETER SampleGameDirs
    已解压的真实游戏目录，用来量最长内部路径（§11 #26）。**强烈建议给**
    —— 它决定目录名降级会不会频繁触发。
    多个目录用「|」隔开写在**一个**字符串里：'D:\游戏A|E:\游戏B'（原因见 param 块后）。

.PARAMETER OutFile
    结果 JSON。默认 .\docs\windows-check.json。写不进去（比如 Codex 沙盒不让写仓库目录）
    时退到系统临时目录，最后一行会打印实际位置。**每跑完一项就落一次盘**。

.PARAMETER ProbeHubWrite
    在 HubRoot 里建一个唯一命名的探测文件并立即删掉（W9，§11 #2）。默认关。
    HubRoot 不存在时什么也不做 —— 不会顺手把枢纽建出来。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\Invoke-WindowsCheck.ps1 `
        -SampleGameDirs 'D:\Games\某个已解压的游戏|E:\old\另一个'
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]   $HubRoot = 'D:\GameHub',
    [string[]] $SampleGameDirs = @(),
    [string]   $OutFile,
    # 默认关。开启后在 HubRoot 里建一个唯一命名的探测文件并立即删掉，用来回答
    # 「当前进程（尤其是 Codex 沙盒里的进程）能不能写枢纽」—— §11 #2。
    # 这是本脚本**唯一**会写到临时目录以外的动作，所以必须显式开启。
    [switch]   $ProbeHubWrite
)

$ErrorActionPreference = 'Continue'

# 多个目录用「|」隔开。经 powershell -File 调用时数组**不会**被展开（2026-09-29 实测）：
#   外层是 pwsh → 'A','B' 连引号整串成为一个值，是个不存在的路径；
#   外层把它拆成多个参数 → 第二个成了位置参数，悄悄绑到 -OutFile 上。
# 所以关掉位置绑定（多出来的参数直接报错），并按「|」拆分 —— 它是 Windows 文件名
# 的非法字符，拆分零歧义。
$SampleGameDirs = @($SampleGameDirs | ForEach-Object { $_ -split '\|' } |
                    ForEach-Object { $_.Trim() } | Where-Object { $_ })
# 旧写法 'A','B' 经 pwsh 外层传进来会变成**一个**连引号的值（实测），不会报错 ——
# 整轮检测会带着一个不存在的路径跑完，W1 什么也量不到。宁可立刻停下说清楚。
$bad = @($SampleGameDirs | Where-Object { $_ -match "^['`"]|['`"]$|','" })
if ($bad.Count) {
    Write-Host ("-SampleGameDirs 收到的值带引号或逗号：{0}" -f ($bad -join ' ; ')) -ForegroundColor Red
    Write-Host "多个目录请写成一个字符串、用 | 隔开：-SampleGameDirs 'D:\游戏A|E:\游戏B'" -ForegroundColor Red
    exit 2
}

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $OutFile) { $OutFile = Join-Path $repo 'docs\windows-check.json' }
$fixtures = Join-Path $repo 'tests\fixtures'

$R = [ordered]@{
    schema_version = 2
    generated_at   = [DateTimeOffset]::UtcNow.ToString('o')
    completed      = $false      # 跑到最后才置 true；false ⇒ 中途被杀，看 in_progress
    in_progress    = $null       # 正在跑哪一项 —— 被 Codex 超时杀掉时，它就是卡住的那项
    host           = [ordered]@{
        ps_version = $PSVersionTable.PSVersion.ToString()
        ps_edition = $PSVersionTable.PSEdition
        exe        = (Get-Process -Id $PID).ProcessName
    }
    # 脚本**实际收到**的参数。参数在传递中被拆坏时，这一格能直接看出来
    params         = [ordered]@{
        hub_root         = $HubRoot
        sample_game_dirs = $SampleGameDirs
        probe_hub_write  = [bool]$ProbeHubWrite
    }
    checks = [ordered]@{}
}

# 每跑完一项就落一次盘：被 Codex 超时杀掉、或被 Ctrl+C 中断时，已跑完的项仍在文件里。
# 首选 -OutFile（默认仓库的 docs\）；写不进去就退到临时目录 —— 结果不能因为
# 「结果文件没地方放」而整份丢掉。
$script:OutFallback = Join-Path ([System.IO.Path]::GetTempPath()) 'gameflow-windows-check.json'
$script:WrittenTo   = $null
function Save-Result {
    $text = $R | ConvertTo-Json -Depth 12
    foreach ($t in @($OutFile, $script:OutFallback)) {
        try {
            $full = [System.IO.Path]::GetFullPath($t)
            $d = Split-Path -Parent $full
            if ($d -and -not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
            [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding($false)))
            $script:WrittenTo = $full
            return
        } catch { $R.save_error = "$t → $($_.Exception.Message)" }
    }
}

# ── 执行上下文 ──────────────────────────────────────────────────────────────
# 由 Codex 执行时，沙盒可能拦截写临时目录、起子进程等动作。那些失败是**沙盒
# 造成的**，不是这台机器的事实。不记录上下文，就会把沙盒拦截误读成系统结论。
$ctx = [ordered]@{
    user          = [Environment]::UserName          # Codex 的 elevated 沙盒会换成独立的本地用户
    machine       = $env:COMPUTERNAME
    codex_env     = @()                                # 只记变量**名**；只有 *SANDBOX* 类才记值
    temp_writable = $false
}
foreach ($v in (Get-ChildItem Env: | Where-Object { $_.Name -like 'CODEX*' })) {
    $entry = [ordered]@{ name = $v.Name }
    # 只记**模式类**变量的值（非机密）。PERMISSION_PROFILE 是 2026-09-29 第一次 Windows 实测
    # 后补的：不知道 Codex 当时是不是沙盒模式，W9 的「能写」就说明不了 writable_roots 生没生效
    if ($v.Name -match 'SANDBOX|PERMISSION' -or $v.Name -in @('CODEX_SHELL','CODEX_VERSION')) { $entry.value = $v.Value }
    $ctx.codex_env += $entry
}
try {
    $tp = Join-Path ([System.IO.Path]::GetTempPath()) ('gfctx-' + [Guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($tp, 'x'); Remove-Item -LiteralPath $tp -Force
    $ctx.temp_writable = $true
} catch { $ctx.temp_error = $_.Exception.Message }
$ctx.likely_under_codex = ($ctx.codex_env.Count -gt 0)
$R.context = $ctx
function Probe { param([string]$N, [scriptblock]$B)
    try { & $B } catch { return [ordered]@{ probe_failed = $true; error = $_.Exception.Message } } }
function Say { param([string]$T, [string]$C = 'Gray') Write-Host $T -ForegroundColor $C }
function Invoke-Check { param([string]$Key, [string]$Title, [scriptblock]$Body)
    Say $Title
    $R.in_progress = $Key; Save-Result          # 先记「正在跑谁」再跑，被杀时才知道卡在哪
    $R.checks[$Key] = Probe $Key $Body
    $R.in_progress = $null; Save-Result
}

# 工作区：全部动作都在这里，跑完删掉
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('gfwin-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
[void](New-Item -ItemType Directory -Path $work -Force)

$sz = $null
foreach ($c in @('7z.exe', "$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe")) {
    $f = Get-Command $c -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $sz = $f.Source; break }
    if (Test-Path -LiteralPath $c) { $sz = $c; break }
}

Say ''
Say '=== GameFlow Windows check ==================================' Cyan
Say ("  PowerShell     : {0} ({1})" -f $R.host.ps_version, $R.host.exe)
Say ("  7-Zip          : {0}" -f $(if ($sz) { $sz } else { 'NOT FOUND —— 多数检测会跳过' }))
Say ("  SampleGameDirs : {0} 个（多个用 | 隔开；数目不对说明参数传坏了）" -f $SampleGameDirs.Count)
Say ''
Save-Result    # 先落一份只有上下文与参数的文件：连 W1 都没跑完就被杀，也知道参数收到了什么

# ── W1 环境快照：直接复用 Preflight ─────────────────────────────────────────
Invoke-Check 'W1_preflight' '[W1] 环境快照（Preflight）...' {
    $pf = Join-Path $repo 'scripts\Preflight.ps1'
    $json = Join-Path $work 'preflight.json'
    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$pf,'-HubRoot',$HubRoot,'-OutFile',$json)
    # 多个目录拼成**一个**「|」分隔的参数 —— 经 -File 传数组会被拆坏（见 param 块后）
    if ($SampleGameDirs.Count) { $a += @('-SampleGameDirs', ($SampleGameDirs -join '|')) }
    $out = & powershell.exe @a 2>&1
    $o = [ordered]@{ exit_code = $LASTEXITCODE; stdout_tail = @($out | Select-Object -Last 40 | ForEach-Object { "$_" }) }
    # 必须显式按 UTF-8 读：5.1 的 Get-Content 把无 BOM 文件当系统 ANSI 解码，
    # 快照里的中文说明与游戏目录名会整段变乱码，而且乱码会被原样写进结果 JSON
    if (Test-Path -LiteralPath $json) {
        $o.snapshot = ([System.IO.File]::ReadAllText($json, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
    }
    $o
}

# ── W2 单元测试：5.1 与 pwsh 各跑一遍 ───────────────────────────────────────
# 这是本脚本最重要的一项：lib 六模块至今**只在 macOS/pwsh 7.6 上跑过**。
Invoke-Check 'W2_unit_tests' '[W2] 单元测试（powershell 5.1 / pwsh 各一遍）...' {
    $runner = Join-Path $repo 'tests\Invoke-AllTests.ps1'
    $res = [ordered]@{}
    # 三个宿主：5.1、PATH 上的 pwsh、系统装的 pwsh。在 Codex 里跑时 PATH 上的 pwsh 是
    # **Codex 自带的运行时**（第一次实测发现），计划任务里用的是系统装的那个 —— 两者不同就都测
    $hosts = [ordered]@{}
    foreach ($h in @('powershell','pwsh')) {
        $c = Get-Command "$h.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $hosts[$h] = $(if ($c) { $c.Source } else { $null })
    }
    $sysPwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    if ((Test-Path -LiteralPath $sysPwsh) -and $sysPwsh -ne $hosts['pwsh']) { $hosts['pwsh_system'] = $sysPwsh }
    foreach ($h in @($hosts.Keys)) {
        $exePath = $hosts[$h]
        if (-not $exePath) { $res[$h] = [ordered]@{ present = $false }; continue }
        $out = & $exePath -NoProfile -ExecutionPolicy Bypass -File $runner 2>&1
        $exit = $LASTEXITCODE
        $txt = @($out | ForEach-Object { "$_" })
        # 跳过与失败的总数单独成数：汇总行里「SKIP 11」一眼就能看见，而不是被 exit 0 盖住
        $skipTotal = 0; $failTotal = 0
        foreach ($l in $txt) {
            $m = [regex]::Match($l, 'PASS \d+\s+SKIP (\d+)\s+FAIL (\d+)')
            if ($m.Success) { $skipTotal += [int]$m.Groups[1].Value; $failTotal += [int]$m.Groups[2].Value }
        }
        $res[$h] = [ordered]@{
            present    = $true
            path       = $exePath
            exit_code  = $exit
            skip_total = $skipTotal
            fail_total = $failTotal
            # 汇总行只用 ASCII 匹配：子进程输出要过控制台代码页，中文在非 936 的
            # 机器上可能变成「?」，按中文匹配就会一行都抓不到
            summary   = @($txt | Where-Object { $_ -match 'PASS \d+.*FAIL \d+' })
            # 除 PASS 行、空行、分隔线外全留：每个文件的标题、SKIP 及其原因、FAIL 明细、以及
            # 测试文件在 5.1 下根本加载不起来时的解析错误，都在这里面
            details   = @($txt | Where-Object { $_.Trim() -and $_ -notmatch '^\s*PASS\s' -and $_ -notmatch '^[\s─]+$' } |
                          Select-Object -First 150)
        }
    }
    $res
}

# ── W3 跨进程互斥（§8.8.6）—— 只能在 Windows 验的是强制锁与跨会话 ───────────
Invoke-Check 'W3_cross_process_lock' '[W3] 跨进程互斥（FileShare.None）...' {
    $lockFile = Join-Path $work 'x.lock'
    $flag     = Join-Path $work 'holder.acquired'     # 持锁方拿到锁后才写它
    $release  = Join-Path $work 'holder.release'      # 主进程写它 = 通知持锁方放锁
    $libLock  = Join-Path $repo 'scripts\lib\Lock.ps1'
    # 握手协议，取代「睡 2 秒赌它已经拿到锁」：
    #   5.1 冷启动（加上 Defender 首次扫描新脚本）经常超过 2 秒。持锁方还没拿到锁，
    #   主进程就先抢到了 → blocked_while_held=false → 报出**假的 FAIL**。
    #   而 W3 恰恰是唯一一项「FAIL 即阻塞」的检测，假 FAIL 代价最高。
    $holder = @"
. '$libLock'
`$l = Open-GfLock -LiteralPath '$lockFile' -RunId 'holder'
if (`$null -eq `$l) { exit 9 }
[System.IO.File]::WriteAllText('$flag', 'ok')
`$deadline = (Get-Date).AddSeconds(60)
while (-not (Test-Path -LiteralPath '$release') -and (Get-Date) -lt `$deadline) { Start-Sleep -Milliseconds 200 }
Close-GfLock -Lock `$l
exit 0
"@
    $hp = Join-Path $work 'holder.ps1'
    [System.IO.File]::WriteAllText($hp, $holder, (New-Object System.Text.UTF8Encoding($true)))
    $sp = @{ FilePath = 'powershell.exe'; PassThru = $true
             ArgumentList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$hp) }
    # -WindowStyle 只在 Windows 上存在；这样开发机上也能把握手逻辑真跑一遍
    if ($env:OS -eq 'Windows_NT') { $sp.WindowStyle = 'Hidden' }
    $p = Start-Process @sp
    $null = $p.Handle     # 5.1 的已知坑：不先取一次 Handle，退出后 ExitCode 读出来是 $null

    # 等持锁方**确认拿到锁**，最多 45 秒
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $flag) -and $sw.Elapsed.TotalSeconds -lt 45 -and -not $p.HasExited) {
        Start-Sleep -Milliseconds 200
    }
    $holderAcquired = Test-Path -LiteralPath $flag
    $waitedSec = [Math]::Round($sw.Elapsed.TotalSeconds, 1)

    . $libLock
    $blockedWhileHeld = $null
    if ($holderAcquired) {
        $mine = Open-GfLock -LiteralPath $lockFile -RunId 'contender'
        $blockedWhileHeld = ($null -eq $mine)
        if ($mine) { Close-GfLock -Lock $mine }
    }

    [System.IO.File]::WriteAllText($release, 'go')
    [void]$p.WaitForExit(20000)
    Start-Sleep -Milliseconds 300
    $after = Open-GfLock -LiteralPath $lockFile -RunId 'after'
    $freeAfterRelease = ($null -ne $after)
    if ($after) { Close-GfLock -Lock $after }

    # 持锁方根本没拿到锁 → 这一轮**什么也没测到**，不能判 FAIL
    $verdict = 'INCONCLUSIVE'
    if ($holderAcquired) {
        $verdict = $(if ($blockedWhileHeld -and $freeAfterRelease) { 'PASS' } else { 'FAIL' })
    }
    [ordered]@{
        holder_acquired     = $holderAcquired       # false ⇒ 子进程没起来或被拦（Codex 沙盒？）
        holder_wait_seconds = $waitedSec            # 5.1 冷启动实际耗时，顺带量一下
        blocked_while_held  = $blockedWhileHeld     # 必须 true —— 否则互斥根本不成立
        free_after_release  = $freeAfterRelease     # 必须 true —— 否则有陈旧锁问题
        holder_exit         = $(if ($p.HasExited) { $p.ExitCode } else { $null })
        verdict             = $verdict
        note                = 'INCONCLUSIVE ≠ FAIL：持锁方没拿到锁，本轮没测到互斥。在普通终端重跑'
    }
}

# ── W4 加密包 + stdin 重定向：会不会挂（§11 #7，CONIN$ 疑云）────────────────
Invoke-Check 'W4_encrypted_stdin' '[W4] 加密包 stdin 重定向（CONIN$ 疑云）...' {
    if (-not $sz) { return [ordered]@{ skipped = '无 7z' } }
    $arc = Join-Path $fixtures 'enc-header.7z'
    if (-not (Test-Path -LiteralPath $arc)) { return [ordered]@{ skipped = '缺 fixture' } }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $sz
    $psi.Arguments = "l -bso1 -bse1 `"$arc`""     # 诊断脚本用 Arguments 够了
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $true
    $pr = [System.Diagnostics.Process]::new(); $pr.StartInfo = $psi
    [void]$pr.Start(); $pr.StandardInput.Close()
    # 先起异步读再等退出，否则管道写满会死锁；结果要取回来，它有诊断价值
    $outTask = $pr.StandardOutput.ReadToEndAsync()
    $hung = -not $pr.WaitForExit(15000)
    # 只能用无参 Kill()：Kill($true)（连子进程树）是 .NET Core 3.0+ 才有的重载，
    # 在 5.1 上调用会抛「找不到重载」，被 catch 吞掉 → 7z 没被杀 → 下面读输出永远等不到头
    # → 整个检测挂死在 W4。恰好是这一项要测的「会挂」那种情况。7z 不起子进程，无参够用。
    $killError = $null
    if ($hung) { try { $pr.Kill() } catch { $killError = $_.Exception.Message } }
    $exit = $(if ($hung) { $null } else { $pr.ExitCode })
    $text = ''
    # 读输出也设上限：万一进程没杀掉，管道不关，无限期等待就会把整个脚本拖死
    try { if ($outTask.Wait(5000)) { $text = $outTask.Result } } catch { }
    $pr.Dispose()
    [ordered]@{
        hung      = $hung          # true ⇒ Windows 走 CONIN$，重定向挡不住 ⇒ 超时是唯一保险
        exit_code = $exit          # macOS 上是 255（「需要密码」）
        kill_error = $killError    # 非空 ⇒ 挂住的 7z 没杀掉，去任务管理器手动结束它
        stdout    = @(($text -split "[`r`n]+") | Where-Object { $_ -ne '' } | Select-Object -First 15)
        note      = 'hung=true 意味着 §6.2 的超时不是可选项而是唯一保险'
    }
}

# ── W5 Shift-JIS ZIP 的落地文件名形态（§11 #11）────────────────────────────
Invoke-Check 'W5_sjis_zip' '[W5] Shift-JIS ZIP 落地文件名...' {
    if (-not $sz) { return [ordered]@{ skipped = '无 7z' } }
    $out = Join-Path $work 'sjis'; [void](New-Item -ItemType Directory -Path $out -Force)
    & $sz x -y -bso0 -bse0 "-o$out" (Join-Path $fixtures 'sjis-legacy.zip') 2>&1 | Out-Null
    $f = Get-ChildItem -LiteralPath $out -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $name = if ($f) { $f.Name } else { $null }
    $cps  = if ($name) { @($name.ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) } else { @() }

    $out2 = Join-Path $work 'sjis-mcp'; [void](New-Item -ItemType Directory -Path $out2 -Force)
    & $sz x -y -bso0 -bse0 -mcp=932 "-o$out2" (Join-Path $fixtures 'sjis-legacy.zip') 2>&1 | Out-Null
    $f2 = Get-ChildItem -LiteralPath $out2 -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $name2 = if ($f2) { $f2.Name } else { $null }

    [ordered]@{
        landed_name        = $name        # 期望之一：ねこぱら.txt / 乱码 / U+EFxx 私用区转义
        landed_codepoints  = $cps
        with_mcp932_name   = $name2       # §11 #20：-mcp 到底有没有用
        mcp_changed_result = ($name -ne $name2)
        expected_correct   = 'ねこぱら.txt'
    }
}

# ── W6 路径穿越条目的落地位置（§11 #13）────────────────────────────────────
Invoke-Check 'W6_traversal' '[W6] 路径穿越落地位置...' {
    if (-not $sz) { return [ordered]@{ skipped = '无 7z' } }
    $base = Join-Path $work 'trav'; $out = Join-Path $base 'deep\er\out'
    [void](New-Item -ItemType Directory -Path $out -Force)
    $o = & $sz x -y -bso1 -bse1 "-o$out" (Join-Path $fixtures 'traversal.zip') 2>&1
    $exit = $LASTEXITCODE
    # 截前缀用的根必须和枚举结果同源：TEMP 常是 8.3 短名（C:\Users\WENZHU~1\…），
    # 自己拼的 $base 与 FullName 的形态一旦不一致，每个文件都会被误判成「穿越成功」
    $baseFull = (Get-Item -LiteralPath $base).FullName
    $outFull  = (Get-Item -LiteralPath $out).FullName.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $files = @(Get-ChildItem -LiteralPath $baseFull -Recurse -File -ErrorAction SilentlyContinue)
    [ordered]@{
        exit_code = $exit
        # 关键：有没有文件落到 $out 之外（那就是穿越成功）。按前缀判，不写死分隔符
        escaped   = @($files | Where-Object { -not $_.FullName.StartsWith($outFull, [System.StringComparison]::OrdinalIgnoreCase) } |
                      ForEach-Object { $_.FullName.Substring($baseFull.Length) })
        landed    = @($files | ForEach-Object { $_.FullName.Substring($baseFull.Length) })
        stdout    = @($o | ForEach-Object { "$_" } | Select-Object -First 25)
        note      = 'escaped 非空 = 穿越成功 = §6.6 的自查是必需的（7-Zip 的拦截是静默的）'
    }
}

# ── W7 -snz 的 MOTW 传播默认值（§11 #6）────────────────────────────────────
Invoke-Check 'W7_motw' '[W7] MOTW 传播（-snz 默认值）...' {
    if (-not $sz) { return [ordered]@{ skipped = '无 7z' } }
    $src = Join-Path $fixtures 'plain.7z'
    $marked = Join-Path $work 'marked.7z'
    Copy-Item -LiteralPath $src -Destination $marked -Force
    # 人为打上 MOTW。必须用 -Stream：「文件名:流名」拼进路径的写法在 5.1 上会被
    # 当成非法路径格式拒掉，而 -ErrorAction SilentlyContinue 会把失败吞掉 ——
    # 结果是 source_marked=false，整项静默作废
    Set-Content -LiteralPath $marked -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`r`nZoneId=3" -ErrorAction SilentlyContinue
    $hasZone = $null -ne (Get-Item -LiteralPath $marked -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue)

    $r = [ordered]@{ source_marked = $hasZone }
    foreach ($mode in @('default','snz')) {
        $o = Join-Path $work "motw-$mode"; [void](New-Item -ItemType Directory -Path $o -Force)
        # 不能叫 $args —— 那是 PowerShell 的自动变量，覆盖它会有意外行为
        $szArgs = @('x','-y','-bso0','-bse0',"-o$o",$marked)
        if ($mode -eq 'snz') { $szArgs = @('x','-y','-bso0','-bse0','-snz',"-o$o",$marked) }
        & $sz @szArgs 2>&1 | Out-Null
        $one = Get-ChildItem -LiteralPath $o -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        $prop = $false
        if ($one) { $prop = $null -ne (Get-Item -LiteralPath $one.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue) }
        $r["propagated_$mode"] = $prop
    }
    $r.note = 'propagated_default=false 即社区共识（CLI 默认不传播）得到确认'
    $r
}

# ── W8 长路径实际行为（§11 #16）────────────────────────────────────────────
Invoke-Check 'W8_long_path' '[W8] 长路径...' {
    $seg = 'a' * 40
    $p = $work
    for ($i = 0; $i -lt 7; $i++) { $p = Join-Path $p $seg }     # ≈ 300+ 字符
    $created = $false; $err = $null
    try { [void](New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop); $created = $true }
    catch { $err = $_.Exception.Message }
    [ordered]@{
        target_length = $p.Length
        created       = $created
        error         = $err
        note          = 'SPEC 的姿态是「从源头压短路径」，本项不阻塞，只是确认代价'
    }
}

# ── W9 能不能写枢纽（§11 #2，opt-in）────────────────────────────────────────
if ($ProbeHubWrite) {
    Invoke-Check 'W9_hub_write' '[W9] 枢纽写入探测...' {
        if (-not (Test-Path -LiteralPath $HubRoot)) {
            return [ordered]@{ skipped = "HubRoot 不存在：$HubRoot（不会替你建）" }
        }
        $probe = Join-Path $HubRoot ('_gameflow_probe_' + [Guid]::NewGuid().ToString('N').Substring(0,8) + '.tmp')
        $wrote = $false; $removed = $false; $err = $null
        try {
            [System.IO.File]::WriteAllText($probe, 'gameflow write probe')
            $wrote = $true
            Remove-Item -LiteralPath $probe -Force
            $removed = -not (Test-Path -LiteralPath $probe)
        } catch { $err = $_.Exception.Message }
        [ordered]@{
            hub_root = $HubRoot
            wrote    = $wrote      # Codex 下为 false ⇒ writable_roots 没生效或沙盒不允许
            removed  = $removed    # 我们自己的探测文件必须能删掉
            error    = $err
            note     = '在 Codex 里跑时，这一格就是 §11 #2 的答案'
        }
    }
}

# ── 汇总 ────────────────────────────────────────────────────────────────────
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
$R.completed = $true
Save-Result

# 汇总行**只用 ASCII**：5.1 的输出经过控制台代码页交给 Codex，emoji 与部分中文会
# 变成「?」—— 而这几行恰恰是 Codex 转述给你的东西。每行附几个标量字段（布尔/数字），
# 即使 JSON 文件没能带出来，关键事实也还在。
function Get-Brief { param($V)
    $parts = @()
    foreach ($k in $V.Keys) {
        $x = $V[$k]
        if ($x -is [bool] -or $x -is [int] -or $x -is [long] -or $x -is [double]) { $parts += "$k=$x" }
        elseif ($x -is [array]) { $parts += "$k.count=$($x.Count)" }
        elseif ($x -is [System.Collections.IDictionary]) {
            # 嵌套一层只取整数（W2 的 exit_code / skip_total / fail_total），三个宿主正好放得下
            foreach ($k2 in $x.Keys) { $y = $x[$k2]; if ($y -is [int]) { $parts += "$k.$k2=$y" } }
        }
    }
    ($parts | Select-Object -First 9) -join ' '
}
Say ''
Say '-------------------------------------------------------------'
foreach ($k in $R.checks.Keys) {
    $v = $R.checks[$k]
    $mark = '[DONE]'            # 数据已采集，好坏要看 JSON —— 不等于「通过」
    $brief = ''
    if ($v -is [System.Collections.IDictionary]) {
        if ($v.Contains('probe_failed')) { $mark = '[ERROR]' }
        elseif ($v.Contains('skipped'))  { $mark = '[SKIP]' }
        elseif ($v.Contains('verdict'))  { $mark = "[$($v['verdict'])]" }
        if (-not $v.Contains('probe_failed') -and -not $v.Contains('skipped')) { $brief = Get-Brief $v }
    }
    Say ("  {0,-15} {1,-24} {2}" -f $mark, $k, $brief)
}
Say '-------------------------------------------------------------'
Say ("  RESULT JSON: {0}" -f $script:WrittenTo) Cyan
if ($script:WrittenTo -and $script:WrittenTo -ne [System.IO.Path]::GetFullPath($OutFile)) {
    Say ("  （-OutFile 写不进去，已改写到临时目录。原因见 JSON 的 save_error）") Yellow
}
Say '  把这个文件整份发回来即可。' Cyan
if ($ctx.likely_under_codex) {
    Say '  UNDER CODEX: 若有 [ERROR]/[INCONCLUSIVE] 且错误像是「拒绝访问」，可能是沙盒拦截而非系统事实，' Yellow
    Say '  那几项请在普通终端里再跑一次对照。' Yellow
}
Say '============================================================='
