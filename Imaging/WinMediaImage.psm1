Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# 映像掛載包裝模組（§3.3）：try/finally 保證卸載；成功才 Save，其餘一律 Discard
# 需要的 Config 鍵：DismProvider、DismLogLevel、DebugTrace、LogDir、OperationLog、LogLevel／LogFile
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Common\WinMediaLog.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinMediaDism.psm1') -Force

function Mount-WinMediaImage {
    # 掛載包裝（§3.3）：try/finally 保證卸載；成功才 -Save，其餘一律 -Discard
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$MountPath,
        [switch]$ReadOnly,
        [bool]$CommitOnSuccess = $true,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][hashtable]$Config
    )

    Write-WinMediaLog -Config $Config -Level Verbose -Message "掛載 $ImagePath 索引 $Index → $MountPath（ReadOnly=$ReadOnly）"
    # DISM 要求掛載點目錄已存在（否則回報「系統找不到指定的檔案」）；主流程只建立 MountDir 本身，子目錄由此補建
    $createdMountDir = -not (Test-Path -LiteralPath $MountPath)
    if ($createdMountDir) { New-Item -ItemType Directory -Path $MountPath -Force | Out-Null }
    try {
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Mount-WindowsImage -ImagePath $ImagePath -Index $Index -Path $MountPath -ReadOnly:$ReadOnly -LogLevel $Config.DismLogLevel | Out-Null
        }
    }
    catch {
        Remove-WinMediaEmptyMountPoint -Path $MountPath -Created $createdMountDir -Config $Config
        throw
    }

    $succeeded = $false
    $save = $false
    try {
        $result = & $Action $MountPath
        $succeeded = $true
        return $result
    }
    finally {
        $save = $succeeded -and $CommitOnSuccess -and (-not $ReadOnly)
        try {
            Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                if ($save) {
                    Dismount-WindowsImage -Path $MountPath -Save -LogLevel $Config.DismLogLevel | Out-Null
                }
                else {
                    Dismount-WindowsImage -Path $MountPath -Discard -LogLevel $Config.DismLogLevel | Out-Null
                }
            }
            # 只在卸載成功（上一行未拋出）後移除；未卸載的掛載點可能仍被占用，不得刪除
            Remove-WinMediaEmptyMountPoint -Path $MountPath -Created $createdMountDir -Config $Config
        }
        catch {
            # 動作已失敗時，保留原始例外，卸載錯誤只記錄；動作成功時卸載失敗必須拋出（Save 失敗等於映像沒寫入）
            if ($succeeded) { throw }
            Write-WinMediaLog -Config $Config -Level Warning -Message "動作失敗後卸載 $MountPath 也失敗（保留原始錯誤）：$($_.Exception.Message)"
        }
    }
}

function Remove-WinMediaEmptyMountPoint {
    # 移除由本次建立且已空的掛載點，避免殘留空目錄使下次執行在 MountDir 非空檢查中止；失敗只記錄警告，不取代操作本身的結果
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][bool]$Created, [Parameter(Mandatory)][hashtable]$Config)
    if (-not $Created) { return }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $remaining = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
        if ($remaining.Count -gt 0) {
            Write-WinMediaLog -Config $Config -Level Warning -Message "掛載點 $Path 非空（剩餘 $($remaining.Count) 項），略過自動移除"
            return
        }
        if ($PSCmdlet.ShouldProcess($Path, '移除空掛載點')) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
    }
    catch {
        Write-WinMediaLog -Config $Config -Level Warning -Message "清理空掛載點 $Path 失敗：$($_.Exception.Message)"
    }
}

Export-ModuleMember -Function Mount-WinMediaImage
