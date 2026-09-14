<#
    跑全部单元测试。每个 *.Tests.ps1 在独立子进程里跑，互不污染。
    退出码：0 = 全绿。
#>
[CmdletBinding()] param()
$files = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File | Sort-Object Name)
$bad = 0
foreach ($f in $files) {
    & (Get-Process -Id $PID).Path -NoProfile -File $f.FullName
    if ($LASTEXITCODE -ne 0) { $bad++ }
}
Write-Host ''
if ($bad -gt 0) { Write-Host ("$bad / $($files.Count) 个测试文件有失败") -ForegroundColor Red; exit 1 }
Write-Host ("全部 $($files.Count) 个测试文件通过") -ForegroundColor Green
exit 0
