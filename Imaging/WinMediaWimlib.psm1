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

function Resolve-WinMediaWimlib {
    # wimlib-imagex 解析：Config.Wimlib.Path 已存在則直接使用；否則取得固定版本並校驗 SHA-256 後解壓縮到目標位置
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    $exe = $Config.Wimlib.Path
    if ([string]::IsNullOrWhiteSpace($exe)) {
        $exe = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'WinMediaRefresh\tools\wimlib-1.14.5\wimlib-imagex.exe'
    }
    if (Test-Path -LiteralPath $exe -PathType Leaf) {
        return $exe
    }

    $spec = Get-WinMediaWimlibSpec
    $toolDir = Split-Path -Path $exe -Parent
    $downloadDir = Join-Path -Path $Config.WorkDir -ChildPath 'downloads'
    $zip = Join-Path -Path $downloadDir -ChildPath $spec.FileName
    $bundled = Join-Path -Path $script:ImagingRoot -ChildPath ('tools\wimlib\' + $spec.FileName)

    if (Test-WinMediaFileHash -Path $bundled -Sha256 $spec.Sha256) {
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

    New-Item -ItemType Directory -Path $toolDir -Force | Out-Null
    Invoke-WinMediaOperation -Category Archive -Operation 'ExpandWimlib' -Target $toolDir -Config $Config -ScriptBlock {
        Expand-Archive -LiteralPath $zip -DestinationPath $toolDir -Force
    } | Out-Null

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
