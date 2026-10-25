#Requires -Version 5.1

Import-Module -Name (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Imaging\WinMediaDism.psm1') -Force

Describe 'Invoke-WinMediaDism（Inbox 分支不沿用已載入的 ADK Dism）' -Tag 'Unit' {
    InModuleScope WinMediaDism {
        BeforeAll {
            $script:cfg = @{ DismLogLevel = 'WarningsInfo'; DismUseWindowsPowerShell = $true; DebugTrace = 0; OperationLog = ''; LogLevel = 'Error'; LogFile = ''; LogDir = '' }
        }

        It 'Windows PowerShell 5.1 下，已載入非 Inbox 的 Dism 時拒絕執行' -Skip:($PSVersionTable.PSEdition -eq 'Core') {
            Mock Get-Module { [pscustomobject]@{ Name = 'Dism'; Path = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\DISM\Dism.psd1' } } -ParameterFilter { $Name -eq 'Dism' }
            { Invoke-WinMediaDism -Provider 'Inbox' -ScriptBlock { 'ran' } -Config $script:cfg } | Should -Throw '*Inbox*'
        }

        It 'Windows PowerShell 5.1 下，已載入的 Dism 位於 SystemRoot 時照常執行' -Skip:($PSVersionTable.PSEdition -eq 'Core') {
            Mock Get-Module { [pscustomobject]@{ Name = 'Dism'; Path = (Join-Path -Path $env:SystemRoot -ChildPath 'system32\WindowsPowerShell\v1.0\Modules\Dism\Dism.psd1') } } -ParameterFilter { $Name -eq 'Dism' }
            Invoke-WinMediaDism -Provider 'Inbox' -ScriptBlock { 'ran' } -Config $script:cfg | Should -Be 'ran'
        }
    }
}
