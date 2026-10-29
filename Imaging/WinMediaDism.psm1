Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# DISM Cmdlet 來源分派模組（§3.4）：Inbox 內建模組或 ADK 的 Dism.psd1
# 需要的 Config 鍵：DismProvider（Inbox／ADK）、AdkRoot（ADK 時）、DismUseWindowsPowerShell（pwsh 7 時）、DebugTrace、LogDir（DebugTrace ≥ 3 時的追蹤檔）、OperationLog、DismLogLevel（缺鍵時用預設）
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Common\WinMediaLog.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Common\WinMediaOperation.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinMediaAdk.psm1') -Force

# 本工作階段由相容匯入載入的來源（'DISM' 或 ADK 的 Dism.psd1 路徑）；$null = 尚未匯入
# 存 $global：多個模組以 -Force 重新匯入本模組，$script: 狀態會被重設
function Initialize-WinMediaDismCompatState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = '跨 -Force 重新匯入保留相容狀態，見檔頭註解')]
    [CmdletBinding()]
    param()

    if (-not (Get-Variable -Name WinMediaDismCompatSource -Scope Global -ErrorAction SilentlyContinue)) { $global:WinMediaDismCompatSource = $null }
}
Initialize-WinMediaDismCompatState

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

function Resolve-WinMediaDismUseWindowsPowerShell {
    # pwsh 7 下是否以 Windows PowerShell 5.1 相容模式載入 DISM；舊設定檔沒有此鍵時預設開啟
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$Config)

    if ($Config.ContainsKey('DismUseWindowsPowerShell')) { return [bool]$Config.DismUseWindowsPowerShell }
    return $true
}

function Test-WinMediaDismCore {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return ($PSVersionTable.PSEdition -eq 'Core')
}

function Get-WinMediaDismLoaded {
    # 目前工作階段已載入的 Dism 模組（無則 $null）；獨立成函式方便 Pester Mock
    [CmdletBinding()]
    param()

    return Get-Module -Name Dism
}

function Remove-WinMediaDismLoaded {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $PSCmdlet.ShouldProcess('Dism', '移除原生自動載入的 Dism 模組')) { return }
    Remove-Module -Name Dism -Force
}

function Import-WinMediaDismCompat {
    # pwsh 7 以 Windows PowerShell 5.1 相容模式匯入（會經由 5.1 程序代理）；需在 $env:TEMP 設好之後呼叫
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Source
    )

    # 已知警告（WinPSCompatSession 還原序列化提示）收進日誌，不以警告串流顯示
    $null = Import-Module -Name $Source -Verbose -Global -PassThru -UseWindowsPowerShell -WarningAction SilentlyContinue -WarningVariable compatWarning
    foreach ($w in @($compatWarning)) { if ("$w" -like '*WinPSCompatSession*') { Write-WinMediaLog -Config $Config -Level Info -Message "已知（pwsh 7 相容匯入）：$w" } else { Write-Warning "$w" } }
    Write-WinMediaLog -Config $Config -Level Info -Message "pwsh 7：DISM 已以 Windows PowerShell 5.1 相容模式匯入（Import-Module -Name '$Source' -UseWindowsPowerShell）。"
}

function Test-WinMediaDismHost {
    # 開工前檢查（Inbox 與 ADK 相同）：pwsh 7 下若 DismUseWindowsPowerShell 為關閉，中止並指出設定鍵
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Inbox', 'ADK')][string]$Provider,
        [Parameter(Mandatory)][hashtable]$Config
    )

    if (-not (Test-WinMediaDismCore)) { return }
    if (-not (Resolve-WinMediaDismUseWindowsPowerShell -Config $Config)) {
        throw "DISM Cmdlet（DismProvider=$Provider）必須在 Windows PowerShell 5.1 執行。目前為 PowerShell 7：請改用 powershell.exe 執行，或將設定 DismUseWindowsPowerShell 設為 `$true（以 Import-Module -UseWindowsPowerShell 相容模式載入）。"
    }
}

function Initialize-WinMediaDismCompat {
    # pwsh 7 的「先檢查、沒有就匯入」：只認自己匯入過的來源；原生自動載入的先移除再匯入；本工作階段中途換來源則擲例外
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = '跨 -Force 重新匯入保留相容狀態，見檔頭註解')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Inbox', 'ADK')][string]$Provider,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][hashtable]$Config
    )

    Test-WinMediaDismHost -Provider $Provider -Config $Config
    if ($global:WinMediaDismCompatSource -eq $Source) { return }
    if ($global:WinMediaDismCompatSource) {
        throw "本工作階段已以 '$($global:WinMediaDismCompatSource)' 載入 DISM，不能中途改用 '$Source'；請重新開啟工作階段後再執行（§3.4.2 2e）。"
    }
    if (Get-WinMediaDismLoaded) {
        Write-WinMediaLog -Config $Config -Level Info -Message 'pwsh 7：偵測到原生自動載入的 Dism，改以相容模式重新匯入。'
        $null = Remove-WinMediaDismLoaded -WhatIf:$false
    }
    $null = Import-WinMediaDismCompat -Config $Config -Source $Source
    $global:WinMediaDismCompatSource = $Source
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
            # Windows PowerShell 5.1 的內建 Dism 模組自動載入；pwsh 7 先檢查、沒有就以相容模式匯入
            if (Test-WinMediaDismCore) {
                $null = Initialize-WinMediaDismCompat -Provider 'Inbox' -Source 'DISM' -Config $Config
            }
            else {
                # 同一工作階段若已載入 ADK 的 Dism，Inbox 的 cmdlet 會實際跑 ADK；拒絕，而不是靜默沿用
                $loaded = @(Get-Module -Name Dism)
                $sysRoot = $env:SystemRoot + '\'
                if ($loaded | Where-Object { -not $_.Path.StartsWith($sysRoot, [StringComparison]::OrdinalIgnoreCase) }) {
                    throw "Dism 模組已從非 Inbox 路徑載入（$($loaded[0].Path)），Inbox 不能沿用；請重新開啟工作階段後再執行（§3.4.2 2e）。"
                }
            }
        }
        'ADK' {
            $adk = Resolve-WinMediaAdk -Config $Config
            if (Test-WinMediaDismCore) {
                $null = Initialize-WinMediaDismCompat -Provider 'ADK' -Source $adk.ModulePath -Config $Config
            }
            else {
                $loaded = Get-Module -Name Dism
                if ($loaded -and $loaded.Path -ne $adk.ModulePath) {
                    throw "Dism 模組已從 '$($loaded.Path)' 載入，與 ADK 路徑不同；請重新開啟工作階段後再執行（§3.4.2 2e）。"
                }
                if (-not $loaded) {
                    Import-Module -Name $adk.ModulePath -ErrorAction Stop
                }
            }
        }
    }

    # 操作紀錄的 operation 欄位取第一個命令名稱（例如 Mount-WindowsImage）；取不到時退回分派來源
    $command = $ScriptBlock.Ast.Find({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
    $operation = if ($command -and $command.GetCommandName()) { $command.GetCommandName() } else { $Provider }

    $wrapped = $ScriptBlock
    if ([int]$Config.DebugTrace -ge 3) {
        $tracePath = Join-Path -Path $Config.LogDir -ChildPath ('trace-dism-{0}.log' -f (Get-Date -Format 'HHmmssfff'))
        $inner = $ScriptBlock
        $wrapped = {
            Trace-Command -Name ParameterBinding, CommandDiscovery -Expression $inner -PSHost -FilePath $tracePath
        }.GetNewClosure()
    }

    return Invoke-WinMediaOperation -Category Dism -Operation $operation -Target "DISM[$Provider]" -ScriptBlock $wrapped -Config $Config
}

Export-ModuleMember -Function Invoke-WinMediaDism, Resolve-WinMediaDismLogLevel, Resolve-WinMediaDismUseWindowsPowerShell, Test-WinMediaDismHost
