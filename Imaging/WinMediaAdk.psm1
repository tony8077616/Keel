Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Windows ADK（Deployment Tools：DISM、oscdimg）解析與安裝模組
# 需要的 Config 鍵：AdkRoot（ADK 安裝根目錄）、WorkDir（安裝程式下載位置）、LogLevel／LogFile、DebugTrace、OperationLog
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Common\WinMediaLog.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Common\WinMediaOperation.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\Common\PathSanitize.psm1') -Force

function Resolve-WinMediaAdk {
    # ADK 路徑探測（§3.4、§3.4.2 2a–2d）；兩種文件路徑都探測，缺少時自動安裝一次後重新探測
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    $found = Find-WinMediaAdkDism -Config $Config
    if (-not $found) {
        Install-WinMediaAdk -Config $Config
        $found = Find-WinMediaAdkDism -Config $Config
    }
    if (-not $found) {
        throw "安裝 ADK 後仍找不到 DISM：'$($Config.AdkRoot)'"
    }

    $dismExe = Join-Path -Path $found -ChildPath 'dism.exe'
    $version = if (Test-Path -LiteralPath $dismExe) { (Get-Item -LiteralPath $dismExe).VersionInfo.FileVersion } else { 'unknown' }
    Write-WinMediaLog -Config $Config -Level Info -Message ("ADK DISM 目錄：$found；dism.exe 版本：$version")

    [pscustomobject]@{
        Root       = $found
        ModulePath = Join-Path -Path $found -ChildPath 'Dism.psd1'
        DismExe    = $dismExe
    }
}

function Find-WinMediaAdkDism {
    # 回傳第一個含 Dism.psd1 或 dism.exe 的候選目錄；皆無則回傳 $null
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    if ([string]::IsNullOrEmpty($Config.AdkRoot)) {
        throw 'AdkRoot 未設定。'
    }

    $candidates = @(
        (Join-Path -Path $Config.AdkRoot -ChildPath 'Deployment Tools\10\DISM'),
        (Join-Path -Path $Config.AdkRoot -ChildPath 'Deployment Tools\amd64\DISM')
    )
    foreach ($candidate in $candidates) {
        if ((Test-Path -LiteralPath (Join-Path -Path $candidate -ChildPath 'Dism.psd1')) -or
            (Test-Path -LiteralPath (Join-Path -Path $candidate -ChildPath 'dism.exe'))) {
            return $candidate
        }
    }
    return $null
}

function Resolve-WinMediaOscdimg {
    # oscdimg 解析（§3.5）：來源為 Q&A，非 Learn 官方，實機確認；缺少時自動安裝 ADK 後再確認
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    if ([string]::IsNullOrEmpty($Config.AdkRoot)) {
        throw 'AdkRoot 未設定。'
    }
    $path = Join-Path -Path $Config.AdkRoot -ChildPath 'Deployment Tools\amd64\Oscdimg\oscdimg.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Install-WinMediaAdk -Config $Config
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "安裝 ADK 後仍找不到 oscdimg.exe：'$path'"
    }
    return $path
}

function Test-WinMediaSignerIsMicrosoft {
    # 逐一比對 X.500 RDN 的 O 欄位完整相等；字串正規式會被引號 CN 內的 ", O=Microsoft Corporation" 騙過
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )

    $rdns = $Certificate.SubjectName.Decode([System.Security.Cryptography.X509Certificates.X500DistinguishedNameFlags]::UseNewLines) -split "`r?`n"
    return [bool]($rdns | Where-Object { $_ -ceq 'O=Microsoft Corporation' })
}

function Install-WinMediaAdk {
    # 缺少 ADK 時自動安裝 Deployment Tools（oscdimg、ADK DISM）到 Config.AdkRoot；安裝程式必須為 Microsoft 簽章
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    if ([string]::IsNullOrEmpty($Config.AdkRoot)) {
        throw 'AdkRoot 未設定，無法安裝 ADK。'
    }
    $uri = ConvertTo-SanitizedUri -Uri 'https://go.microsoft.com/fwlink/?linkid=2289980'
    $downloadDir = Join-Path -Path $Config.WorkDir -ChildPath 'downloads'
    $installer = Join-Path -Path $downloadDir -ChildPath 'adksetup.exe'
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

    Write-WinMediaLog -Config $Config -Level Info -Message "本地沒有 ADK Deployment Tools，自動下載安裝程式：$($uri.SafeUri)"
    Invoke-WinMediaOperation -Category Download -Operation 'DownloadAdk' -Target $uri.SafeUri -Config $Config -ScriptBlock {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $uri.Uri -OutFile $installer -UseBasicParsing
    } | Out-Null

    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or -not (Test-WinMediaSignerIsMicrosoft -Certificate $signature.SignerCertificate)) {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        throw "ADK 安裝程式簽章無效或非 Microsoft 簽署，已刪除：$installer"
    }

    $arguments = '/quiet /norestart /installpath "{0}" /features OptionId.DeploymentTools' -f $Config.AdkRoot
    $process = Invoke-WinMediaOperation -Category External -Operation 'InstallAdk' -Target $installer -Config $Config -ScriptBlock {
        Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
    }
    if ($process.ExitCode -notin 0, 3010) {
        throw "ADK 安裝失敗，結束碼 $($process.ExitCode)"
    }
}

Export-ModuleMember -Function Resolve-WinMediaAdk, Find-WinMediaAdkDism, Resolve-WinMediaOscdimg, Install-WinMediaAdk
