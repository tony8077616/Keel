#Requires -Version 5.1

Import-Module -Name (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Imaging\WinMediaDism.psm1') -Force

Describe 'Get-WinMediaDismCommonParameter' -Tag 'Unit' {
    It '空設定回傳空 hashtable' {
        $r = Get-WinMediaDismCommonParameter -Config @{}
        $r | Should -BeOfType [hashtable]
        $r.Count | Should -Be 0
    }

    It '設定 ScratchDirectory 時回傳該鍵與值' {
        $r = Get-WinMediaDismCommonParameter -Config @{ ScratchDirectory = 'D:\Scratch' }
        $r.Count | Should -Be 1
        $r.ScratchDirectory | Should -Be 'D:\Scratch'
    }

    It '空字串回傳空 hashtable' {
        $r = Get-WinMediaDismCommonParameter -Config @{ ScratchDirectory = '' }
        $r | Should -BeOfType [hashtable]
        $r.Count | Should -Be 0
    }

    It '僅空白字元回傳空 hashtable' {
        $r = Get-WinMediaDismCommonParameter -Config @{ ScratchDirectory = '   ' }
        $r | Should -BeOfType [hashtable]
        $r.Count | Should -Be 0
    }

    It '不洩漏 LogLevel 與 DismLogLevel 鍵' {
        $r = Get-WinMediaDismCommonParameter -Config @{ ScratchDirectory = 'D:\S'; DismLogLevel = 'Debug'; LogLevel = 'Debug' }
        $r.ContainsKey('LogLevel') | Should -BeFalse
        $r.ContainsKey('DismLogLevel') | Should -BeFalse
    }

    It 'Get-Command -Module WinMediaDism 列出此函式' {
        (Get-Command -Module WinMediaDism -Name Get-WinMediaDismCommonParameter) | Should -Not -BeNullOrEmpty
    }
}
