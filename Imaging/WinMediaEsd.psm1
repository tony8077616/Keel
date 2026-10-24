Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ESD ↔ WIM 轉換模組（§2.4、§3.2 步驟 2a）
# 需要的 Config 鍵：Wimlib.Path（有指定才走 wimlib）、DismProvider、DismLogLevel、WorkDir／LogLevel／LogFile、DebugTrace、OperationLog
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Common\WinMediaLog.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Common\WinMediaOperation.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinMediaDism.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinMediaWimlib.psm1') -Force

function Convert-WinMediaEsdToWim {
    # install.esd → install.wim（§3.2 步驟 2a、§2.7.3）：全部索引轉換；Config.Wimlib.Path 有指定才走 wimlib，否則走 DISM
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceEsd,
        [Parameter(Mandatory)][string]$DestinationWim,
        [Parameter(Mandatory)][hashtable]$Config
    )

    if (Test-Path -LiteralPath $DestinationWim) {
        Invoke-WinMediaOperation -Category File -Operation 'Remove' -Target $DestinationWim -Config $Config -ScriptBlock {
            Remove-Item -LiteralPath $DestinationWim -Force
        } | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($Config.Wimlib.Path)) {
        Write-WinMediaLog -Config $Config -Level Info -Message "使用 wimlib-imagex 轉換 ESD（Wimlib.Path 已指定）：$SourceEsd"
        Invoke-WinMediaWimlib -ArgumentList @('export', $SourceEsd, 'all', $DestinationWim) -Config $Config | Out-Null
    }
    else {
        Write-WinMediaLog -Config $Config -Level Info -Message "使用 DISM Cmdlet 轉換 ESD（未指定 Wimlib.Path）：$SourceEsd"
        $indexes = Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Get-WindowsImage -ImagePath $SourceEsd -LogLevel $Config.DismLogLevel
        }
        foreach ($image in $indexes) {
            $exportIndex = $image.ImageIndex
            $export = {
                Export-WindowsImage -SourceImagePath $SourceEsd -SourceIndex $exportIndex -DestinationImagePath $DestinationWim -CompressionType Max -LogLevel $Config.DismLogLevel | Out-Null
            }.GetNewClosure()
            Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock $export | Out-Null
        }
    }

    if (-not (Test-Path -LiteralPath $DestinationWim)) {
        throw "ESD 轉換後找不到輸出檔：$DestinationWim"
    }
    Invoke-WinMediaOperation -Category File -Operation 'Remove' -Target $SourceEsd -Config $Config -ScriptBlock {
        Remove-Item -LiteralPath $SourceEsd -Force
    } | Out-Null
}

function Export-WinMediaEsd {
    <#
    .SYNOPSIS
        以 wimlib-imagex 將 install.wim 轉為 LZMS 壓縮的 install.esd（§2.4）。
    .DESCRIPTION
        wimlib 未設定或找不到時自動下載固定版本（見 Resolve-WinMediaWimlib）；不退回 DISM（Learn 未記載 DISM 直接產生 ESD，§2.4、§7 第 9 項）。
        成功後移除來源 install.wim。
    .PARAMETER SourceWim
        來源 install.wim 路徑。
    .PARAMETER DestinationEsd
        輸出 install.esd 路徑。
    .PARAMETER Config
        由 Import-PowerShellDataFile 載入並補上執行期鍵值的設定表。
    .EXAMPLE
        Export-WinMediaEsd -SourceWim '<WorkDir>\media\sources\install.wim' -DestinationEsd '<WorkDir>\media\sources\install.esd' -Config $config
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceWim,
        [Parameter(Mandatory)][string]$DestinationEsd,
        [Parameter(Mandatory)][hashtable]$Config
    )

    # wimlib export 對既有檔案是附加映像而非覆寫，須先移除（與 Convert-WinMediaEsdToWim 相同）
    if (Test-Path -LiteralPath $DestinationEsd) {
        Invoke-WinMediaOperation -Category File -Operation 'Remove' -Target $DestinationEsd -Config $Config -ScriptBlock {
            Remove-Item -LiteralPath $DestinationEsd -Force
        } | Out-Null
    }

    Invoke-WinMediaWimlib -ArgumentList @('export', $SourceWim, 'all', $DestinationEsd, '--compress=LZMS', '--solid') -Config $Config | Out-Null

    Invoke-WinMediaOperation -Category File -Operation 'Remove' -Target $SourceWim -Config $Config -ScriptBlock {
        Remove-Item -LiteralPath $SourceWim -Force
    } | Out-Null
}

Export-ModuleMember -Function Convert-WinMediaEsdToWim, Export-WinMediaEsd
