Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# 映像掛載包裝模組（§3.3）：try/finally 保證卸載；成功才 Save，其餘一律 Discard
# 需要的 Config 鍵：DismProvider、DismLogLevel、DebugTrace、LogDir、OperationLog、LogLevel／LogFile
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Common\WinMediaLog.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Common\PathSanitize.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinMediaDism.psm1') -Force

function Mount-WinMediaImage {
    # 掛載包裝（§3.3）：try/finally 保證卸載；成功才 -Save，其餘一律 -Discard
    # Mount：掛載映像；Remount：重新掛載已存在（NeedsRemount）的掛載點，目錄必須已存在
    [CmdletBinding(DefaultParameterSetName = 'Mount')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Mount')][string]$ImagePath,
        [Parameter(Mandatory, ParameterSetName = 'Mount')][int]$Index,
        [Parameter(Mandatory, ParameterSetName = 'Mount')]
        [Parameter(Mandatory, ParameterSetName = 'Remount')][string]$MountPath,
        [Parameter(Mandatory, ParameterSetName = 'Remount')][switch]$Remount,
        [Parameter(ParameterSetName = 'Mount')]
        [Parameter(ParameterSetName = 'Remount')][switch]$ReadOnly,
        [Parameter(ParameterSetName = 'Mount')][switch]$Optimize,
        [Parameter(ParameterSetName = 'Mount')][switch]$CheckIntegrity,
        [bool]$CommitOnSuccess = $true,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][hashtable]$Config
    )

    # 只在 Config 有設定時才帶 -ScratchDirectory（未設定為空 hashtable，呼叫形狀不變）
    $common = Get-WinMediaDismCommonParameter -Config $Config
    $createdMountDir = $false
    if ($Remount) {
        Write-WinMediaLog -Config $Config -Level Verbose -Message "重新掛載 $MountPath（ReadOnly=$ReadOnly）"
        # Remount 的目標目錄必須已存在；不建立也不刪除
        if (-not (Test-Path -LiteralPath $MountPath -PathType Container)) {
            throw "重新掛載失敗：掛載點目錄不存在（$MountPath）；Remount 不會自動建立目錄。"
        }
        Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Mount-WindowsImage -Path $MountPath -Remount @common -LogLevel $Config.DismLogLevel | Out-Null
        }
    }
    else {
        Write-WinMediaLog -Config $Config -Level Verbose -Message "掛載 $ImagePath 索引 $Index → $MountPath（ReadOnly=$ReadOnly）"
        # DISM 要求掛載點目錄已存在（否則回報「系統找不到指定的檔案」）；主流程只建立 MountDir 本身，子目錄由此補建
        $createdMountDir = -not (Test-Path -LiteralPath $MountPath)
        if ($createdMountDir) { New-Item -ItemType Directory -Path $MountPath -Force | Out-Null }
        # 只在開關設定時才加鍵
        $mountExtra = $common.Clone()
        if ($Optimize) { $mountExtra.Optimize = $true }
        if ($CheckIntegrity) { $mountExtra.CheckIntegrity = $true }
        try {
            Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                Mount-WindowsImage -ImagePath $ImagePath -Index $Index -Path $MountPath -ReadOnly:$ReadOnly @mountExtra -LogLevel $Config.DismLogLevel | Out-Null
            }
        }
        catch {
            Remove-WinMediaEmptyMountPoint -Path $MountPath -Created $createdMountDir -Config $Config
            throw
        }
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
                    Dismount-WindowsImage -Path $MountPath -Save @common -LogLevel $Config.DismLogLevel | Out-Null
                }
                else {
                    Dismount-WindowsImage -Path $MountPath -Discard @common -LogLevel $Config.DismLogLevel | Out-Null
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

function Get-WinMediaMountState {
    # 回傳掛載點狀態：OK／NeedsRemount／Invalid／Unknown（找不到或無法判讀）
    # 文件定義 DismMountStatus：Ok=0、NeedsRemount=1、Invalid=2；5.1 實測 MountedImageInfoObject 屬性為 Path、MountStatus（列舉 Ok／NeedsRemount／Invalid）
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $want = Get-ComparablePath -Path $Path
    $common = Get-WinMediaDismCommonParameter -Config $Config
    try {
        $mounted = Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
            Get-WindowsImage -Mounted -ErrorAction Stop @common
        }
    }
    catch {
        Write-WinMediaLog -Config $Config -Level Warning -Message "讀取掛載狀態失敗（$Path）：$($_.Exception.Message)"
        return 'Unknown'
    }
    $img = @($mounted) | Where-Object { (Get-ComparablePath -Path ([string]$_.Path)) -eq $want } | Select-Object -First 1
    if (-not $img) { return 'Unknown' }
    $prop = $img.PSObject.Properties['MountStatus']
    if (-not $prop) { return 'Unknown' }
    switch ([string]$prop.Value) {
        { $_ -in 'Ok', '0' } { return 'OK' }
        { $_ -in 'NeedsRemount', '1' } { return 'NeedsRemount' }
        { $_ -in 'Invalid', '2' } { return 'Invalid' }
        default { return 'Unknown' }
    }
}
function Get-WinMediaLoadedHive {
    # 列出 HKLM 底下以 WinMedia_ 開頭或等於 WinMediaBootSW 的已載入登錄檔（reg.exe query）；獨立成函式以便測試時模擬
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $names = foreach ($line in @(& reg.exe query HKLM 2>$null)) {
        $leaf = ([string]$line).Trim() -replace '^.*\\', ''
        if ($leaf -like 'WinMedia_*' -or $leaf -eq 'WinMediaBootSW') { $leaf }
    }
    return [string[]]@($names)
}

function Invoke-WinMediaRegUnload {
    # reg.exe unload 的薄包裝，便於測試時模擬
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    & reg.exe unload "HKLM\$Name" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg.exe unload HKLM\$Name 失敗（結束碼 $LASTEXITCODE）。" }
}

function Clear-WinMediaMount {
    # 清理殘留掛載：先卸載本工具載入的登錄檔（載入中的 hive 會使卸載失敗），再逐一 Discard 卸載；失敗則 Clear-WindowsCorruptMountPoint
    # 單一路徑的錯誤只記錄為警告，不拋出
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string[]]$MountPath,
        [Parameter(Mandatory)][hashtable]$Config
    )

    if (-not $PSCmdlet.ShouldProcess(($MountPath -join ', '), '卸載登錄檔並捨棄掛載')) { return }
    $common = Get-WinMediaDismCommonParameter -Config $Config

    try {
        foreach ($hive in @(Get-WinMediaLoadedHive)) {
            try { Invoke-WinMediaRegUnload -Name $hive }
            catch { Write-WinMediaLog -Config $Config -Level Warning -Message "卸載登錄檔 $hive 失敗：$($_.Exception.Message)" }
        }
    }
    catch { Write-WinMediaLog -Config $Config -Level Warning -Message "列舉已載入登錄檔失敗：$($_.Exception.Message)" }

    foreach ($mp in $MountPath) {
        try {
            Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                Dismount-WindowsImage -Path $mp -Discard @common -LogLevel $Config.DismLogLevel | Out-Null
            }
        }
        catch {
            Write-WinMediaLog -Config $Config -Level Warning -Message "捨棄卸載 $mp 失敗，改用 Clear-WindowsCorruptMountPoint：$($_.Exception.Message)"
            try {
                Invoke-WinMediaDism -Provider $Config.DismProvider -Config $Config -ScriptBlock {
                    Clear-WindowsCorruptMountPoint @common | Out-Null
                }
            }
            catch { Write-WinMediaLog -Config $Config -Level Warning -Message "Clear-WindowsCorruptMountPoint 失敗（$mp）：$($_.Exception.Message)" }
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

Export-ModuleMember -Function Mount-WinMediaImage, Get-WinMediaMountState, Clear-WinMediaMount
