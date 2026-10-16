Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# 通用操作紀錄與檔案雜湊模組（不依賴 WinMediaRefresh，可直接複製到其他專案）
# 需要的 Config 鍵：DebugTrace（0–3）、OperationLog（空白則不寫操作紀錄）
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinMediaLog.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PathSanitize.psm1') -Force

function Invoke-WinMediaOperation {
    # 操作紀錄包裝（§4.1）：檔案、登錄檔、壓縮、下載、外部程式與 DISM 操作都經過這裡
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('File', 'Registry', 'Archive', 'Download', 'Dism', 'External')][string]$Category,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $level = [int]$Config.DebugTrace
    $safeTarget = Protect-WinMediaLogValue -Value (ConvertTo-LogSafePath -Value $Target)
    $before = $null
    if ($level -ge 2) { $before = Get-WinMediaFingerprint -Path $Target }

    $start = Get-Date
    $result = 'success'
    $detail = ''
    try {
        return (& $ScriptBlock)
    }
    catch {
        $result = 'failure'
        $detail = Protect-WinMediaLogValue -Value $_.Exception.Message
        throw
    }
    finally {
        $elapsed = [int]((Get-Date) - $start).TotalMilliseconds
        # 逗號的優先順序高於 -f，每項都要加括號，否則只有第一項會被格式化、其餘被丟棄
        $fields = @(
            ('time={0}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')),
            ('category={0}' -f $Category),
            ('operation={0}' -f $Operation),
            ('target={0}' -f $safeTarget),
            ('result={0}' -f $result),
            ('elapsed_ms={0}' -f $elapsed)
        )
        if ($level -ge 2) {
            $after = Get-WinMediaFingerprint -Path $Target
            $fields += 'before={0}' -f $before
            $fields += 'after={0}' -f $after
        }
        if ($detail) { $fields += 'error={0}' -f $detail }

        if ($Config.OperationLog) {
            Add-WinMediaTextLine -Path $Config.OperationLog -Line ($fields -join ' | ')
        }
    }
}

function Get-WinMediaFingerprint {
    # 第 2 層以上才計算 SHA-256 與大小；目標不是檔案時只回報存在與否
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return 'missing'
        }
        $item = Get-Item -LiteralPath $Path
        $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $stream = [System.IO.File]::OpenRead($fullPath)
            try {
                $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '')
            }
            finally {
                $stream.Dispose()
            }
        }
        finally {
            $sha.Dispose()
        }
        return 'size={0};sha256={1}' -f $item.Length, $hash
    }
    catch {
        # 非檔案目標（例如整條外部命令列）或檔案被鎖定時不得讓紀錄本身失敗
        return 'n/a'
    }
}

function Test-WinMediaFileHash {
    # SHA-256 比對；不符或不存在回傳 $false，由呼叫端決定是否中止
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Alias('Sha256')][string]$Hash,
        [ValidateSet('SHA256', 'SHA1')][string]$Algorithm = 'SHA256'
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash
    return ($actual -ieq $Hash)
}

Export-ModuleMember -Function Invoke-WinMediaOperation, Get-WinMediaFingerprint, Test-WinMediaFileHash
