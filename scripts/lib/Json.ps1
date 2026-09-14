<#
    GameFlow · Json.ps1 —— JSON 序列化（SPEC §8.8.3）

    存在的唯一理由：**裸 ConvertTo-Json 的默认 -Depth 是 2**，而本项目的批次清单
    items[].extraction.extension_rule 已经是第 4 层。5.1 下超深度是**静默截断**，
    不报错、不告警 —— 于是 extraction / translation 整块配置会在「看起来跑通了」
    的情况下消失。

    所以全项目禁止裸调用 ConvertTo-Json，一律走本模块。
#>

if (-not $script:GfIoLoaded) { . "$PSScriptRoot\Io.ps1"; $script:GfIoLoaded = $true }

$script:GfJsonDepth = 10

function ConvertTo-GfJson {
    <# 永远显式 -Depth。-Compress 用于 JSONL（一行一条）。 #>
    param(
        [Parameter(Mandatory)][AllowNull()]$InputObject,
        [switch]$Compress
    )
    return ($InputObject | ConvertTo-Json -Depth $script:GfJsonDepth -Compress:$Compress)
}

function ConvertFrom-GfJson {
    <#
        安全解析：解析失败返回 $null 而不抛。
        events.jsonl 的读取端需要「这一行能不能解析」这个布尔，而不是异常控制流
        —— 尾行撕裂是**正常情况**（§3.3.5），不该走 catch。
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    try { return ($Json | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Read-GfJsonFile {
    <# 读 + 解析。文件不存在或解析失败都返回 $null（调用方用 Test-Path 区分）。 #>
    param([Parameter(Mandatory)][string]$LiteralPath)
    $t = Read-GfText -LiteralPath $LiteralPath
    if ($null -eq $t) { return $null }
    return ConvertFrom-GfJson -Json $t
}

function Write-GfJsonFile {
    <#
        写 JSON，走 §3.9.2 的可恢复落盘协议，**并回读校验**。
        回读不是洁癖：-Depth 静默截断、编码写错、磁盘写满，三者都表现为
        「写入调用成功返回、内容却不对」。写后回读是唯一能当场发现的手段。
    #>
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][AllowNull()]$InputObject
    )
    $json = ConvertTo-GfJson -InputObject $InputObject
    Write-GfTextAtomic -LiteralPath $LiteralPath -Text $json
    $back = Read-GfJsonFile -LiteralPath $LiteralPath
    if ($null -eq $back) { throw "写后回读失败，文件可能被截断或编码写错：$LiteralPath" }
    return $back
}
