Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# 通用路徑淨化模組（不依賴 WinMediaRefresh，可直接複製到其他專案）
# 處理：一般檔案路徑（含盤符、相對、根相對）、UNC、\\?\ 長路徑、\\.\ 裝置命名空間（拒絕）、
#       PowerShell 登錄機碼路徑（HKLM:\、Registry::、reg.exe 形式）、網址（http／https／ftp）

function ConvertTo-SanitizedPath {
    # 將檔案系統路徑正規化：去除 FileSystem 提供者前綴、統一分隔符、收斂重複分隔符、拒絕 .. 與非法字元
    # 回傳 Path（一般形式）、Kind（Drive／UNC／RootRelative／Relative）、LongPath（超過 260 字元時的 \\?\ 形式）
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path
    )

    $work = $Path.Trim()
    if ([string]::IsNullOrEmpty($work)) { throw '路徑為空白。' }
    if ($work -match '[\x00-\x1F]') { throw "路徑含控制字元：$Path" }

    # 去除 PowerShell 的 FileSystem 提供者前綴
    $work = $work -replace '^(?i)Microsoft\.PowerShell\.Core\\FileSystem::', ''
    $work = $work -replace '^(?i)FileSystem::', ''
    if ($work -match '(?i)^(Registry::|Microsoft\.PowerShell\.Core\\Registry::|HK(LM|CU|CR|U|CC)[:\\]|HKEY_)') {
        throw "此為登錄機碼路徑，請改用 ConvertTo-SanitizedRegistryPath：$Path"
    }
    if ($work -match '^(?i)(https?|ftp)://') {
        throw "此為網址，請改用 ConvertTo-SanitizedUri：$Path"
    }
    $work = $work.Replace('/', '\')

    $prefix = ''
    if ($work.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        $prefix = '\\?\UNC\'
        $work = '\\' + $work.Substring(8)
    }
    elseif ($work.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
        $prefix = '\\?\'
        $work = $work.Substring(4)
    }
    if ($work.StartsWith('\\.\')) { throw "不支援裝置命名空間：$Path" }

    if ($work -match '^\\\\[^\\]') {
        $kind = 'UNC'
        $root = '\\'
        $rest = $work.Substring(2)
    }
    elseif ($work -match '^[A-Za-z]:') {
        $kind = 'Drive'
        $root = $work.Substring(0, 2)
        $rest = $work.Substring(2)
    }
    elseif ($work.StartsWith('\')) {
        $kind = 'RootRelative'
        $root = ''
        $rest = $work
    }
    else {
        $kind = 'Relative'
        $root = ''
        $rest = $work
    }

    $segments = @()
    foreach ($segment in ($rest -split '\\')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq '.') { continue }
        if ($segment -eq '..') { throw "路徑不可含上層參照（..）：$Path" }
        if ($segment -match '[<>"|?*:]') { throw "路徑段含非法字元：$segment（$Path）" }
        if ($segment -match '[. ]$') { throw "路徑段結尾不可為點或空白：$segment（$Path）" }
        $segments += $segment
    }

    switch ($kind) {
        'UNC' {
            if ($segments.Count -lt 2) { throw "UNC 路徑需包含伺服器與共用名稱：$Path" }
            $normal = '\\' + ($segments -join '\')
        }
        'Drive' {
            $normal = $root + '\' + ($segments -join '\')
        }
        'RootRelative' {
            $normal = '\' + ($segments -join '\')
        }
        default {
            $normal = $segments -join '\'
        }
    }

    # 超過 MAX_PATH（260）的絕對路徑提供 \\?\ 形式，供需要長路徑的呼叫端使用
    $longPath = $null
    if (($kind -eq 'Drive' -or $kind -eq 'UNC') -and $normal.Length -ge 248) {
        $longPath = if ($kind -eq 'UNC') { '\\?\UNC\' + $normal.Substring(2) } else { '\\?\' + $normal }
    }
    if ($prefix) {
        $longPath = if ($kind -eq 'UNC') { '\\?\UNC\' + $normal.Substring(2) } else { '\\?\' + $normal }
    }

    [pscustomobject]@{
        Path     = $normal
        Kind     = $kind
        LongPath = $longPath
        Original = $Path
    }
}

function ConvertTo-SanitizedRegistryPath {
    # 登錄機碼路徑正規化：接受 HKLM:\、HKEY_LOCAL_MACHINE\、Registry::HKEY_...、HKLM\（reg.exe）等形式
    # 回傳 Hive（長名稱）、SubKey、ProviderPath（Registry::…）、RegExePath（HKLM\…）、PsDrivePath（HKLM:\…）
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path
    )

    $work = $Path.Trim()
    if ([string]::IsNullOrEmpty($work)) { throw '登錄機碼路徑為空白。' }
    if ($work -match '[\x00-\x1F]') { throw "登錄機碼路徑含控制字元：$Path" }
    $work = $work -replace '^(?i)Microsoft\.PowerShell\.Core\\Registry::', ''
    $work = $work -replace '^(?i)Registry::', ''
    $work = $work.Replace('/', '\')

    $match = [regex]::Match($work, '^(?<hive>[^\\:]+)(?::\\?|\\|$)(?<rest>.*)$')
    if (-not $match.Success) { throw "無法解析登錄機碼路徑：$Path" }

    # 登錄機碼根：短名稱（HKLM）與長名稱（HKEY_LOCAL_MACHINE）對應到同一組結果
    $hives = @{
        'HKLM' = 'HKEY_LOCAL_MACHINE'; 'HKEY_LOCAL_MACHINE' = 'HKEY_LOCAL_MACHINE'
        'HKCU' = 'HKEY_CURRENT_USER';  'HKEY_CURRENT_USER' = 'HKEY_CURRENT_USER'
        'HKCR' = 'HKEY_CLASSES_ROOT';  'HKEY_CLASSES_ROOT' = 'HKEY_CLASSES_ROOT'
        'HKU'  = 'HKEY_USERS';         'HKEY_USERS' = 'HKEY_USERS'
        'HKCC' = 'HKEY_CURRENT_CONFIG'; 'HKEY_CURRENT_CONFIG' = 'HKEY_CURRENT_CONFIG'
    }
    $shortNames = @{
        'HKEY_LOCAL_MACHINE' = 'HKLM'; 'HKEY_CURRENT_USER' = 'HKCU'; 'HKEY_CLASSES_ROOT' = 'HKCR'
        'HKEY_USERS' = 'HKU'; 'HKEY_CURRENT_CONFIG' = 'HKCC'
    }

    $hiveKey = $match.Groups['hive'].Value.ToUpperInvariant()
    if (-not $hives.ContainsKey($hiveKey)) { throw "未知的登錄機碼根：$hiveKey（$Path）" }
    $hive = $hives[$hiveKey]

    $segments = @()
    foreach ($segment in ($match.Groups['rest'].Value -split '\\')) {
        if ([string]::IsNullOrEmpty($segment)) { continue }
        if ($segment -eq '..') { throw "登錄機碼路徑不可含上層參照（..）：$Path" }
        $segments += $segment
    }
    $subKey = $segments -join '\'
    $short = $shortNames[$hive]

    [pscustomobject]@{
        Hive         = $hive
        SubKey       = $subKey
        ProviderPath = 'Registry::' + $hive + $(if ($subKey) { '\' + $subKey } else { '' })
        RegExePath   = $short + $(if ($subKey) { '\' + $subKey } else { '' })
        PsDrivePath  = $short + ':\' + $subKey
        Original     = $Path
    }
}

function ConvertTo-SanitizedUri {
    # 網址淨化：僅允許 http、https、ftp（預設）；回傳移除帳密的 SafeUri 供紀錄，以及可安全用作檔名的 FileName
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string[]]$AllowedSchemes = @('https', 'http', 'ftp')
    )

    $work = $Uri.Trim()
    if ($work -match '[\x00-\x1F\s]') { throw "網址含空白或控制字元：$Uri" }
    $parsed = $null
    if (-not [Uri]::TryCreate($work, [UriKind]::Absolute, [ref]$parsed)) {
        throw "不是有效的絕對網址：$Uri"
    }
    if ($parsed.Scheme -notin $AllowedSchemes) {
        throw "不允許的網址協定：$($parsed.Scheme)（允許：$($AllowedSchemes -join ', ')）"
    }

    # 紀錄用：移除 userinfo（帳號密碼），保留協定、主機、埠、路徑與查詢字串
    $components = [UriComponents]([int][UriComponents]::Scheme -bor [int][UriComponents]::Host -bor [int][UriComponents]::Port -bor [int][UriComponents]::Path -bor [int][UriComponents]::Query)
    $safe = $parsed.GetComponents($components, [UriFormat]::UriEscaped)

    $segments = @($parsed.AbsolutePath.TrimEnd('/') -split '/')
    $leaf = [Uri]::UnescapeDataString($segments[-1])
    $leaf = $leaf -replace '[\\/:*?"<>|\x00-\x1F]', '_'
    if ([string]::IsNullOrWhiteSpace($leaf) -or $leaf -match '^\.+$') { $leaf = 'download' }

    [pscustomobject]@{
        Uri      = $parsed.AbsoluteUri
        SafeUri  = $safe
        Scheme   = $parsed.Scheme
        Host     = $parsed.Host
        FileName = $leaf
    }
}

function Get-ComparablePath {
    # 比對用的完整路徑：統一為一般形式、補結尾反斜線、小寫（比對不分大小寫）
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path
    )

    $fs = ConvertTo-SanitizedPath -Path $Path
    $full = $fs.Path
    if ($fs.Kind -eq 'Relative' -or $fs.Kind -eq 'RootRelative') {
        $full = [IO.Path]::GetFullPath($full)
    }
    return ($full.TrimEnd('\') + '\').ToLowerInvariant()
}

function Test-PathWithin {
    # 判斷 Child 是否等於或位於 Parent 之下（路徑段邊界比對，不會把 D:\pkg2 誤判為 D:\pkg 之下）
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Child,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Parent
    )

    if ([string]::IsNullOrWhiteSpace($Child) -or [string]::IsNullOrWhiteSpace($Parent)) { return $false }
    $childPath = Get-ComparablePath -Path $Child
    $parentPath = Get-ComparablePath -Path $Parent
    return $childPath.StartsWith($parentPath, [StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-LogSafePath {
    # 紀錄用：網址移除帳密（SafeUri）；無效網址與其他字串原樣回傳，不得讓紀錄本身失敗
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Value
    )

    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    if ($Value -match '^(?i)(https?|ftp)://') {
        try { return (ConvertTo-SanitizedUri -Uri $Value).SafeUri }
        catch { return '<無效網址>' }
    }
    return $Value
}

Export-ModuleMember -Function ConvertTo-SanitizedPath, ConvertTo-SanitizedRegistryPath, ConvertTo-SanitizedUri, Get-ComparablePath, Test-PathWithin, ConvertTo-LogSafePath
