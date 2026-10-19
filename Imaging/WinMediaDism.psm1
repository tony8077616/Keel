Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# DISM Cmdlet 來源分派模組（§3.4）：Inbox 內建模組或 ADK 的 Dism.psd1
# 需要的 Config 鍵：DismProvider（Inbox／ADK）、AdkRoot（ADK 時）、DebugTrace、LogDir（DebugTrace ≥ 3 時的追蹤檔）、OperationLog、DismLogLevel（缺鍵時用預設）
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Common\WinMediaOperation.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinMediaAdk.psm1') -Force

function Resolve-WinMediaDismLogLevel {
    # DISM Cmdlet 的 -LogLevel 值（名稱，不是數字）；舊設定檔沒有此鍵時用產品預設
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Config)

    $level = if ($Config.ContainsKey('DismLogLevel')) { $Config.DismLogLevel } else { 'WarningsInfo' }
    if ('Errors', 'Warnings', 'WarningsInfo', 'Debug' -notcontains $level) {
        throw "DismLogLevel 必須為 Errors／Warnings／WarningsInfo／Debug 其中之一（名稱，不是數字），目前為：'$level'。"
    }
    return $level
}

function Invoke-WinMediaDism {
    # DISM 來源分派（§3.4）：只呼叫 DISM Cmdlet（§3.4.3），不直接呼叫 dism.exe
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Inbox', 'ADK')][string]$Provider,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory)][hashtable]$Config
    )

    # 回寫到呼叫端同一個 hashtable：ScriptBlock 讀的 $Config 與呼叫端是同一份，所以缺鍵的舊設定也能讀到預設值
    $Config.DismLogLevel = Resolve-WinMediaDismLogLevel -Config $Config

    switch ($Provider) {
        'Inbox' {
            # 內建 Dism 模組於 Windows 11 自動載入，不需匯入
        }
        'ADK' {
            $adk = Resolve-WinMediaAdk -Config $Config
            $loaded = Get-Module -Name Dism
            if ($loaded -and $loaded.Path -ne $adk.ModulePath) {
                throw "Dism 模組已從 '$($loaded.Path)' 載入，與 ADK 路徑不同；請重新開啟工作階段後再執行（§3.4.2 2e）。"
            }
            if (-not $loaded) {
                Import-Module -Name $adk.ModulePath -ErrorAction Stop
            }
        }
    }

    $wrapped = $ScriptBlock
    if ([int]$Config.DebugTrace -ge 3) {
        $tracePath = Join-Path -Path $Config.LogDir -ChildPath ('trace-dism-{0}.log' -f (Get-Date -Format 'HHmmssfff'))
        $inner = $ScriptBlock
        $wrapped = {
            Trace-Command -Name ParameterBinding, CommandDiscovery -Expression $inner -PSHost -FilePath $tracePath
        }.GetNewClosure()
    }

    return Invoke-WinMediaOperation -Category Dism -Operation $Provider -Target "DISM[$Provider]" -ScriptBlock $wrapped -Config $Config
}

Export-ModuleMember -Function Invoke-WinMediaDism, Resolve-WinMediaDismLogLevel
