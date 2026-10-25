Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# wimlib-imagex 解析、取得與呼叫模組（§2.4）
# 需要的 Config 鍵：Wimlib.Path（空白則使用 %LOCALAPPDATA% 預設位置）、WorkDir（下載暫存）、DebugTrace、OperationLog、LogLevel／LogFile
# 內附壓縮檔放在本模組的 tools\wimlib\（與模組一起搬移）
$script:ImagingRoot = $PSScriptRoot
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Common\WinMediaLog.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Common\WinMediaOperation.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Common\WinMediaProcess.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Common\PathSanitize.psm1') -Force

function Get-WinMediaWimlibSpec {
    # wimlib 1.14.5 Windows 發行包與 SHA-256（來源：wimlib 論壇 1.14.5 公告，viewtopic.php?t=1133）
    [CmdletBinding()]
    param(
        [string]$Architecture = $env:PROCESSOR_ARCHITECTURE
    )

    $releases = @{
        'x86_64'  = @{ FileName = 'wimlib-1.14.5-windows-x86_64-bin.zip'; Sha256 = '2f446d6fa3866582175f1a22a7be198eeee0aec7aba5b4e04ad25c99eae2d265' }
        'aarch64' = @{ FileName = 'wimlib-1.14.5-windows-aarch64-bin.zip'; Sha256 = '2c2e3e50cf21bfdd4ffd693b5052b231aa04a10c85f218ae61eb5a031dfcdd8f' }
        'i686'    = @{ FileName = 'wimlib-1.14.5-windows-i686-bin.zip';    Sha256 = '3739eb2291b9a86d2fcc2914c4b2b53317c045de214782e46588ed8350371905' }
    }

    $machine = @{ AMD64 = 'x86_64'; ARM64 = 'aarch64'; x86 = 'i686' }[$Architecture]
    if (-not $machine) {
        throw "不支援的處理器架構：$Architecture"
    }

    [pscustomobject]@{
        Version      = '1.14.5'
        Architecture = $machine
        FileName     = $releases[$machine].FileName
        Url          = 'https://wimlib.net/downloads/' + $releases[$machine].FileName
        Sha256       = $releases[$machine].Sha256
    }
}

function Test-WinMediaWimlibCache {
    # 預設快取完整性：快取內的 zip 須符合固定 SHA-256，zip 內每個檔案的雜湊須與磁碟一致，且不得有 zip 沒有的多餘檔案
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolDir,
        [Parameter(Mandatory)][pscustomobject]$Spec
    )

    $cachedZip = Join-Path -Path $ToolDir -ChildPath $Spec.FileName
    if (-not (Test-WinMediaFileHash -Path $cachedZip -Sha256 $Spec.Sha256)) {
        return $false
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $expected = @{ $Spec.FileName = $true }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $archive = [System.IO.Compression.ZipFile]::OpenRead($cachedZip)
    try {
        foreach ($entry in $archive.Entries) {
            if (-not $entry.Name) { continue }
            $relative = $entry.FullName.Replace('/', '\')
            $expected[$relative] = $true
            $onDisk = Join-Path -Path $ToolDir -ChildPath $relative
            if (-not (Test-Path -LiteralPath $onDisk -PathType Leaf)) { return $false }
            $stream = $entry.Open()
            try { $want = [System.BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') } finally { $stream.Dispose() }
            if ((Get-FileHash -LiteralPath $onDisk -Algorithm SHA256).Hash -ne $want) { return $false }
        }
    }
    finally {
        $archive.Dispose()
        $sha.Dispose()
    }
    $root = (Get-Item -LiteralPath $ToolDir).FullName.TrimEnd('\') + '\'
    foreach ($file in Get-ChildItem -LiteralPath $ToolDir -Recurse -File -Force) {
        if (-not $expected.ContainsKey($file.FullName.Substring($root.Length))) { return $false }
    }
    return $true
}

function Expand-WinMediaWimlibZip {
    # 驗證與解壓使用同一份位元組：整檔讀入記憶體、比對 SHA-256，再從同一份位元組解壓（驗證後檔案不可被替換）
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Zip,
        [Parameter(Mandatory)][string]$DestinationDir,
        [Parameter(Mandatory)][string]$Sha256
    )

    $bytes = [System.IO.File]::ReadAllBytes($Zip)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $actual = [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') } finally { $sha.Dispose() }
    if ($actual -ine $Sha256) { throw "wimlib 壓縮檔 SHA-256 不符：$Zip" }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream = [System.IO.MemoryStream]::new($bytes)
    $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Read)
    try { [System.IO.Compression.ZipFileExtensions]::ExtractToDirectory($archive, $DestinationDir) }
    finally { $archive.Dispose(); $stream.Dispose() }
}

function Resolve-WinMediaWimlib {
    # wimlib-imagex 解析：Config.Wimlib.Path 已存在則直接使用；否則取得固定版本並校驗 SHA-256 後解壓縮到目標位置
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    $exe = $Config.Wimlib.Path
    $isDefault = [string]::IsNullOrWhiteSpace($exe)
    if ($isDefault) {
        $exe = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'WinMediaRefresh\tools\wimlib-1.14.5\wimlib-imagex.exe'
    }
    elseif (Test-Path -LiteralPath $exe -PathType Leaf) {
        return $exe
    }

    $spec = Get-WinMediaWimlibSpec
    $toolDir = Split-Path -Path $exe -Parent
    $downloadDir = Join-Path -Path $Config.WorkDir -ChildPath 'downloads'
    $zip = Join-Path -Path $downloadDir -ChildPath $spec.FileName
    $bundled = Join-Path -Path $script:ImagingRoot -ChildPath ('tools\wimlib\' + $spec.FileName)

    $haveZip = $false
    if ($isDefault -and (Test-Path -LiteralPath $toolDir)) {
        # shortcut: 驗證到 wimlib-imagex.exe 實際執行之間仍有 TOCTOU 空窗（同使用者程式可在此間隔替換檔案）, 改為複製到管理員專屬目錄再執行或鎖定檔案時升級
        if (Test-WinMediaWimlibCache -ToolDir $toolDir -Spec $spec) {
            return $exe
        }
        Write-WinMediaLog -Config $Config -Level Warning -Message "wimlib 快取完整性檢查失敗，刪除並重新解壓：$toolDir"
        $cachedZip = Join-Path -Path $toolDir -ChildPath $spec.FileName
        if (Test-WinMediaFileHash -Path $cachedZip -Sha256 $spec.Sha256) {
            New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
            Copy-Item -LiteralPath $cachedZip -Destination $zip -Force
            $haveZip = $true
        }
        Remove-Item -LiteralPath $toolDir -Recurse -Force
    }

    if ($haveZip) {
        Write-WinMediaLog -Config $Config -Level Info -Message '使用快取中已驗證的 wimlib 壓縮檔重新解壓'
    }
    elseif (Test-WinMediaFileHash -Path $bundled -Sha256 $spec.Sha256) {
        Write-WinMediaLog -Config $Config -Level Info -Message "使用模組內附的 wimlib 壓縮檔：$bundled"
        $zip = $bundled
    }
    else {
        New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
        Write-WinMediaLog -Config $Config -Level Info -Message "本地沒有 wimlib-imagex，自動下載 $($spec.Url)"
        Invoke-WinMediaOperation -Category Download -Operation 'DownloadWimlib' -Target $spec.Url -Config $Config -ScriptBlock {
            $ProgressPreference = 'SilentlyContinue'
            # 下載前先淨化網址：只接受 http／https／ftp 絕對網址，無效時在操作紀錄中標為失敗
            $uri = ConvertTo-SanitizedUri -Uri $spec.Url
            Invoke-WebRequest -Uri $uri.Uri -OutFile $zip -UseBasicParsing
        } | Out-Null
        if (-not (Test-WinMediaFileHash -Path $zip -Sha256 $spec.Sha256)) {
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            throw "wimlib 壓縮檔 SHA-256 不符，已刪除：$($spec.FileName)"
        }
    }

    # 非預設路徑是使用者指定的目錄：不清空、不覆寫，已有內容即拒絕（預設路徑已在上方清空）
    if (-not $isDefault -and (Test-Path -LiteralPath $toolDir) -and @(Get-ChildItem -LiteralPath $toolDir -Force).Count -gt 0) {
        throw "wimlib 目錄非空，拒絕解壓（請指定空目錄或移除既有檔案）：$toolDir"
    }
    New-Item -ItemType Directory -Path $toolDir -Force | Out-Null
    Invoke-WinMediaOperation -Category Archive -Operation 'ExpandWimlib' -Target $toolDir -Config $Config -ScriptBlock {
        Expand-WinMediaWimlibZip -Zip $zip -DestinationDir $toolDir -Sha256 $spec.Sha256
    } | Out-Null

    if ($isDefault) {
        Copy-Item -LiteralPath $zip -Destination (Join-Path -Path $toolDir -ChildPath $spec.FileName) -Force
    }

    $extracted = Join-Path -Path $toolDir -ChildPath 'wimlib-imagex.exe'
    if (-not (Test-Path -LiteralPath $extracted -PathType Leaf)) {
        throw "解壓縮後找不到 wimlib-imagex.exe：$toolDir"
    }
    if ($extracted -ine $exe) {
        Copy-Item -LiteralPath $extracted -Destination $exe -Force
    }
    return $exe
}

function Invoke-WinMediaWimlib {
    # wimlib-imagex 專用入口：只接受 wimlib 自己的子命令與參數，不與 DISM 指令混用（§2.4）
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$StandardInputPath
    )

    $exe = Resolve-WinMediaWimlib -Config $Config
    $result = Invoke-WinMediaExternal -FilePath $exe -ArgumentList $ArgumentList -Config $Config -StandardInputPath $StandardInputPath
    if ($result.ExitCode -ne 0) {
        throw "wimlib-imagex $($ArgumentList[0]) 失敗，結束碼 $($result.ExitCode)：$($result.StdErr)"
    }
    return $result
}

Export-ModuleMember -Function Get-WinMediaWimlibSpec, Resolve-WinMediaWimlib, Invoke-WinMediaWimlib
