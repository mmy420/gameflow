<#
.SYNOPSIS
    GameFlow Windows 侧检测 —— 一条命令，一份输出，贴回来即可。

.DESCRIPTION
    本项目在 macOS 上开发，以下几类事实**在开发机上原理上无法验证**，
    只能在目标机做。这个脚本把它们打包成一次运行：

      · 环境真相（PLAN 0.1 #1 / §11 #1）
      · lib 模块在 **Windows PowerShell 5.1** 与 **pwsh** 下的行为差异
      · 跨进程互斥（§8.8.6）—— Unix 的 FileShare 是进程内咨询语义，测不了
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

.PARAMETER OutFile
    结果 JSON。默认 .\docs\windows-check.json

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\Invoke-WindowsCheck.ps1 `
        -SampleGameDirs 'D:\Games\某个已解压的游戏'
#>
[CmdletBinding()]
param(
    [string]   $HubRoot = 'D:\GameHub',
    [string[]] $SampleGameDirs = @(),
    [string]   $OutFile
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $OutFile) { $OutFile = Join-Path $repo 'docs\windows-check.json' }
$fixtures = Join-Path $repo 'tests\fixtures'

$R = [ordered]@{
    schema_version = 1
    generated_at   = [DateTimeOffset]::UtcNow.ToString('o')
    host           = [ordered]@{
        ps_version = $PSVersionTable.PSVersion.ToString()
        ps_edition = $PSVersionTable.PSEdition
        exe        = (Get-Process -Id $PID).ProcessName
    }
    checks = [ordered]@{}
}
function Probe { param([string]$N, [scriptblock]$B)
    try { & $B } catch { return [ordered]@{ probe_failed = $true; error = $_.Exception.Message } } }
function Say { param([string]$T, [string]$C = 'Gray') Write-Host $T -ForegroundColor $C }

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
Say '═══ GameFlow Windows 检测 ═══════════════════════════════════' Cyan
Say ("  主机 PowerShell: {0} ({1})" -f $R.host.ps_version, $R.host.exe)
Say ("  7-Zip          : {0}" -f $(if ($sz) { $sz } else { '未找到 —— 多数检测会跳过' }))
Say ''

# ── W1 环境快照：直接复用 Preflight ─────────────────────────────────────────
Say '[W1] 环境快照（Preflight）...'
$R.checks.W1_preflight = Probe 'W1' {
    $pf = Join-Path $repo 'scripts\Preflight.ps1'
    $json = Join-Path $work 'preflight.json'
    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$pf,'-HubRoot',$HubRoot,'-OutFile',$json)
    if ($SampleGameDirs.Count) { $a += @('-SampleGameDirs'); $a += $SampleGameDirs }
    $out = & powershell.exe @a 2>&1
    $o = [ordered]@{ exit_code = $LASTEXITCODE; stdout_tail = @($out | Select-Object -Last 40 | ForEach-Object { "$_" }) }
    if (Test-Path -LiteralPath $json) { $o.snapshot = (Get-Content -LiteralPath $json -Raw | ConvertFrom-Json) }
    $o
}

# ── W2 单元测试：5.1 与 pwsh 各跑一遍 ───────────────────────────────────────
# 这是本脚本最重要的一项：lib 六模块至今**只在 macOS/pwsh 7.6 上跑过**。
Say '[W2] 单元测试（powershell 5.1 / pwsh 各一遍）...'
$R.checks.W2_unit_tests = Probe 'W2' {
    $runner = Join-Path $repo 'tests\Invoke-AllTests.ps1'
    $res = [ordered]@{}
    foreach ($h in @('powershell','pwsh')) {
        $exe = Get-Command "$h.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $exe) { $res[$h] = [ordered]@{ present = $false }; continue }
        $out = & $exe.Source -NoProfile -ExecutionPolicy Bypass -File $runner 2>&1
        $txt = @($out | ForEach-Object { "$_" })
        $res[$h] = [ordered]@{
            present   = $true
            exit_code = $LASTEXITCODE
            # 只留 PASS/FAIL 汇总行与全部 FAIL 明细，避免输出爆掉
            summary   = @($txt | Where-Object { $_ -match '项：|个测试文件' })
            failures  = @($txt | Where-Object { $_ -match '^\s*FAIL|^\s{6,}' } | Select-Object -First 60)
        }
    }
    $res
}

# ── W3 跨进程互斥（§8.8.6）——— macOS 上原理上测不了 ────────────────────────
Say '[W3] 跨进程互斥（FileShare.None）...'
$R.checks.W3_cross_process_lock = Probe 'W3' {
    $lockFile = Join-Path $work 'x.lock'
    $libLock  = Join-Path $repo 'scripts\lib\Lock.ps1'
    # 子进程持锁 8 秒
    $holder = @"
. '$libLock'
`$l = Open-GfLock -LiteralPath '$lockFile' -RunId 'holder'
if (`$null -eq `$l) { exit 9 }
Start-Sleep -Seconds 8
Close-GfLock -Lock `$l
"@
    $hp = Join-Path $work 'holder.ps1'
    [System.IO.File]::WriteAllText($hp, $holder, (New-Object System.Text.UTF8Encoding($true)))
    $p = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$hp) `
            -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2                      # 让它先拿到锁

    . $libLock
    $mine = Open-GfLock -LiteralPath $lockFile -RunId 'contender'
    $blockedWhileHeld = ($null -eq $mine)
    if ($mine) { Close-GfLock -Lock $mine }

    $p.WaitForExit(20000) | Out-Null
    Start-Sleep -Milliseconds 500
    $after = Open-GfLock -LiteralPath $lockFile -RunId 'after'
    $freeAfterRelease = ($null -ne $after)
    if ($after) { Close-GfLock -Lock $after }

    [ordered]@{
        blocked_while_held  = $blockedWhileHeld     # 必须 true —— 否则互斥根本不成立
        free_after_release  = $freeAfterRelease     # 必须 true —— 否则有陈旧锁问题
        holder_exit         = $p.ExitCode
        verdict             = $(if ($blockedWhileHeld -and $freeAfterRelease) { 'PASS' } else { 'FAIL' })
    }
}

# ── W4 加密包 + stdin 重定向：会不会挂（§11 #7，CONIN$ 疑云）────────────────
Say '[W4] 加密包 stdin 重定向（CONIN$ 疑云）...'
$R.checks.W4_encrypted_stdin = Probe 'W4' {
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
    if ($hung) { try { $pr.Kill($true) } catch {} }
    $exit = $(if ($hung) { $null } else { $pr.ExitCode })
    $text = ''
    try { $text = $outTask.GetAwaiter().GetResult() } catch { }
    $pr.Dispose()
    [ordered]@{
        hung      = $hung          # true ⇒ Windows 走 CONIN$，重定向挡不住 ⇒ 超时是唯一保险
        exit_code = $exit          # macOS 上是 255（「需要密码」）
        stdout    = @(($text -split "[`r`n]+") | Where-Object { $_ -ne '' } | Select-Object -First 15)
        note      = 'hung=true 意味着 §6.2 的超时不是可选项而是唯一保险'
    }
}

# ── W5 Shift-JIS ZIP 的落地文件名形态（§11 #11）────────────────────────────
Say '[W5] Shift-JIS ZIP 落地文件名...'
$R.checks.W5_sjis_zip = Probe 'W5' {
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
Say '[W6] 路径穿越落地位置...'
$R.checks.W6_traversal = Probe 'W6' {
    if (-not $sz) { return [ordered]@{ skipped = '无 7z' } }
    $base = Join-Path $work 'trav'; $out = Join-Path $base 'deep\er\out'
    [void](New-Item -ItemType Directory -Path $out -Force)
    $o = & $sz x -y -bso1 -bse1 "-o$out" (Join-Path $fixtures 'traversal.zip') 2>&1
    $landed = @(Get-ChildItem -LiteralPath $base -Recurse -File -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName.Substring($base.Length) })
    [ordered]@{
        exit_code = $LASTEXITCODE
        # 关键：有没有文件落到 $out 之外（那就是穿越成功）
        escaped   = @($landed | Where-Object { $_ -notlike '\deep\er\out\*' })
        landed    = $landed
        stdout    = @($o | ForEach-Object { "$_" } | Select-Object -First 25)
        note      = 'escaped 非空 = 穿越成功 = §6.6 的自查是必需的（7-Zip 的拦截是静默的）'
    }
}

# ── W7 -snz 的 MOTW 传播默认值（§11 #6）────────────────────────────────────
Say '[W7] MOTW 传播（-snz 默认值）...'
$R.checks.W7_motw = Probe 'W7' {
    if (-not $sz) { return [ordered]@{ skipped = '无 7z' } }
    $src = Join-Path $fixtures 'plain.7z'
    $marked = Join-Path $work 'marked.7z'
    Copy-Item -LiteralPath $src -Destination $marked -Force
    # 人为打上 MOTW
    Set-Content -LiteralPath "${marked}:Zone.Identifier" -Value "[ZoneTransfer]`r`nZoneId=3" -ErrorAction SilentlyContinue
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
Say '[W8] 长路径...'
$R.checks.W8_long_path = Probe 'W8' {
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

# ── 汇总 ────────────────────────────────────────────────────────────────────
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
[System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($OutFile),
    ($R | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))

Say ''
Say '─────────────────────────────────────────────────────────────'
foreach ($k in $R.checks.Keys) {
    $v = $R.checks[$k]
    $mark = '·'
    if ($v -is [System.Collections.IDictionary]) {
        if ($v.Contains('probe_failed')) { $mark = '❌' }
        elseif ($v.Contains('skipped'))  { $mark = '⏭' }
        elseif ($v.Contains('verdict'))  { $mark = $(if ($v['verdict'] -eq 'PASS') { '✅' } else { '❌' }) }
        else { $mark = '✅' }
    }
    Say ("  {0} {1}" -f $mark, $k)
}
Say '─────────────────────────────────────────────────────────────'
Say ("  结果 JSON → {0}" -f $OutFile) Cyan
Say '  把这个文件（或下面的摘要）整份贴回对话即可。' Cyan
Say '═════════════════════════════════════════════════════════════' Cyan
