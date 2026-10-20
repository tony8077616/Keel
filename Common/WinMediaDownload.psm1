Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# 通用下載傳輸模組（不依賴 WinMediaRefresh，可直接複製到其他專案）
# 需要的 Config 鍵：DebugTrace、OperationLog、LogLevel／LogFile
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinMediaLog.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinMediaOperation.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinMediaProcess.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'PathSanitize.psm1') -Force

$script:MaxRedirects = 5

function Complete-WinMediaBitsJob {
    # BITS 的 -BitsJob 參數為強型別；包成字串 JobId 介面，測試才能以替身取代
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JobId
    )

    Complete-BitsTransfer -BitsJob (Get-BitsTransfer -JobId $JobId)
}

function Clear-WinMediaBitsJob {
    # 失敗時清除工作；工作已不存在時不報錯
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JobId
    )

    $job = Get-BitsTransfer -JobId $JobId -ErrorAction SilentlyContinue
    if ($job) { Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue }
}

function Get-WinMediaRedirectStep {
    # 只取回回應標頭（Range 0-0，不下載本體），且不自動跟隨重導向；HttpWebRequest 無 cmdlet 替代，獨立成函式以便測試替身
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$Uri
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.AllowAutoRedirect = $false
    $request.Method = 'GET'
    $request.AddRange(0, 0)
    try {
        $response = $request.GetResponse()
    }
    catch [Net.WebException] {
        # 4xx／5xx 會以例外呈現，但例外仍帶有回應；由呼叫端依狀態碼判定
        if (-not $_.Exception.Response) { throw }
        $response = $_.Exception.Response
    }
    try {
        return [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Location = $response.Headers['Location'] }
    }
    finally {
        $response.Close()
    }
}

function Resolve-WinMediaDownloadUri {
    # 逐跳解析重導向：每一跳都必須是 https，且主機符合 AllowedHostPattern（空字串 = 不限主機，但仍要求 https）
    # 回傳最終網址與各跳的 SafeUri（供記錄；不記錄原始 Location，因為 CDN 網址可能含 token）
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [string]$AllowedHostPattern = ''
    )

    $current = $Uri
    $hops = @()
    for ($hop = 0; $hop -le $script:MaxRedirects; $hop++) {
        if ($current.Scheme -ne 'https') { throw "下載網址或重導向目標不是 https：$($current.Host)" }
        if ($AllowedHostPattern -and $current.Host -notmatch $AllowedHostPattern) {
            throw "重導向目標不在允許的網域：$($current.Host)（若確認可信，請擴充允許清單）"
        }
        $hops += (ConvertTo-SanitizedUri -Uri $current.AbsoluteUri).SafeUri
        $step = Get-WinMediaRedirectStep -Uri $current
        if ($step.StatusCode -ge 300 -and $step.StatusCode -lt 400) {
            if (-not $step.Location) { throw "重導向缺少 Location 標頭：$($current.Host)（HTTP $($step.StatusCode)）" }
            $current = New-Object -TypeName System.Uri -ArgumentList $current, ([string]$step.Location)
            continue
        }
        if ($step.StatusCode -ge 200 -and $step.StatusCode -lt 300) {
            return [pscustomobject]@{ Uri = $current; Hops = $hops }
        }
        throw "下載來源回應 HTTP $($step.StatusCode)：$($current.Host)"
    }
    throw "重導向超過 $($script:MaxRedirects) 次，已中止"
}

function Invoke-WinMediaDownload {
    # 單一檔案下載：先逐跳驗證重導向鏈，再以最終網址下載；先寫入 .partial，完成後才改名
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [ValidateSet('WebRequest', 'Bits', 'Curl')][string]$Method = 'WebRequest',
        [string]$AllowedHostPattern = '',
        [Parameter(Mandatory)][hashtable]$Config
    )

    $safe = ConvertTo-SanitizedUri -Uri $Uri
    $resolved = Resolve-WinMediaDownloadUri -Uri $safe.Uri -AllowedHostPattern $AllowedHostPattern
    foreach ($hop in $resolved.Hops) { Write-WinMediaLog -Config $Config -Level Info -Message "下載路徑：$hop" }
    $finalUri = $resolved.Uri.AbsoluteUri

    $dest = (ConvertTo-SanitizedPath -Path $Destination).Path
    $partial = $dest + '.partial'
    New-Item -ItemType Directory -Path (Split-Path -Path $dest -Parent) -Force | Out-Null
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }

    Invoke-WinMediaOperation -Category Download -Operation ('Download-' + $Method) -Target $safe.SafeUri -Config $Config -ScriptBlock {
        switch ($Method) {
            'WebRequest' {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                $ProgressPreference = 'SilentlyContinue'
                # 重導向已於上方逐跳驗證；此處禁止再自動跟隨
                Invoke-WebRequest -Uri $finalUri -OutFile $partial -UseBasicParsing -MaximumRedirection 0
            }
            'Bits' {
                # 殘餘限制：BITS 無法關閉自動重導向，這裡只能使用已驗證的最終網址降低風險
                # shortcut: 輪詢間隔固定 2 秒、逾時 60 分鐘，沒有進度列；需要更細的進度再改
                $job = Start-BitsTransfer -Source $finalUri -Destination $partial -Asynchronous -DisplayName 'WinMediaRefresh'
                try {
                    $deadline = (Get-Date).AddMinutes(60)
                    while ($job.JobState -in 'Queued', 'Connecting', 'Transferring', 'TransientError' -and (Get-Date) -lt $deadline) {
                        Start-Sleep -Seconds 2
                        $job = Get-BitsTransfer -JobId $job.JobId
                    }
                    if ($job.JobState -ne 'Transferred') { throw "BITS 下載未完成，狀態：$($job.JobState)" }
                    Complete-WinMediaBitsJob -JobId $job.JobId
                }
                catch {
                    Clear-WinMediaBitsJob -JobId $job.JobId
                    throw
                }
            }
            'Curl' {
                # 不使用 -L：重導向已於上方驗證，curl 不再自行跟隨
                $curl = Join-Path -Path $env:SystemRoot -ChildPath 'System32\curl.exe'
                $result = Invoke-WinMediaExternal -FilePath $curl -ArgumentList @('--fail', '--silent', '--show-error', '-o', $partial, $finalUri) -Config $Config
                if ($result.ExitCode -ne 0) { throw "curl 下載失敗，結束碼 $($result.ExitCode)：$($result.StdErr)" }
            }
        }
    } | Out-Null

    Move-Item -LiteralPath $partial -Destination $dest -Force
    return $dest
}

Export-ModuleMember -Function Invoke-WinMediaDownload, Resolve-WinMediaDownloadUri
