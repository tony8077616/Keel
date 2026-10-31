#Requires -Version 5.1

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Common\WinMediaLog.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\Imaging\WinMediaImage.psm1') -Force
    $script:cfg = @{ DismProvider = 'Inbox'; LogLevel = 'Error'; LogFile = ''; OperationLog = ''; DebugTrace = 0 }
    # DISM Cmdlet 在 pwsh 7 未載入時以全域 stub 供 Mock 使用
    foreach ($n in 'Get-WindowsImage', 'Dismount-WindowsImage', 'Clear-WindowsCorruptMountPoint') {
        if (-not (Get-Command $n -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$n" -Value { param([switch]$Mounted, $Path, [switch]$Discard, $LogLevel, $ScratchDirectory, [switch]$ErrorAction) $null = $Mounted, $Path, $Discard, $LogLevel, $ScratchDirectory, $ErrorAction }
        }
    }
}

Describe 'Get-WinMediaMountState' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName WinMediaImage Invoke-WinMediaDism { param($Provider, $Config, $ScriptBlock); $null = $Provider; $Config.DismLogLevel = 'Errors'; & $ScriptBlock }
    }

    It '<value> 對應 <expected>' -ForEach @(
        @{ value = 'Ok'; expected = 'OK' }
        @{ value = 0; expected = 'OK' }
        @{ value = 'NeedsRemount'; expected = 'NeedsRemount' }
        @{ value = 1; expected = 'NeedsRemount' }
        @{ value = 'Invalid'; expected = 'Invalid' }
        @{ value = 2; expected = 'Invalid' }
        @{ value = 'Weird'; expected = 'Unknown' }
    ) {
        $status = $value
        Mock -ModuleName WinMediaImage Get-WindowsImage { [pscustomobject]@{ Path = 'C:\mnt\'; MountStatus = $status } }.GetNewClosure()
        Get-WinMediaMountState -Path 'c:\MNT' -Config $script:cfg | Should -Be $expected
    }

    It '找不到該路徑：Unknown' {
        Mock -ModuleName WinMediaImage Get-WindowsImage { [pscustomobject]@{ Path = 'C:\other'; MountStatus = 0 } }
        Get-WinMediaMountState -Path 'C:\mnt' -Config $script:cfg | Should -Be 'Unknown'
    }

    It 'Get-WindowsImage 拋出：Unknown 並記錄警告' {
        Mock -ModuleName WinMediaImage Get-WindowsImage { throw 'no admin' }
        Mock -ModuleName WinMediaImage Write-WinMediaLog { }
        Get-WinMediaMountState -Path 'C:\mnt' -Config $script:cfg | Should -Be 'Unknown'
        Should -Invoke -ModuleName WinMediaImage Write-WinMediaLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' }
    }

    It '缺少 MountStatus 屬性：Unknown' {
        Mock -ModuleName WinMediaImage Get-WindowsImage { [pscustomobject]@{ Path = 'C:\mnt' } }
        Get-WinMediaMountState -Path 'C:\mnt' -Config $script:cfg | Should -Be 'Unknown'
    }

    It '經由 Invoke-WinMediaDism 呼叫（依 DismProvider 分派）' {
        Mock -ModuleName WinMediaImage Get-WindowsImage { [pscustomobject]@{ Path = 'C:\mnt'; MountStatus = 0 } }
        Get-WinMediaMountState -Path 'C:\mnt' -Config $script:cfg | Out-Null
        Should -Invoke -ModuleName WinMediaImage Invoke-WinMediaDism -Times 1 -Exactly
        Should -Invoke -ModuleName WinMediaImage Get-WindowsImage -Times 1 -Exactly
    }
}

Describe 'Clear-WinMediaMount' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName WinMediaImage Invoke-WinMediaDism { param($Provider, $Config, $ScriptBlock); $null = $Provider; $Config.DismLogLevel = 'Errors'; & $ScriptBlock }
        Mock -ModuleName WinMediaImage Dismount-WindowsImage { }
        Mock -ModuleName WinMediaImage Clear-WindowsCorruptMountPoint { }
        Mock -ModuleName WinMediaImage Get-WinMediaLoadedHive { [string[]]@('WinMedia_SYS', 'WinMediaBootSW') }
        Mock -ModuleName WinMediaImage Invoke-WinMediaRegUnload { }
        Mock -ModuleName WinMediaImage Write-WinMediaLog { }
    }

    It '-WhatIf：不卸載、不清理、不卸載登錄檔' {
        Clear-WinMediaMount -MountPath 'C:\a', 'C:\b' -Config $script:cfg -WhatIf
        Should -Invoke -ModuleName WinMediaImage Invoke-WinMediaDism -Exactly 0
        Should -Invoke -ModuleName WinMediaImage Dismount-WindowsImage -Exactly 0
        Should -Invoke -ModuleName WinMediaImage Invoke-WinMediaRegUnload -Exactly 0
    }

    It '正常：每個路徑 Discard 卸載，並卸載兩個登錄檔' {
        Clear-WinMediaMount -MountPath 'C:\a', 'C:\b' -Config $script:cfg
        Should -Invoke -ModuleName WinMediaImage Dismount-WindowsImage -Exactly 2 -ParameterFilter { $Discard }
        Should -Invoke -ModuleName WinMediaImage Invoke-WinMediaRegUnload -Exactly 2
        Should -Invoke -ModuleName WinMediaImage Clear-WindowsCorruptMountPoint -Exactly 0
    }

    It 'Dismount 失敗：改呼叫 Clear-WindowsCorruptMountPoint，只記警告不拋出，繼續下一個路徑' {
        Mock -ModuleName WinMediaImage Dismount-WindowsImage { throw 'busy' }
        { Clear-WinMediaMount -MountPath 'C:\a', 'C:\b' -Config $script:cfg } | Should -Not -Throw
        Should -Invoke -ModuleName WinMediaImage Clear-WindowsCorruptMountPoint -Exactly 2
        Should -Invoke -ModuleName WinMediaImage Write-WinMediaLog -ParameterFilter { $Level -eq 'Warning' }
    }

    It '設定 ScratchDirectory 時 Dismount 收到 -ScratchDirectory' {
        $cfg = $script:cfg.Clone(); $cfg.ScratchDirectory = 'D:\scratch'
        Clear-WinMediaMount -MountPath 'C:\a' -Config $cfg
        Should -Invoke -ModuleName WinMediaImage Dismount-WindowsImage -Exactly 1 -ParameterFilter { $ScratchDirectory -eq 'D:\scratch' }
    }
}
