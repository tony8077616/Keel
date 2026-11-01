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
        Mock -ModuleName WinMediaEsd Invoke-WinMediaWimlib { if ($ArgumentList[0] -eq 'export') { Set-Content -LiteralPath $ArgumentList[3] -Value 'esd' } }
        Mock -ModuleName WinMediaEsd Get-WinMediaImageCount { 2 }
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

    It '預設（映像數相符）刪除來源 WIM' {
        $wim = Join-Path $TestDrive 'm-install.wim'
        Set-Content -LiteralPath $wim -Value 'wim'
        Export-WinMediaEsd -SourceWim $wim -DestinationEsd (Join-Path $TestDrive 'm-install.esd') -Config (& $script:newCfg '')
        Should -Invoke -ModuleName WinMediaEsd Get-WinMediaImageCount -Times 2 -Exactly
        Test-Path -LiteralPath $wim | Should -BeFalse
    }

    It '映像數不符時 throw 並保留來源 WIM' {
        $wim = Join-Path $TestDrive 'x-install.wim'
        Set-Content -LiteralPath $wim -Value 'wim'
        Mock -ModuleName WinMediaEsd Get-WinMediaImageCount { if ($Path -like '*.wim') { 3 } else { 2 } }
        { Export-WinMediaEsd -SourceWim $wim -DestinationEsd (Join-Path $TestDrive 'x-install.esd') -Config (& $script:newCfg '') } | Should -Throw '*映像數*'
        Test-Path -LiteralPath $wim | Should -BeTrue
    }

    It '輸出 ESD 不存在時 throw 並保留來源 WIM' {
        $wim = Join-Path $TestDrive 'y-install.wim'
        Set-Content -LiteralPath $wim -Value 'wim'
        Mock -ModuleName WinMediaEsd Invoke-WinMediaWimlib { }
        { Export-WinMediaEsd -SourceWim $wim -DestinationEsd (Join-Path $TestDrive 'y-install.esd') -Config (& $script:newCfg '') } | Should -Throw '*找不到輸出檔*'
        Test-Path -LiteralPath $wim | Should -BeTrue
    }

    It '-KeepSource 時保留來源 WIM' {
        $wim = Join-Path $TestDrive 'k-install.wim'
        Set-Content -LiteralPath $wim -Value 'wim'
        Export-WinMediaEsd -SourceWim $wim -DestinationEsd (Join-Path $TestDrive 'k-install.esd') -Config (& $script:newCfg '') -KeepSource
        Test-Path -LiteralPath $wim | Should -BeTrue
    }
}

Describe 'Convert-WinMediaEsdToWim -KeepSource' -Tag 'Unit' {
    It '-KeepSource 時保留來源 ESD' {
        Mock -ModuleName WinMediaEsd Invoke-WinMediaOperation { param($ScriptBlock) & $ScriptBlock }
        $esd = Join-Path $TestDrive 'ks-install.esd'
        $wim = Join-Path $TestDrive 'ks-install.wim'
        Set-Content -LiteralPath $esd -Value 'esd'
        $script:wimOut = $wim
        Mock -ModuleName WinMediaEsd Invoke-WinMediaWimlib { Set-Content -LiteralPath $script:wimOut -Value 'wim' }
        Convert-WinMediaEsdToWim -SourceEsd $esd -DestinationWim $wim -Config (& $script:newCfg (Join-Path $TestDrive 'fake.exe')) -KeepSource
        Test-Path -LiteralPath $esd | Should -BeTrue
        Test-Path -LiteralPath $wim | Should -BeTrue
    }
}

Describe 'Convert-WinMediaEsdToWim DISM 路徑的 ScratchDirectory 接線' -Tag 'Unit' {
    # Export 區塊以 GetNewClosure 建立，其中的命令從全域解析，-ModuleName Mock 攔不到；
    # 因此以全域函式替身取代 DISM cmdlet，讓 scriptblock 真正執行並記錄實際綁定的參數。
    BeforeAll {
        $script:dismCalls = [System.Collections.Generic.List[hashtable]]::new()
        $calls = $script:dismCalls
        $script:stubbed = @('Get-WindowsImage', 'Export-WindowsImage') | Where-Object { -not (Test-Path -LiteralPath "function:global:$_") }
        Set-Item -Path 'function:global:Get-WindowsImage' -Value ({
            param($ImagePath, $LogLevel, $ScratchDirectory)
            $null = $ImagePath, $LogLevel, $ScratchDirectory
            $calls.Add(@{ Bound = $PSBoundParameters })
            [pscustomobject]@{ ImageIndex = 1 }
        }.GetNewClosure())
        Set-Item -Path 'function:global:Export-WindowsImage' -Value ({
            param($SourceImagePath, $SourceIndex, $DestinationImagePath, $CompressionType, $LogLevel, $ScratchDirectory)
            $null = $SourceImagePath, $SourceIndex, $DestinationImagePath, $CompressionType, $LogLevel, $ScratchDirectory
            $calls.Add(@{ Bound = $PSBoundParameters })
        }.GetNewClosure())
    }

    AfterAll {
        foreach ($name in $script:stubbed) { Remove-Item -Path "function:global:$name" -ErrorAction SilentlyContinue }
    }

    BeforeEach {
        $script:dismCalls.Clear()
        Mock -ModuleName WinMediaEsd Invoke-WinMediaOperation { }
        Mock -ModuleName WinMediaEsd Invoke-WinMediaDism { param($ScriptBlock) & $ScriptBlock }
    }

    It '設定 ScratchDirectory 時 Get 與 Export 兩段 DISM 呼叫都實際帶入該值' {
        Mock -ModuleName WinMediaEsd Get-WinMediaDismCommonParameter { @{ ScratchDirectory = 'D:\Scratch' } }
        $esd = Join-Path $TestDrive 'sc-install.esd'
        $wim = Join-Path $TestDrive 'sc-install.wim'
        Set-Content -LiteralPath $esd -Value 'esd'
        Set-Content -LiteralPath $wim -Value 'wim'
        $cfg = & $script:newCfg ''
        $cfg.DismLogLevel = 'WarningsInfo'
        Convert-WinMediaEsdToWim -SourceEsd $esd -DestinationWim $wim -Config $cfg
        $script:dismCalls.Count | Should -Be 2
        foreach ($c in $script:dismCalls) { $c.Bound.ScratchDirectory | Should -Be 'D:\Scratch' }
    }

    It '未設定 ScratchDirectory 時兩段 DISM 呼叫都不帶該鍵' {
        Mock -ModuleName WinMediaEsd Get-WinMediaDismCommonParameter { @{} }
        $esd = Join-Path $TestDrive 'nsc-install.esd'
        $wim = Join-Path $TestDrive 'nsc-install.wim'
        Set-Content -LiteralPath $esd -Value 'esd'
        Set-Content -LiteralPath $wim -Value 'wim'
        $cfg = & $script:newCfg ''
        $cfg.DismLogLevel = 'WarningsInfo'
        Convert-WinMediaEsdToWim -SourceEsd $esd -DestinationWim $wim -Config $cfg
        $script:dismCalls.Count | Should -Be 2
        foreach ($c in $script:dismCalls) { $c.Bound.ContainsKey('ScratchDirectory') | Should -BeFalse }
    }
}

Describe 'Get-WinMediaImageCount' -Tag 'Unit' {
    BeforeEach {
        $script:infoCfg = @{ Wimlib = @{ Path = (Join-Path $TestDrive 'fake.exe') }; DismProvider = 'Inbox'; LogLevel = 'Error'; LogFile = ''; OperationLog = ''; DebugTrace = 0 }
    }

    It '解析 Image Count 行' {
        Mock -ModuleName WinMediaEsd Invoke-WinMediaWimlib { [pscustomobject]@{ ExitCode = 0; StdOut = "WIM info`r`n   Image Count:    2`r`n"; StdErr = '' } }
        InModuleScope WinMediaEsd -Parameters @{ c = $script:infoCfg } { param($c) Get-WinMediaImageCount -Path 'x.wim' -Config $c } | Should -Be 2
    }

    It '缺少 Image Count 行時 throw' {
        Mock -ModuleName WinMediaEsd Invoke-WinMediaWimlib { [pscustomobject]@{ ExitCode = 0; StdOut = 'no header here'; StdErr = '' } }
        { InModuleScope WinMediaEsd -Parameters @{ c = $script:infoCfg } { param($c) Get-WinMediaImageCount -Path 'x.wim' -Config $c } } |
            Should -Throw '*無法從 wimlib info 取得映像數*'
    }
}

Describe 'Export-WinMediaEsd 映像數小於 1' -Tag 'Unit' {
    It '來源映像數為 0 時 throw 並保留來源 WIM' {
        Mock -ModuleName WinMediaEsd Invoke-WinMediaOperation { param($ScriptBlock) & $ScriptBlock }
        Mock -ModuleName WinMediaEsd Invoke-WinMediaWimlib { if ($ArgumentList[0] -eq 'export') { Set-Content -LiteralPath $ArgumentList[3] -Value 'esd' } }
        Mock -ModuleName WinMediaEsd Get-WinMediaImageCount { 0 }
        $wim = Join-Path $TestDrive 'z-install.wim'
        Set-Content -LiteralPath $wim -Value 'wim'
        { Export-WinMediaEsd -SourceWim $wim -DestinationEsd (Join-Path $TestDrive 'z-install.esd') -Config (& $script:newCfg '') } | Should -Throw '*小於 1*'
        Test-Path -LiteralPath $wim | Should -BeTrue
    }
}
