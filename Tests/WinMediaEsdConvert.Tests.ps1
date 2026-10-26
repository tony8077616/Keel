#Requires -Version 5.1

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Common\WinMediaLog.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\Imaging\WinMediaEsd.psm1') -Force
    $script:newCfg = {
        param([string]$WimlibPath)
        @{ DismProvider = 'Inbox'; LogLevel = 'Error'; LogFile = ''; OperationLog = ''; DebugTrace = 0; WorkDir = $TestDrive; Wimlib = @{ Path = $WimlibPath } }
    }
}

Describe 'Convert-WinMediaEsdToWim' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName WinMediaEsd Invoke-WinMediaOperation { param($ScriptBlock) & $ScriptBlock }
        Mock -ModuleName WinMediaEsd Invoke-WinMediaWimlib { }
        Mock -ModuleName WinMediaEsd Invoke-WinMediaDism { }
        $script:wimOut = $null
    }

    It 'Wimlib.Path 有值：走 wimlib，參數正確，不呼叫 DISM，並刪除來源 ESD' {
        $esd = Join-Path $TestDrive 'w-install.esd'
        $wim = Join-Path $TestDrive 'w-install.wim'
        Set-Content -LiteralPath $esd -Value 'esd'
        $script:wimOut = $wim
        Mock -ModuleName WinMediaEsd Invoke-WinMediaWimlib { Set-Content -LiteralPath $script:wimOut -Value 'wim' }
        Convert-WinMediaEsdToWim -SourceEsd $esd -DestinationWim $wim -Config (& $script:newCfg (Join-Path $TestDrive 'fake.exe'))
        Should -Invoke -ModuleName WinMediaEsd Invoke-WinMediaWimlib -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -eq 'export' -and $ArgumentList[1] -eq $esd -and $ArgumentList[2] -eq 'all' -and $ArgumentList[3] -eq $wim
        }
        Should -Invoke -ModuleName WinMediaEsd Invoke-WinMediaDism -Times 0 -Exactly
        Test-Path -LiteralPath $esd | Should -BeFalse
        Test-Path -LiteralPath $wim | Should -BeTrue
    }

    It 'Wimlib.Path 為空：走 DISM，逐索引匯出，不呼叫 wimlib，並刪除來源 ESD' {
        $esd = Join-Path $TestDrive 'd-install.esd'
        $wim = Join-Path $TestDrive 'd-install.wim'
        Set-Content -LiteralPath $esd -Value 'esd'
        $script:wimOut = $wim
        Mock -ModuleName WinMediaEsd Invoke-WinMediaDism {
            param($ScriptBlock)
            if ($ScriptBlock.ToString() -match 'Get-WindowsImage') {
                [pscustomobject]@{ ImageIndex = 1 }
                [pscustomobject]@{ ImageIndex = 2 }
            }
            else {
                Set-Content -LiteralPath $script:wimOut -Value 'wim'
            }
        }
        Convert-WinMediaEsdToWim -SourceEsd $esd -DestinationWim $wim -Config (& $script:newCfg '')
        # 1 次 Get-WindowsImage + 2 次 Export-WindowsImage
        Should -Invoke -ModuleName WinMediaEsd Invoke-WinMediaDism -Times 3 -Exactly
        Should -Invoke -ModuleName WinMediaEsd Invoke-WinMediaDism -Times 2 -Exactly -ParameterFilter { $ScriptBlock.ToString() -match 'Export-WindowsImage' }
        Should -Invoke -ModuleName WinMediaEsd Invoke-WinMediaWimlib -Times 0 -Exactly
        Test-Path -LiteralPath $esd | Should -BeFalse
    }

    It '輸出檔不存在時 throw，且保留來源 ESD' {
        $esd = Join-Path $TestDrive 'n-install.esd'
        Set-Content -LiteralPath $esd -Value 'esd'
        { Convert-WinMediaEsdToWim -SourceEsd $esd -DestinationWim (Join-Path $TestDrive 'n-install.wim') -Config (& $script:newCfg (Join-Path $TestDrive 'fake.exe')) } |
            Should -Throw '*ESD 轉換後找不到輸出檔*'
        Test-Path -LiteralPath $esd | Should -BeTrue
    }

    It '目的 WIM 已存在時先刪除再轉換' {
        $esd = Join-Path $TestDrive 'o-install.esd'
        $wim = Join-Path $TestDrive 'o-install.wim'
        Set-Content -LiteralPath $esd -Value 'esd'
        Set-Content -LiteralPath $wim -Value 'stale'
        # wimlib mock 不產生檔案：若舊檔沒被先刪除，後面的存在檢查會誤通過
        { Convert-WinMediaEsdToWim -SourceEsd $esd -DestinationWim $wim -Config (& $script:newCfg (Join-Path $TestDrive 'fake.exe')) } |
            Should -Throw '*ESD 轉換後找不到輸出檔*'
        Test-Path -LiteralPath $wim | Should -BeFalse
    }
}

Describe 'Export-WinMediaEsd' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName WinMediaEsd Invoke-WinMediaOperation { param($ScriptBlock) & $ScriptBlock }
        Mock -ModuleName WinMediaEsd Invoke-WinMediaWimlib { }
    }

    It '以 LZMS solid 匯出並刪除來源 WIM' {
        $wim = Join-Path $TestDrive 'e-install.wim'
        $esd = Join-Path $TestDrive 'e-install.esd'
        Set-Content -LiteralPath $wim -Value 'wim'
        Export-WinMediaEsd -SourceWim $wim -DestinationEsd $esd -Config (& $script:newCfg '')
        Should -Invoke -ModuleName WinMediaEsd Invoke-WinMediaWimlib -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -eq 'export' -and $ArgumentList[1] -eq $wim -and $ArgumentList[2] -eq 'all' -and $ArgumentList[3] -eq $esd -and
            $ArgumentList -contains '--compress=LZMS' -and $ArgumentList -contains '--solid'
        }
        Test-Path -LiteralPath $wim | Should -BeFalse
    }

    It 'wimlib 失敗時不刪除來源 WIM' {
        $wim = Join-Path $TestDrive 'f-install.wim'
        Set-Content -LiteralPath $wim -Value 'wim'
        Mock -ModuleName WinMediaEsd Invoke-WinMediaWimlib { throw 'wimlib 失敗' }
        { Export-WinMediaEsd -SourceWim $wim -DestinationEsd (Join-Path $TestDrive 'f-install.esd') -Config (& $script:newCfg '') } | Should -Throw '*wimlib 失敗*'
        Test-Path -LiteralPath $wim | Should -BeTrue
    }
}
