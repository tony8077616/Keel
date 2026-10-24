#Requires -Version 5.1

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module -Name (Join-Path -Path $script:root -ChildPath 'Common\WinMediaProcess.psm1') -Force
    $script:cfg = @{ DebugTrace = 0; OperationLog = ''; LogLevel = 'Error'; LogFile = '' }
    # 以 code point 組出中文，腳本本身維持 ASCII（不受檔案編碼影響）
    $script:expected = [string][char]0x6E2C + [char]0x8A66
}

Describe 'Invoke-WinMediaExternal 的 stdout／stderr 解碼' -Tag 'Unit' {
    It '父行程主控台為 UTF-8 時，cmd 寫入 stderr 的中文仍以 OEM code page 還原' {
        $saved = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [Text.Encoding]::UTF8
        }
        catch {
            Set-ItResult -Skipped -Because '無法設定主控台編碼（沒有主控台）'
            return
        }
        try {
            $r = Invoke-WinMediaExternal -FilePath 'cmd.exe' -ArgumentList @('/c', ('echo ' + $script:expected + ' 1>&2')) -Config $script:cfg
            $text = ([string]$r.StdErr).Trim()
            if ($text -cne $script:expected) {
                throw ('stderr 解碼不符，十六進位：' + ((($text.ToCharArray()) | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ' '))
            }
        }
        finally {
            [Console]::OutputEncoding = $saved
        }
    }

    It '父行程主控台為預設值時，stderr 同樣正確還原（迴歸）' {
        $r = Invoke-WinMediaExternal -FilePath 'cmd.exe' -ArgumentList @('/c', ('echo ' + $script:expected + ' 1>&2')) -Config $script:cfg
        ([string]$r.StdErr).Trim() | Should -BeExactly $script:expected
    }
}
