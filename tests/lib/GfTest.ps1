<#
    GameFlow · 极简测试 harness（零依赖）

    为什么不用 Pester：Windows 10/11 **预装的是 Pester 3.4.0**，与 Pester 5 的
    语法不兼容，而 `Import-Module Pester` 默认会加载那个 3.4.0（SPEC §8.8.12）。
    要么在目标机上钉版本装 Pester 5（多一个依赖、多一条「装没装对」的失败路径），
    要么自己写 60 行。本项目选后者 —— 它在 5.1 与 7.x 上行为完全一致。

    用法：
        . "$PSScriptRoot\lib\GfTest.ps1"
        Test-Case '标题说明' { Assert-Equal '期望' '实际' }
        exit (Invoke-GfTestSummary)
#>

$script:GfTests  = New-Object System.Collections.ArrayList
$script:GfCurrent = $null

function Test-Case {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    $script:GfCurrent = [ordered]@{ name = $Name; ok = $true; msgs = New-Object System.Collections.ArrayList }
    try { & $Body }
    catch {
        $script:GfCurrent.ok = $false
        [void]$script:GfCurrent.msgs.Add("抛异常: $($_.Exception.Message)")
    }
    [void]$script:GfTests.Add($script:GfCurrent)
    $script:GfCurrent = $null
}

function script:Fail { param([string]$Msg)
    if ($null -ne $script:GfCurrent) {
        $script:GfCurrent.ok = $false
        [void]$script:GfCurrent.msgs.Add($Msg)
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    # 字符串走 Ordinal —— 本项目大量处理大小写与 Unicode 形态敏感的字符串，
    # 文化敏感比较会把「ネコぱら」与「ネコパラ」之类的差异吞掉。
    #
    # **非字符串不得字符串化后再比**：PowerShell 7 保留数值字面量的原形，
    # `"$(0x0A)"` 给出 "0x0A" 而不是 "10"，与 [byte]10 的 "10" 比会误报。
    # 这条本身就是被一次误报抓出来的。
    $ok = $false
    if ($null -eq $Expected -and $null -eq $Actual) { $ok = $true }
    elseif ($null -eq $Expected -or $null -eq $Actual) { $ok = $false }
    elseif ($Expected -is [string] -and $Actual -is [string]) {
        $ok = [string]::Equals($Expected, $Actual, [System.StringComparison]::Ordinal)
    } else {
        $ok = ($Expected -eq $Actual)        # 数值/布尔按值比，跨类型（Int32 vs Byte）也成立
    }
    if (-not $ok) {
        $e = if ($null -eq $Expected) { '<null>' } else { '{0} ({1})' -f $Expected, $Expected.GetType().Name }
        $a = if ($null -eq $Actual)   { '<null>' } else { '{0} ({1})' -f $Actual,   $Actual.GetType().Name }
        Fail ("期望 [{0}] 实际 [{1}] {2}" -f $e, $a, $Because)
    }
}

function Assert-True  { param($Cond, [string]$Because='') if (-not $Cond) { Fail "期望为真但为假 $Because" } }
function Assert-False { param($Cond, [string]$Because='') if ($Cond)      { Fail "期望为假但为真 $Because" } }

function Assert-Match {
    param([string]$Pattern, [string]$Actual, [string]$Because='')
    if ($Actual -notmatch $Pattern) { Fail ("[{0}] 不匹配 /{1}/ {2}" -f $Actual, $Pattern, $Because) }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Because='')
    $threw = $false
    try { & $Body } catch { $threw = $true }
    if (-not $threw) { Fail "期望抛异常但没抛 $Because" }
}

function Invoke-GfTestSummary {
    param([string]$Title = '')
    $pass = @($script:GfTests | Where-Object { $_.ok }).Count
    $fail = @($script:GfTests | Where-Object { -not $_.ok }).Count
    Write-Host ''
    if ($Title) { Write-Host ("── {0} " -f $Title) -NoNewline; Write-Host ('─' * [Math]::Max(0, 58 - $Title.Length)) }
    foreach ($t in $script:GfTests) {
        if ($t.ok) {
            Write-Host ("  PASS  {0}" -f $t.name) -ForegroundColor Green
        } else {
            Write-Host ("  FAIL  {0}" -f $t.name) -ForegroundColor Red
            foreach ($m in $t.msgs) { Write-Host ("          {0}" -f $m) -ForegroundColor Red }
        }
    }
    Write-Host ('─' * 60)
    $color = 'Green'; if ($fail -gt 0) { $color = 'Red' }
    Write-Host ("  {0} 项：PASS {1}   FAIL {2}" -f $script:GfTests.Count, $pass, $fail) -ForegroundColor $color
    Write-Host ''
    if ($fail -gt 0) { return 1 } else { return 0 }
}
