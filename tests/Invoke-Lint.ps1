<#
.SYNOPSIS
    GameFlow 静态检查：解析 + 5.1 兼容性 + BOM。

.DESCRIPTION
    本项目在 macOS 上开发、在 Windows 上运行，绝大多数代码无法在开发机执行。
    这个脚本是「能在开发机做的全部验证」，每写完一个模块都要跑。

    三类检查：

      1. 解析        —— 用真正的 PowerShell 解析器，抓语法错
      2. 5.1 兼容性  —— PSUseCompatibleSyntax，抓「PS7 能跑、5.1 跑不了」的写法
                        （Codex 的 Windows agent 调的是 powershell.exe 5.1，§8.2.1）
      3. BOM         —— 含非 ASCII 的 .ps1 **必须**带 UTF-8 BOM

    第 3 条最容易被忽略，也最坑：**Windows PowerShell 5.1 把无 BOM 的 .ps1
    按系统 ANSI 解码**。在 ACP=936 的机器上，源码里的中文字符串会变成乱码，
    而且是「脚本照跑、只是输出全乱」这种最难察觉的形态。

    注意这与 §8.8.2「数据文件写 UTF-8 无 BOM」**不矛盾**，两者是不同的东西：

      源码 .ps1  →  UTF-8 **带** BOM（给 5.1 的解析器看）
      数据文件   →  UTF-8 **无** BOM（JSON / JSONL，给别的程序看）

.EXAMPLE
    pwsh -NoProfile -File tests/Invoke-Lint.ps1
.EXAMPLE
    pwsh -NoProfile -File tests/Invoke-Lint.ps1 -Path scripts/lib
#>
[CmdletBinding()]
param(
    [string] $Path = '.',
    [switch] $FixBom     # 自动补 BOM，而不是只报告
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$target = Join-Path $repo $Path
$files = @(Get-ChildItem -LiteralPath $target -Filter '*.ps1' -Recurse -File |
           Sort-Object FullName)

if (-not $files) { Write-Host "没找到 .ps1"; exit 0 }

$fail = 0
$warn = 0

Write-Host ''
Write-Host '═══ GameFlow Lint ════════════════════════════════════════════'

foreach ($f in $files) {
    $rel = $f.FullName.Substring($repo.Length + 1)
    $issues = New-Object System.Collections.ArrayList

    # ── 1. BOM ────────────────────────────────────────────────────────────
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.IO.File]::ReadAllText($f.FullName)
    $nonAscii = 0
    foreach ($ch in $text.ToCharArray()) { if ([int]$ch -gt 127) { $nonAscii++ } }

    if ($nonAscii -gt 0 -and -not $hasBom) {
        if ($FixBom) {
            $utf8Bom = New-Object System.Text.UTF8Encoding($true)
            [System.IO.File]::WriteAllText($f.FullName, $text, $utf8Bom)
            [void]$issues.Add(@{ lvl='FIXED'; msg="补上 UTF-8 BOM（含 $nonAscii 个非 ASCII 字符）" })
        } else {
            [void]$issues.Add(@{ lvl='FAIL'; msg="含 $nonAscii 个非 ASCII 字符但**无 BOM**。5.1 会按 ANSI 解码 → 中文全乱码。加 -FixBom 自动修" })
        }
    }

    # ── 2. 解析 ───────────────────────────────────────────────────────────
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
    foreach ($e in @($errs)) {
        [void]$issues.Add(@{ lvl='FAIL'; msg=("解析错误 行{0}:{1}  {2}" -f $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message) })
    }

    # ── 3. 5.1 兼容性 ─────────────────────────────────────────────────────
    if (Get-Module -ListAvailable PSScriptAnalyzer) {
        Import-Module PSScriptAnalyzer -ErrorAction SilentlyContinue
        # 必须给 IncludeRules —— 只在 Rules 里配某条规则**不会**限制只跑它，
        # 默认规则仍会全跑，于是 Write-Host 之类会被误标成「5.1 不兼容」。
        $settings = @{
            IncludeRules = @('PSUseCompatibleSyntax')
            Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1','7.0') } }
        }
        foreach ($d in @(Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings -ErrorAction SilentlyContinue)) {
            [void]$issues.Add(@{ lvl='FAIL'; msg=("5.1 不兼容 行{0}  {1}" -f $d.Line, $d.Message) })
        }
        # 只取真正危险的通用规则；风格类（位置参数、空 catch）本项目刻意允许
        $keep = @('PSAvoidUsingInvokeExpression','PSAvoidUsingPlainTextForPassword',
                  'PSAvoidUsingConvertToSecureStringWithPlainText','PSUseDeclaredVarsMoreThanAssignments',
                  'PSAvoidGlobalVars','PSPossibleIncorrectComparisonWithNull','PSAvoidUsingCmdletAliases')
        foreach ($d in @(Invoke-ScriptAnalyzer -Path $f.FullName -ErrorAction SilentlyContinue |
                         Where-Object { $keep -contains $_.RuleName })) {
            [void]$issues.Add(@{ lvl='WARN'; msg=("{0} 行{1}  {2}" -f $d.RuleName, $d.Line, $d.Message) })
        }
    }

    # ── 输出 ──────────────────────────────────────────────────────────────
    $f_ = @($issues | Where-Object { $_.lvl -eq 'FAIL' }).Count
    $w_ = @($issues | Where-Object { $_.lvl -eq 'WARN' }).Count
    $fail += $f_; $warn += $w_

    if ($issues.Count -eq 0) {
        Write-Host ("  ✅ {0}" -f $rel) -ForegroundColor Green
    } else {
        $c = 'Yellow'; if ($f_ -gt 0) { $c = 'Red' }
        Write-Host ("  {0} {1}" -f $(if ($f_ -gt 0) { '❌' } else { '⚠️ ' }), $rel) -ForegroundColor $c
        foreach ($i in $issues) {
            $ic = 'Yellow'
            if ($i.lvl -eq 'FAIL')  { $ic = 'Red' }
            if ($i.lvl -eq 'FIXED') { $ic = 'Cyan' }
            Write-Host ("       [{0}] {1}" -f $i.lvl, $i.msg) -ForegroundColor $ic
        }
    }
}

Write-Host '──────────────────────────────────────────────────────────────'
Write-Host ("  {0} 个文件   FAIL {1}   WARN {2}" -f $files.Count, $fail, $warn)
if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Write-Host '  ⚠️  PSScriptAnalyzer 未安装，跳过了 5.1 兼容性检查' -ForegroundColor Yellow
    Write-Host '     Install-Module PSScriptAnalyzer -Scope CurrentUser' -ForegroundColor Yellow
}
Write-Host '══════════════════════════════════════════════════════════════'

if ($fail -gt 0) { exit 1 } else { exit 0 }
