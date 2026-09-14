<#
.SYNOPSIS
    GameFlow 环境探测（PLAN 阶段 0.1 / 0.2，SPEC §9.11）。

.DESCRIPTION
    只读。把「这台机器到底是什么样」固化成一份 JSON 快照 + 一份人读摘要。
    SPEC 里所有标【待测】的环境类断言，答案都在这份输出里。

    本脚本刻意不依赖 scripts\lib\ —— 它要在 lib 存在之前就能跑。
    也刻意兼容 Windows PowerShell 5.1 —— 因为 Codex 的 Windows 原生 agent
    调的就是 powershell.exe（SPEC §8.2.1），不能假设 pwsh 7 在场。

.PARAMETER HubRoot
    枢纽根。默认 D:\GameHub。不存在也不报错——会记成 absent 并给出建议。

.PARAMETER SampleGameDirs
    已解压的真实游戏目录，用于测量「最长内部条目路径」（SPEC §11 #26）。
    这条直接决定 MAX_PATH 预算够不够、目录名降级会不会频繁触发。
    例：-SampleGameDirs 'D:\Games\ABC','E:\old\XYZ'

.PARAMETER OutFile
    JSON 快照落盘位置。不给就只打印摘要，一个文件都不写。

.EXAMPLE
    .\Preflight.ps1
.EXAMPLE
    .\Preflight.ps1 -HubRoot D:\GameHub -SampleGameDirs 'D:\Games\某游戏' -OutFile .\docs\preflight.json
#>
[CmdletBinding()]
param(
    [string]   $HubRoot = 'D:\GameHub',
    [string[]] $SampleGameDirs = @(),
    [string]   $OutFile
)

# 刻意不开 StrictMode：Preflight 的价值在于「即使几项探不到也要出一份快照」。
# 开了 StrictMode，任何一个探测项返回 error 对象都会让后面的判定段整体崩掉。
$ErrorActionPreference = 'Continue'

# ── 小工具 ────────────────────────────────────────────────────────────────────
# 探测项一律走 Probe：任何一条炸了都不许中断整个 Preflight —— 一份缺了三项的
# 快照仍然有用，一个跑到一半崩掉的脚本没用。
function Probe {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body }
    catch {
        Write-Verbose "[$Name] $($_.Exception.Message)"
        return [ordered]@{ probe_failed = $true; error = $_.Exception.Message }
    }
}

# 安全取值：探测项可能整个失败，也可能只缺某个键。
# 全脚本的判定段一律走它，不直接用 .属性 —— 这样任何一项探不到都只是少一条结论。
function Get-Val {
    param($Obj, [string]$Key, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    try {
        if ($Obj -is [System.Collections.IDictionary]) {
            if ($Obj.Contains($Key)) { $v = $Obj[$Key] } else { return $Default }
        } else {
            $p = $Obj.PSObject.Properties[$Key]
            if ($null -eq $p) { return $Default }
            $v = $p.Value
        }
    } catch { return $Default }
    if ($null -eq $v) { return $Default }
    return $v
}

function Get-CmdPath {
    param([string]$Name)
    $c = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if ($c) { return $c.Source }
    return $null
}

function Test-PathUnder {
    param([string]$Path, [string]$Ancestor)
    if (-not $Path -or -not $Ancestor) { return $false }
    try {
        $p = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        $a = [System.IO.Path]::GetFullPath($Ancestor).TrimEnd('\')
    } catch { return $false }
    return $p.Equals($a, 'OrdinalIgnoreCase') -or
           $p.StartsWith($a + '\', 'OrdinalIgnoreCase')
}

$R = [ordered]@{}
$R.schema_version = 1
$R.generated_at   = [DateTimeOffset]::UtcNow.ToString('o')
$R.hub_root_arg   = $HubRoot

# ── PF-00 平台 ───────────────────────────────────────────────────────────────
$R.platform = Probe 'platform' {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $caption = $null; $osver = $null; $build = $null
    if ($os) { $caption = $os.Caption; $osver = $os.Version; $build = $os.BuildNumber }
    $isAdmin = $false; $sid = $null
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)
                   ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $sid = $id.User.Value
    } catch {}
    [ordered]@{
        is_windows     = ($env:OS -eq 'Windows_NT')
        caption        = $caption
        version        = $osver
        build          = $build
        is_admin       = $isAdmin
        user_sid       = $sid
        machine        = $env:COMPUTERNAME
    }
}

# ── PF-01 归档引擎（SPEC §6.2、D-17）──────────────────────────────────────────
# E3 只说了「装了 7-Zip 或 WinRAR/Bandizip」，没指明哪个。7z.exe 缺席是硬阻塞。
$R.archiver = Probe 'archiver' {
    $sevenZip = Get-CmdPath '7z.exe'
    if (-not $sevenZip) {
        foreach ($c in @(
            "$env:ProgramFiles\7-Zip\7z.exe",
            "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
            "$env:LOCALAPPDATA\Programs\7-Zip\7z.exe")) {
            if (Test-Path -LiteralPath $c) { $sevenZip = $c; break }
        }
    }
    $ver = $null; $handlers = $null; $floorOk = $false; $recOk = $false
    if ($sevenZip) {
        # 7z 无 --version；第一行形如 "7-Zip 24.09 (x64) : Copyright ..."
        $head = & $sevenZip 2>&1 | Select-Object -First 3
        $m = [regex]::Match(($head -join ' '), '7-Zip(?:\s*\(\w+\))?\s+(\d+\.\d+)')
        if ($m.Success) { $ver = $m.Groups[1].Value }
        # handler 名的逐字拼写 —— container-types.json 要用它（SPEC §11 #25）
        $i = & $sevenZip i 2>&1
        $handlers = @($i | Select-String -Pattern '^\s*\d+\s+\S+\s+(\S+)' |
                          ForEach-Object { $_.Matches[0].Groups[1].Value })
    }
    if ($ver) {
        try {
            $floorOk = ([version]$ver -ge [version]'25.01')   # D-17 硬下限
            $recOk   = ([version]$ver -ge [version]'26.02')   # D-17 建议线
        } catch { $floorOk = $false; $recOk = $false }
    }
    [ordered]@{
        sevenzip_path      = $sevenZip
        sevenzip_version   = $ver
        meets_hard_floor   = $floorOk
        meets_recommended  = $recOk
        handlers           = $handlers
        winrar_path        = Get-CmdPath 'WinRAR.exe'
        rar_cli_path       = Get-CmdPath 'Rar.exe'
        bandizip_path      = Get-CmdPath 'Bandizip.exe'
    }
}

# ── PF-02 PowerShell（SPEC §8.8.1）───────────────────────────────────────────
$R.powershell = Probe 'powershell' {
    $pwsh = Get-CmdPath 'pwsh.exe'
    $pwshVer = $null
    if ($pwsh) { $pwshVer = (& $pwsh -NoProfile -c '$PSVersionTable.PSVersion.ToString()' 2>&1 | Select-Object -First 1) }
    # 版本比较提到哈希字面量外面：5.1 的哈希值位置不保证能容纳 try/catch
    $meets74 = $false
    if ($pwshVer) {
        try { $meets74 = ([version]("$pwshVer" -replace '-.*$') -ge [version]'7.4') } catch { $meets74 = $false }
    }
    [ordered]@{
        current_version  = $PSVersionTable.PSVersion.ToString()
        current_edition  = $PSVersionTable.PSEdition
        host_exe         = (Get-Process -Id $PID).ProcessName
        pwsh_path        = $pwsh
        pwsh_version     = $pwshVer
        # 脚本内部可用 7.4 语义（前提是被 pwsh 执行）；但 Codex 那一层永远是 5.1
        pwsh_meets_74    = $meets74
    }
}

# ── PF-06 执行策略（SPEC §8.4）───────────────────────────────────────────────
$R.execution_policy = Probe 'execution_policy' {
    $list = Get-ExecutionPolicy -List
    $o = [ordered]@{}
    foreach ($e in $list) { $o[[string]$e.Scope] = [string]$e.ExecutionPolicy }
    $o['effective'] = [string](Get-ExecutionPolicy)
    # GPO 锁死时 Set-ExecutionPolicy 无效，只能靠 -ExecutionPolicy Bypass 逐进程绕
    $o['locked_by_gpo'] = ($o['MachinePolicy'] -ne 'Undefined') -or ($o['UserPolicy'] -ne 'Undefined')
    $o
}

# ── PF-04/08 代码页与 Beta UTF-8（SPEC §6.3、§3.2A）──────────────────────────
# ACP 决定：中文密码的字节形态、dirname 能不能保留原标题。不断言必须是 936。
$R.codepage = Probe 'codepage' {
    $nls = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -ErrorAction SilentlyContinue
    $acp = $null; $oem = $null; $acpName = $null
    if ($nls) {
        try { $acp = [int]$nls.ACP }   catch {}
        try { $oem = [int]$nls.OEMCP } catch {}
    }
    if ($acp) { try { $acpName = [System.Text.Encoding]::GetEncoding($acp).WebName } catch {} }
    [ordered]@{
        acp              = $acp
        oemcp            = $oem
        acp_name         = $acpName
        beta_utf8_on     = ($acp -eq 65001)   # 「Beta: 使用 Unicode UTF-8」的标志
        console_output   = [Console]::OutputEncoding.WebName
        ps_default_enc   = $PSDefaultParameterValues['*:Encoding']
    }
}

# ── PF-05 长路径（SPEC §2.5）─────────────────────────────────────────────────
$R.long_paths = Probe 'long_paths' {
    $fs = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -ErrorAction SilentlyContinue
    $enabled = $false
    if ($fs -and ($fs.PSObject.Properties.Name -contains 'LongPathsEnabled')) {
        $enabled = ([int]$fs.LongPathsEnabled -eq 1)
    }
    [ordered]@{
        registry_enabled = $enabled
        # 注册表只是必要条件：还要 exe manifest 声明 longPathAware。
        # 本 SPEC 的姿态是「从源头压短路径」，这里只记录、不依赖。
        note = 'SPEC 不依赖长路径；预算按 248 = MAX_PATH-12 算（§2.5）'
    }
}

# ── PF-03/07/13 枢纽根与卷（SPEC §2.4、§2.9.5）───────────────────────────────
$R.hub = Probe 'hub' {
    $exists = Test-Path -LiteralPath $HubRoot
    $root   = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($HubRoot))
    $vol = $null
    try { $vol = Get-Volume -FilePath $HubRoot -ErrorAction Stop } catch {
        try { $vol = Get-Volume -DriveLetter $root.TrimEnd(':\') -ErrorAction Stop } catch {}
    }
    $free = $null; $size = $null
    try { $d = New-Object System.IO.DriveInfo($root); $free = $d.AvailableFreeSpace; $size = $d.TotalSize } catch {}

    $oneDrive = @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial) | Where-Object { $_ }
    $inOneDrive = $false
    foreach ($od in $oneDrive) { if (Test-PathUnder $HubRoot $od) { $inOneDrive = $true } }

    [ordered]@{
        path              = $HubRoot
        exists            = $exists
        volume_root       = $root
        filesystem        = if ($vol) { $vol.FileSystemType } else { $null }
        is_ntfs           = if ($vol) { $vol.FileSystemType -eq 'NTFS' } else { $null }
        free_bytes        = $free
        total_bytes       = $size
        free_gib          = if ($free) { [math]::Round($free / 1GB, 1) } else { $null }
        under_onedrive    = $inOneDrive
        under_programfiles = (Test-PathUnder $HubRoot $env:ProgramFiles) -or
                             (Test-PathUnder $HubRoot ${env:ProgramFiles(x86)})
        root_name_length  = $HubRoot.TrimEnd('\').Length
        # §2.5：games\ 那一段的固定前缀，决定解压期预算
        games_prefix_len  = ($HubRoot.TrimEnd('\') + '\games\').Length
    }
}

# ── PF-Defender（SPEC §6.9）──────────────────────────────────────────────────
$R.defender = Probe 'defender' {
    $mp = Get-CmdPath 'MpCmdRun.exe'
    if (-not $mp) {
        $c = "$env:ProgramData\Microsoft\Windows Defender\Platform"
        if (Test-Path -LiteralPath $c) {
            $latest = Get-ChildItem -LiteralPath $c -Directory -ErrorAction SilentlyContinue |
                      Sort-Object Name -Descending | Select-Object -First 1
            if ($latest -and (Test-Path -LiteralPath "$($latest.FullName)\MpCmdRun.exe")) {
                $mp = "$($latest.FullName)\MpCmdRun.exe"
            }
        }
    }
    $status = $null; $excl = $null
    try {
        $s = Get-MpComputerStatus -ErrorAction Stop
        $status = [ordered]@{
            realtime_enabled = $s.RealTimeProtectionEnabled
            antivirus_enabled = $s.AntivirusEnabled
            engine_version   = $s.AMEngineVersion
        }
    } catch {}
    try { $excl = @((Get-MpPreference -ErrorAction Stop).ExclusionPath) } catch {}
    [ordered]@{
        mpcmdrun_path  = $mp
        status         = $status
        exclusion_paths = $excl
        stg_excluded   = if ($excl) { [bool](@($excl) -contains ($HubRoot.TrimEnd('\') + '\_stg')) } else { $false }
        note = 'MpCmdRun 需提权运行（官方）；B 的计划任务要 -RunLevel Highest（§8.8.10）'
    }
}

# ── PF-Codex（SPEC §8）───────────────────────────────────────────────────────
$R.codex = Probe 'codex' {
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    [ordered]@{
        cli_path       = Get-CmdPath 'codex.exe'
        codex_home     = $codexHome
        config_exists  = Test-Path -LiteralPath (Join-Path $codexHome 'config.toml')
        # §11 #3：prefix_rule 对 PowerShell 的拆分语义 —— 只能用 execpolicy check 实测
        note = '§11 #2/#3 必须在 Codex 会话内实测，本脚本测不到（见输出末尾的待办）'
    }
}

# ── PF-MTool（SPEC §7.6）─────────────────────────────────────────────────────
$R.mtool = Probe 'mtool' {
    $paths = @()
    foreach ($base in @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)}, 'D:\', 'E:\')) {
        if (-not $base) { continue }
        try {
            $paths += Get-ChildItem -LiteralPath $base -Filter 'MTool*.exe' -Recurse -Depth 2 `
                        -File -ErrorAction SilentlyContinue | Select-Object -First 3 -ExpandProperty FullName
        } catch {}
    }
    $paths = @($paths | Select-Object -Unique)
    $sigs = @()
    foreach ($p in $paths) {
        try {
            $s = Get-AuthenticodeSignature -LiteralPath $p
            $sigs += [ordered]@{
                path    = $p
                status  = [string]$s.Status
                subject = if ($s.SignerCertificate) { $s.SignerCertificate.Subject } else { $null }
            }
        } catch {}
    }
    [ordered]@{
        found      = $paths
        signatures = $sigs
        note       = '签名状态决定 computer_use.windows.exes 规则能不能写（§11 #14）'
    }
}

# ── §11 #26 真实游戏包的最长内部条目路径 ──────────────────────────────────────
# 这条直接决定 MAX_PATH 预算够不够。没给样本就跳过，但会在摘要里催。
$R.internal_paths = Probe 'internal_paths' {
    if (-not $SampleGameDirs -or $SampleGameDirs.Count -eq 0) {
        return [ordered]@{ measured = $false; reason = '未提供 -SampleGameDirs' }
    }
    $per = @()
    foreach ($d in $SampleGameDirs) {
        if (-not (Test-Path -LiteralPath $d)) { $per += [ordered]@{ dir = $d; error = 'not found' }; continue }
        $base = [System.IO.Path]::GetFullPath($d).TrimEnd('\')
        $lens = @()
        Get-ChildItem -LiteralPath $d -Recurse -Force -File -ErrorAction SilentlyContinue |
            ForEach-Object { $lens += ($_.FullName.Length - $base.Length - 1) }
        if ($lens.Count -eq 0) { $per += [ordered]@{ dir = $d; files = 0 }; continue }
        $sorted = $lens | Sort-Object
        $per += [ordered]@{
            dir    = $d
            files  = $lens.Count
            max    = $sorted[-1]
            p95    = $sorted[[int][math]::Floor($sorted.Count * 0.95)]
            median = $sorted[[int][math]::Floor($sorted.Count * 0.50)]
        }
    }
    $all = @($per | Where-Object { $_.Contains('max') } | ForEach-Object { $_.max })
    [ordered]@{
        measured  = $true
        per_dir   = $per
        worst_E   = if ($all.Count) { ($all | Measure-Object -Maximum).Maximum } else { $null }
    }
}

# ── 判定（PASS / WARN / FAIL）─────────────────────────────────────────────────
# 本段一律用 Get-Val 取值，绝不直接 .属性 —— 任何探测项失败都只是少一条结论，
# 不会让整个 Preflight 崩掉。
$P  = $R.platform;         $A  = $R.archiver;    $W = $R.powershell
$EP = $R.execution_policy; $CP = $R.codepage;    $H = $R.hub
$DF = $R.defender;         $IP = $R.internal_paths

$findings = New-Object System.Collections.ArrayList
function Add-Finding {
    param([ValidateSet('PASS','WARN','FAIL')][string]$Level, [string]$Id, [string]$Text)
    [void]$findings.Add([ordered]@{ level = $Level; id = $Id; text = $Text })
}

if ((Get-Val $P 'is_windows' $false) -ne $true) {
    Add-Finding FAIL 'PF-00' '不是 Windows。本项目只在 Windows 上有意义'
}

$sz    = Get-Val $A 'sevenzip_path'
$szVer = Get-Val $A 'sevenzip_version'
if (-not $sz) {
    Add-Finding FAIL 'PF-01' '找不到 7z.exe。WinRAR/Bandizip 的 GUI 顶替不了——SPEC 的全部退出码判据都以 7-Zip 命令行为准（§6.2）。装 7-Zip 并把它加进 PATH'
} elseif ((Get-Val $A 'meets_hard_floor' $false) -ne $true) {
    Add-Finding FAIL 'PF-01' "7-Zip $szVer 低于硬下限 25.01（解析不可信归档的内存安全漏洞，D-17）"
} elseif ((Get-Val $A 'meets_recommended' $false) -ne $true) {
    Add-Finding WARN 'PF-01' "7-Zip $szVer 低于建议线 26.02。可运行，但报告顶部会长期提示（D-17）"
} else {
    Add-Finding PASS 'PF-01' "7-Zip $szVer"
}

$pwshVer = Get-Val $W 'pwsh_version'
if (-not (Get-Val $W 'pwsh_path')) {
    Add-Finding WARN 'PF-02' '没有 pwsh 7。脚本内部想用 7.x 语义就必须装；注意 Codex 那一层永远是 powershell.exe 5.1（§8.2.1）'
} elseif ((Get-Val $W 'pwsh_meets_74' $false) -ne $true) {
    Add-Finding WARN 'PF-02' "pwsh $pwshVer 低于 7.4"
} else {
    Add-Finding PASS 'PF-02' "pwsh $pwshVer"
}

$eff = Get-Val $EP 'effective' 'Unknown'
if ((Get-Val $EP 'locked_by_gpo' $false) -eq $true) {
    Add-Finding WARN 'PF-06' 'ExecutionPolicy 被 GPO 锁定，Set-ExecutionPolicy 会无效。逐进程用 -ExecutionPolicy Bypass（§8.4）'
} elseif (@('Restricted','AllSigned','Undefined') -contains $eff) {
    Add-Finding WARN 'PF-06' "ExecutionPolicy = $eff。Codex 生成的 .ps1 跑不起来，需 Set-ExecutionPolicy RemoteSigned（§8.4）"
} else {
    Add-Finding PASS 'PF-06' "ExecutionPolicy = $eff"
}

$acp = Get-Val $CP 'acp'
if ((Get-Val $CP 'beta_utf8_on' $false) -eq $true) {
    Add-Finding WARN 'PF-08' 'ACP = 65001（Beta UTF-8 已开）。dirname 的 ACP 往返检查会几乎全过，但老引擎读自己资源时的行为需实测（§3.2A）'
} elseif ($acp) {
    Add-Finding PASS 'PF-08' "ACP = $acp ($(Get-Val $CP 'acp_name' '?'))。SPEC 不断言它必须是 936，只把它作为解释失败的上下文"
} else {
    Add-Finding WARN 'PF-08' 'ACP 读不到。dirname 的 ACP 往返检查将无法判定，只能一律降级成 ASCII slug（§3.2A）'
}

$prefixLen = Get-Val $H 'games_prefix_len' 0
if ((Get-Val $H 'exists' $false) -ne $true) {
    Add-Finding WARN 'PF-03' "枢纽根 $HubRoot 不存在。建目录即可；卷必须是 NTFS"
} elseif ((Get-Val $H 'is_ntfs' $false) -ne $true) {
    Add-Finding FAIL 'PF-03' "枢纽卷不是 NTFS（$(Get-Val $H 'filesystem' '?')）。exFAT 上没有 Zone.Identifier 备用数据流，整套 MOTW 逻辑失效（§9.4）"
} else {
    Add-Finding PASS 'PF-03' "枢纽卷 NTFS，剩余 $(Get-Val $H 'free_gib' '?') GiB"
}
if ((Get-Val $H 'under_onedrive' $false) -eq $true) {
    Add-Finding FAIL 'PF-07' '枢纽根在 OneDrive 同步目录下。有社区证据表明会导致 MTool inject 失败（D-22）'
}
if ((Get-Val $H 'under_programfiles' $false) -eq $true) {
    Add-Finding FAIL 'PF-07' '枢纽根在 Program Files 下，写不进去（D-22）'
}
if ($prefixLen -gt 20) {
    Add-Finding WARN 'PF-03' "枢纽根偏长：<hub>\games\ 共 $prefixLen 字符（设计基准 17）。每多一个字符，内部路径预算就少一个（§2.5）"
}

if (-not (Get-Val $DF 'mpcmdrun_path')) {
    Add-Finding WARN 'PF-09' '找不到 MpCmdRun.exe。§6.9 的 Defender 预检实现不了，全部条目会按 C 级软停'
} elseif ((Get-Val $P 'is_admin' $false) -ne $true) {
    Add-Finding WARN 'PF-09' 'MpCmdRun 需提权运行（官方）。当前不是管理员——B 的计划任务要 -RunLevel Highest（§8.8.10）'
} else {
    Add-Finding PASS 'PF-09' 'MpCmdRun 可用且当前已提权'
}

$E = Get-Val $IP 'worst_E'
if ((Get-Val $IP 'measured' $false) -ne $true) {
    Add-Finding WARN 'PF-26' '未测量真实游戏包的最长内部路径（§11 #26）。重跑时加 -SampleGameDirs，这条决定目录名降级会不会频繁触发'
} elseif ($E -and $prefixLen -gt 0) {
    $maxN = 248 - $prefixLen - 1 - [int]$E
    if ($maxN -lt 20) {
        Add-Finding FAIL 'PF-26' "最长内部路径 E=$E，枢纽期只剩 $maxN 字符给游戏目录名。几乎必然强制降级成 ASCII slug——考虑把枢纽根改短（§2.5.3a）"
    } elseif ($maxN -lt 60) {
        Add-Finding WARN 'PF-26' "最长内部路径 E=$E，游戏目录名最多 $maxN 字符（上限 60）。长日文标题会被裁剪或降级"
    } else {
        Add-Finding PASS 'PF-26' "最长内部路径 E=$E，目录名预算充裕（可用 $maxN ≥ 60）"
    }
}

# 探测项本身失败的，单独列出来 —— 否则会被静默吞掉
foreach ($k in @($R.Keys)) {
    $v = $R[$k]
    if ((Get-Val $v 'probe_failed' $false) -eq $true) {
        Add-Finding WARN 'PROBE' "探测项 [$k] 失败：$(Get-Val $v 'error' '?')"
    }
}

$R.findings = @($findings)
$R.summary  = [ordered]@{
    pass = @($findings | Where-Object { $_.level -eq 'PASS' }).Count
    warn = @($findings | Where-Object { $_.level -eq 'WARN' }).Count
    fail = @($findings | Where-Object { $_.level -eq 'FAIL' }).Count
}
# 本脚本测不到、必须在 Codex 会话里做的两条（§11 #2/#3）
$R.manual_todo = @(
    '§11 #2  在 Codex 里开 project=D:\GameFlow，配 sandbox_workspace_write.writable_roots=["D:\\GameHub"]，让 agent 实际写一个文件，确认能写',
    '§11 #3  codex execpolicy check --rules <rules> -- powershell.exe -NoProfile -Command "& ''7z.exe'' t x.7z"  —— 看 prefix_rule 是整条匹配还是按子命令拆分'
)

# ── 输出 ─────────────────────────────────────────────────────────────────────
$json = $R | ConvertTo-Json -Depth 10        # -Depth 显式给，默认 2 会静默截断（§8.8.3）

if ($OutFile) {
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # UTF-8 无 BOM：5.1 的 -Encoding utf8 会带 BOM（§8.8.2）
    [System.IO.File]::WriteAllText(
        [System.IO.Path]::GetFullPath($OutFile), $json,
        (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "JSON 快照 → $OutFile"
}

# 空值显示成「(无)」而不是空白 —— 摘要里一列空白看不出是"没探到"还是"没打印"
function Show {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return '(无)' }
    return "$Value"
}

Write-Host ''
Write-Host '═══ GameFlow Preflight ═══════════════════════════════════════'
Write-Host ("  机器      : {0}  ({1})" -f (Show (Get-Val $P 'machine')), (Show (Get-Val $P 'caption')))
Write-Host ("  PowerShell: {0}    pwsh: {1}" -f (Show (Get-Val $W 'current_version')), (Show $pwshVer))
Write-Host ("  7-Zip     : {0}" -f (Show $szVer))
Write-Host ("  枢纽根    : {0}  [{1}]  剩余 {2} GiB" -f $HubRoot, (Show (Get-Val $H 'filesystem')), (Show (Get-Val $H 'free_gib')))
Write-Host ("  ACP       : {0}" -f (Show $acp))
Write-Host '──────────────────────────────────────────────────────────────'
foreach ($f in $findings) {
    $color = 'Green'
    if     ($f.level -eq 'FAIL') { $color = 'Red' }
    elseif ($f.level -eq 'WARN') { $color = 'Yellow' }
    Write-Host ("  [{0}] {1}  {2}" -f $f.level, $f.id, $f.text) -ForegroundColor $color
}
Write-Host '──────────────────────────────────────────────────────────────'
Write-Host ("  PASS {0}   WARN {1}   FAIL {2}" -f $R.summary.pass, $R.summary.warn, $R.summary.fail)
Write-Host ''
Write-Host '  本脚本测不到、必须在 Codex 会话里做的：' -ForegroundColor Cyan
foreach ($t in $R.manual_todo) { Write-Host ("    . {0}" -f $t) -ForegroundColor Cyan }
Write-Host '══════════════════════════════════════════════════════════════'

# 退出码：0 = 无 FAIL；3 = 有 FAIL（前置条件不满足，§8.2.3）
if ($R.summary.fail -gt 0) { exit 3 } else { exit 0 }
