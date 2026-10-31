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

Describe 'Mount-WinMediaImage 掛載選項與 Remount' -Tag 'Unit' {
    BeforeAll {
        # DISM Cmdlet 在 pwsh 7 未載入時以全域 stub 供 Mock 使用
        foreach ($n in 'Mount-WindowsImage', 'Dismount-WindowsImage') {
            if (-not (Get-Command $n -ErrorAction SilentlyContinue)) {
                Set-Item -Path "function:global:$n" -Value {
                    param($ImagePath, $Index, $Path, [switch]$ReadOnly, [switch]$Optimize, [switch]$CheckIntegrity, [switch]$Remount, [switch]$Save, [switch]$Discard, $ScratchDirectory, $LogLevel)
                    $null = $ImagePath, $Index, $Path, $ReadOnly, $Optimize, $CheckIntegrity, $Remount, $Save, $Discard, $ScratchDirectory, $LogLevel
                }
            }
        }
    }
    BeforeEach {
        Mock -ModuleName WinMediaImage Invoke-WinMediaDism { $Config.DismLogLevel = 'Errors'; & $ScriptBlock }
        Mock -ModuleName WinMediaImage Mount-WindowsImage { }
        Mock -ModuleName WinMediaImage Dismount-WindowsImage { }
    }

    It 'Remount 參數集拒絕 -ImagePath（參數繫結錯誤）' {
        $mp = Join-Path $TestDrive 'rm-a'
        { Mount-WinMediaImage -Remount -ImagePath 'x.wim' -MountPath $mp -Action { } -Config $script:cfg } | Should -Throw
    }

    It '未設定選項：Mount-WindowsImage 不帶 Optimize／CheckIntegrity／ScratchDirectory' {
        $mp = Join-Path $TestDrive 'mo-a'
        Mount-WinMediaImage -ImagePath 'x.wim' -Index 1 -MountPath $mp -Action { } -Config $script:cfg
        Should -Invoke -ModuleName WinMediaImage Mount-WindowsImage -Exactly 1 -ParameterFilter {
            -not $PesterBoundParameters.ContainsKey('Optimize') -and -not $PesterBoundParameters.ContainsKey('CheckIntegrity') -and -not $PesterBoundParameters.ContainsKey('ScratchDirectory')
        }
    }

    It '設定 -Optimize／-CheckIntegrity 才帶對應參數' {
        $mp = Join-Path $TestDrive 'mo-b'
        Mount-WinMediaImage -ImagePath 'x.wim' -Index 1 -MountPath $mp -Optimize -CheckIntegrity -Action { } -Config $script:cfg
        Should -Invoke -ModuleName WinMediaImage Mount-WindowsImage -Exactly 1 -ParameterFilter {
            $PesterBoundParameters.ContainsKey('Optimize') -and $PesterBoundParameters.ContainsKey('CheckIntegrity')
        }
    }

    It 'Config.ScratchDirectory 同時帶入 Mount 與 Dismount' {
        $mp = Join-Path $TestDrive 'mo-c'
        $cfg = $script:cfg.Clone(); $cfg.ScratchDirectory = 'D:\scratch'
        Mount-WinMediaImage -ImagePath 'x.wim' -Index 1 -MountPath $mp -Action { } -Config $cfg
        Should -Invoke -ModuleName WinMediaImage Mount-WindowsImage -Exactly 1 -ParameterFilter { $ScratchDirectory -eq 'D:\scratch' }
        Should -Invoke -ModuleName WinMediaImage Dismount-WindowsImage -Exactly 1 -ParameterFilter { $ScratchDirectory -eq 'D:\scratch' }
    }

    It 'Remount：目錄不存在時拋出且不建立目錄，也不呼叫 Mount-WindowsImage' {
        $mp = Join-Path $TestDrive 'rm-missing'
        { Mount-WinMediaImage -Remount -MountPath $mp -Action { } -Config $script:cfg } | Should -Throw '*不存在*'
        Test-Path -LiteralPath $mp | Should -BeFalse
        Should -Invoke -ModuleName WinMediaImage Mount-WindowsImage -Exactly 0
    }

    It 'Remount：目錄存在時只帶 -Remount（不帶 Image／Index／Optimize／ReadOnly），結束後 Save 卸載' {
        $mp = Join-Path $TestDrive 'rm-ok'
        New-Item -ItemType Directory -Path $mp | Out-Null
        Mount-WinMediaImage -Remount -MountPath $mp -Action { } -Config $script:cfg
        Should -Invoke -ModuleName WinMediaImage Mount-WindowsImage -Exactly 1 -ParameterFilter {
            $Remount -and -not $PesterBoundParameters.ContainsKey('ImagePath') -and -not $PesterBoundParameters.ContainsKey('Index') -and -not $PesterBoundParameters.ContainsKey('ReadOnly')
        }
        Should -Invoke -ModuleName WinMediaImage Dismount-WindowsImage -Exactly 1 -ParameterFilter { $Save }
        Test-Path -LiteralPath $mp | Should -BeTrue
    }

    It 'Remount -ReadOnly：只影響卸載（Discard），不傳給 Mount-WindowsImage' {
        $mp = Join-Path $TestDrive 'rm-ro'
        New-Item -ItemType Directory -Path $mp | Out-Null
        Mount-WinMediaImage -Remount -ReadOnly -MountPath $mp -Action { } -Config $script:cfg
        Should -Invoke -ModuleName WinMediaImage Mount-WindowsImage -Exactly 1 -ParameterFilter { -not $PesterBoundParameters.ContainsKey('ReadOnly') }
        Should -Invoke -ModuleName WinMediaImage Dismount-WindowsImage -Exactly 1 -ParameterFilter { $Discard }
    }
}
