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

Describe 'ConvertTo-WinMediaFilePath' -Tag 'Unit' {
    It '裝置路徑依對照表轉成 DOS 路徑；前綴需以分隔符界定；對照不到回傳空字串' {
        InModuleScope WinMediaImage {
            $map = @{ '\Device\HarddiskVolume5' = 'C:'; '\Device\HarddiskVolume50' = 'D:' }
            ConvertTo-WinMediaFilePath -DevicePath '\Device\HarddiskVolume5\Windows\x' -DeviceMap $map | Should -Be 'C:\Windows\x'
            ConvertTo-WinMediaFilePath -DevicePath '\Device\HarddiskVolume50\a' -DeviceMap $map | Should -Be 'D:\a'
            ConvertTo-WinMediaFilePath -DevicePath '\Device\HarddiskVolume9\a' -DeviceMap $map | Should -Be ''
            ConvertTo-WinMediaFilePath -DevicePath '' -DeviceMap $map | Should -Be ''
        }
    }
}

Describe 'Get-WinMediaLoadedHiveFile' -Tag 'Unit' {
    It '只取 HKLM 之下的項目，並轉成 DOS 路徑' {
        Mock -ModuleName WinMediaImage Get-ItemProperty {
            [pscustomobject]@{
                '\REGISTRY\MACHINE\SYSTEM' = '\Device\HarddiskVolume5\Windows\System32\config\SYSTEM'
                '\REGISTRY\MACHINE\HARDWARE' = ''
                '\REGISTRY\USER\.DEFAULT' = '\Device\HarddiskVolume5\Windows\System32\config\DEFAULT'
            }
        }
        Mock -ModuleName WinMediaImage Get-WinMediaDosDeviceMap { @{ '\Device\HarddiskVolume5' = 'C:' } }
        InModuleScope WinMediaImage {
            $rows = @(Get-WinMediaLoadedHiveFile)
            $rows.Count | Should -Be 2
            ($rows | Where-Object { $_.Name -eq 'SYSTEM' }).File | Should -Be 'C:\Windows\System32\config\SYSTEM'
        }
    }
}

Describe 'Clear-WinMediaMount' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName WinMediaImage Invoke-WinMediaDism { param($Provider, $Config, $ScriptBlock); $null = $Provider; $Config.DismLogLevel = 'Errors'; & $ScriptBlock }
        Mock -ModuleName WinMediaImage Dismount-WindowsImage { }
        Mock -ModuleName WinMediaImage Clear-WindowsCorruptMountPoint { }
        Mock -ModuleName WinMediaImage Get-WinMediaLoadedHiveFile {
            @(
                [pscustomobject]@{ Name = 'WinMedia_SYS'; File = 'C:\a\Windows\System32\config\SYSTEM' }
                [pscustomobject]@{ Name = 'WinMediaBootSW'; File = 'C:\b\Windows\System32\config\SOFTWARE' }
                [pscustomobject]@{ Name = 'SOFTWARE'; File = 'C:\Windows\System32\config\SOFTWARE' }
                [pscustomobject]@{ Name = 'WinMedia_A10'; File = 'C:\a10\Windows\System32\config\SYSTEM' }
                [pscustomobject]@{ Name = 'WinMedia_NoMap'; File = '' }
            )
        }
        Mock -ModuleName WinMediaImage Invoke-WinMediaRegUnload { }
        Mock -ModuleName WinMediaImage Write-WinMediaLog { }
    }

    It '-WhatIf：不卸載、不清理、不卸載登錄檔' {
        Clear-WinMediaMount -MountPath 'C:\a', 'C:\b' -Config $script:cfg -WhatIf
        Should -Invoke -ModuleName WinMediaImage Invoke-WinMediaDism -Exactly 0
        Should -Invoke -ModuleName WinMediaImage Dismount-WindowsImage -Exactly 0
        Should -Invoke -ModuleName WinMediaImage Invoke-WinMediaRegUnload -Exactly 0
    }

    It '正常：每個路徑 Discard 卸載，並只卸載檔案位於掛載點之下的兩個登錄檔' {
        Clear-WinMediaMount -MountPath 'C:\a', 'C:\b' -Config $script:cfg
        Should -Invoke -ModuleName WinMediaImage Dismount-WindowsImage -Exactly 2 -ParameterFilter { $Discard }
        Should -Invoke -ModuleName WinMediaImage Invoke-WinMediaRegUnload -Exactly 2
        Should -Invoke -ModuleName WinMediaImage Invoke-WinMediaRegUnload -Exactly 1 -ParameterFilter { $Name -eq 'WinMedia_SYS' }
        Should -Invoke -ModuleName WinMediaImage Invoke-WinMediaRegUnload -Exactly 1 -ParameterFilter { $Name -eq 'WinMediaBootSW' }
        Should -Invoke -ModuleName WinMediaImage Clear-WindowsCorruptMountPoint -Exactly 0
    }

    It '系統 hive、前綴相同的 install-10 類路徑、無對照檔案的 hive 都不卸載' {
        Clear-WinMediaMount -MountPath 'C:\a1' -Config $script:cfg
        Should -Invoke -ModuleName WinMediaImage Invoke-WinMediaRegUnload -Exactly 0
    }

    It 'hivelist 讀取失敗：不卸載任何登錄檔、只記警告，仍照常 Discard' {
        Mock -ModuleName WinMediaImage Get-WinMediaLoadedHiveFile { throw 'hivelist 不可讀' }
        { Clear-WinMediaMount -MountPath 'C:\a' -Config $script:cfg } | Should -Not -Throw
        Should -Invoke -ModuleName WinMediaImage Invoke-WinMediaRegUnload -Exactly 0
        Should -Invoke -ModuleName WinMediaImage Dismount-WindowsImage -Exactly 1 -ParameterFilter { $Discard }
    }

    It 'Dismount 失敗：改呼叫 Clear-WindowsCorruptMountPoint，只記警告不拋出，繼續下一個路徑' {
        Mock -ModuleName WinMediaImage Dismount-WindowsImage { throw 'busy' }
        { Clear-WinMediaMount -MountPath 'C:\a', 'C:\b' -Config $script:cfg } | Should -Not -Throw
        Should -Invoke -ModuleName WinMediaImage Clear-WindowsCorruptMountPoint -Exactly 1
        Should -Invoke -ModuleName WinMediaImage Write-WinMediaLog -ParameterFilter { $Level -eq 'Warning' }
    }

    It 'Dismount 只有一個路徑失敗：Clear-WindowsCorruptMountPoint 仍只呼叫一次' {
        Mock -ModuleName WinMediaImage Dismount-WindowsImage { throw 'busy' } -ParameterFilter { $Path -eq 'C:\a' }
        Clear-WinMediaMount -MountPath 'C:\a', 'C:\b' -Config $script:cfg
        Should -Invoke -ModuleName WinMediaImage Dismount-WindowsImage -Exactly 2
        Should -Invoke -ModuleName WinMediaImage Clear-WindowsCorruptMountPoint -Exactly 1
    }

    It '設定 ScratchDirectory 時 Dismount 收到 -ScratchDirectory' {
        $cfg = $script:cfg.Clone(); $cfg.ScratchDirectory = 'D:\scratch'
        Clear-WinMediaMount -MountPath 'C:\a' -Config $cfg
        Should -Invoke -ModuleName WinMediaImage Dismount-WindowsImage -Exactly 1 -ParameterFilter { $ScratchDirectory -eq 'D:\scratch' }
    }
}
