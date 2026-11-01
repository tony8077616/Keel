Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# DISM Optimize-WindowsImage 包裝（計畫步驟 4）；不包裝 AppX 的 Optimize-* Cmdlet
# 需要的 Config 鍵：DismProvider、DismLogLevel、ScratchDirectory（選用）、DebugTrace、LogDir、OperationLog
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Common\WinMediaLog.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinMediaDism.psm1') -Force

function Optimize-WinMediaImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        # shortcut: 文件只列 WIMBoot，故不加 ValidateSet、原樣傳給 DISM；在 5.1 驗證其他值後再升級
        [Parameter(Mandatory)][string]$OptimizationTarget,
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$WindowsDirectory,
        [string]$SystemDrive
    )

    Write-WinMediaLog -Config $Config -Level Verbose -Message "最佳化映像 $Path（OptimizationTarget=$OptimizationTarget）"
    # 只在選項有設定時才加鍵，未設定時行為與不傳相同
    $splat = Get-WinMediaDismCommonParameter -Config $Config
    if ($PSBoundParameters.ContainsKey('WindowsDirectory')) { $splat.WindowsDirectory = $WindowsDirectory }
    if ($PSBoundParameters.ContainsKey('SystemDrive')) { $splat.SystemDrive = $SystemDrive }
    $logLevel = Resolve-WinMediaDismLogLevel -Config $Config

    Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
        Optimize-WindowsImage -Path $Path -OptimizationTarget $OptimizationTarget -LogLevel $logLevel @splat | Out-Null
    }
}

Export-ModuleMember -Function Optimize-WinMediaImage
