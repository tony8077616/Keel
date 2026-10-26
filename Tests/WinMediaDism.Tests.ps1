#Requires -Version 5.1

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Imaging\WinMediaDism.psm1') -Force
    $script:cfg = @{ DismProvider = 'Inbox'; LogLevel = 'Error'; LogFile = ''; OperationLog = ''; DebugTrace = 0 }
}

Describe 'Invoke-WinMediaDism 操作名稱' -Tag 'Unit' {
    BeforeEach {
        $script:captured = $null
        Mock -ModuleName WinMediaDism Invoke-WinMediaOperation {
            param($Category, $Operation, $Target, $ScriptBlock, $Config)
            # 簽章需要接收全部參數；只記錄 Operation，不執行 ScriptBlock（避免真的呼叫 DISM Cmdlet）
            $null = $Category, $Target, $ScriptBlock, $Config
            $script:captured = $Operation
        }
    }

    It '取第一個命令名稱 Mount-WindowsImage' {
        Invoke-WinMediaDism -Provider Inbox -Config $script:cfg -ScriptBlock { Mount-WindowsImage -ImagePath 'x.wim' -Index 1 -Path 'C:\m' } | Out-Null
        $script:captured | Should -Be 'Mount-WindowsImage'
    }

    It '無命令時退回 Provider（Inbox）' {
        Invoke-WinMediaDism -Provider Inbox -Config $script:cfg -ScriptBlock { 'x' } | Out-Null
        $script:captured | Should -Be 'Inbox'
    }

    It '多個命令時取第一個（Get-WindowsImage）' {
        Invoke-WinMediaDism -Provider Inbox -Config $script:cfg -ScriptBlock { Get-WindowsImage -ImagePath 'x.wim'; Get-WindowsEdition -Path 'C:\m' } | Out-Null
        $script:captured | Should -Be 'Get-WindowsImage'
    }
}
