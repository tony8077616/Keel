#Requires -Version 5.1

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Common\WinMediaLog.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\Imaging\WinMediaImage.psm1') -Force
    $script:cfg = @{ DismProvider = 'Inbox'; LogLevel = 'Error'; LogFile = ''; OperationLog = ''; DebugTrace = 0 }
}

Describe 'Mount-WinMediaImage 卸載失敗處理' -Tag 'Unit' {
    BeforeEach {
        # 卸載（Dismount-WindowsImage）拋出，掛載直接成功
        Mock -ModuleName WinMediaImage Invoke-WinMediaDism {
            if ($ScriptBlock.ToString() -match 'Dismount-WindowsImage') { throw 'dismount failed' }
        }
    }

    It 'Action 失敗且卸載也失敗：保留原始錯誤 boom，不被 dismount failed 取代' {
        $mp = Join-Path $TestDrive 'mp-a'
        { Mount-WinMediaImage -ImagePath 'x.wim' -Index 1 -MountPath $mp -Action { throw 'boom' } -Config $script:cfg } | Should -Throw 'boom'
    }

    It 'Action 失敗且卸載也失敗：掛載點目錄保留' {
        $mp = Join-Path $TestDrive 'mp-c'
        { Mount-WinMediaImage -ImagePath 'x.wim' -Index 1 -MountPath $mp -Action { throw 'boom' } -Config $script:cfg } | Should -Throw 'boom'
        Test-Path -LiteralPath $mp | Should -BeTrue
    }

    It 'Action 成功但卸載失敗：拋出 dismount failed' {
        $mp = Join-Path $TestDrive 'mp-b'
        { Mount-WinMediaImage -ImagePath 'x.wim' -Index 1 -MountPath $mp -Action { 'ok' } -Config $script:cfg } | Should -Throw '*dismount failed*'
    }

    It 'Action 成功且卸載成功：不拋出並回傳 Action 的值' {
        Mock -ModuleName WinMediaImage Invoke-WinMediaDism { }
        $mp = Join-Path $TestDrive 'mp-d'
        Mount-WinMediaImage -ImagePath 'x.wim' -Index 1 -MountPath $mp -Action { 'ok' } -Config $script:cfg | Should -Be 'ok'
    }
}
