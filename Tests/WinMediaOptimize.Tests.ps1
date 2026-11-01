#Requires -Version 5.1

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Common\WinMediaLog.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\Imaging\WinMediaOptimize.psm1') -Force
    $script:cfg = @{ DismProvider = 'Inbox'; DismLogLevel = 'Errors'; LogLevel = 'Error'; LogFile = ''; OperationLog = ''; DebugTrace = 0 }
    # pwsh 7 尚未載入 DISM：在模組範圍放一個同名替身，再 Mock 它
    InModuleScope WinMediaOptimize {
        function Optimize-WindowsImage {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = '測試替身，隨即被 Mock')]
            [CmdletBinding()]
            param($Path, $OptimizationTarget, $WindowsDirectory, $SystemDrive, $ScratchDirectory, $LogLevel)
            $PSBoundParameters | Out-Null
        }
    }
}

Describe 'Optimize-WinMediaImage' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName WinMediaOptimize Invoke-WinMediaDism { param($ScriptBlock) & $ScriptBlock }
        Mock -ModuleName WinMediaOptimize Optimize-WindowsImage { }
    }

    It '只呼叫 Invoke-WinMediaDism 一次，並原樣傳遞 Path／OptimizationTarget／LogLevel' {
        Optimize-WinMediaImage -Path 'D:\m' -OptimizationTarget 'WIMBoot' -Config $script:cfg
        Should -Invoke -ModuleName WinMediaOptimize Invoke-WinMediaDism -Times 1 -Exactly
        Should -Invoke -ModuleName WinMediaOptimize Optimize-WindowsImage -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'D:\m' -and $OptimizationTarget -eq 'WIMBoot' -and $LogLevel -eq 'Errors'
        }
    }

    It '未設定任何選項時不帶 ScratchDirectory／WindowsDirectory／SystemDrive' {
        Optimize-WinMediaImage -Path 'D:\m' -OptimizationTarget 'WIMBoot' -Config $script:cfg
        Should -Invoke -ModuleName WinMediaOptimize Optimize-WindowsImage -Times 1 -Exactly -ParameterFilter {
            -not $PesterBoundParameters.ContainsKey('ScratchDirectory') -and
            -not $PesterBoundParameters.ContainsKey('WindowsDirectory') -and
            -not $PesterBoundParameters.ContainsKey('SystemDrive')
        }
    }

    It '設定 ScratchDirectory 時才帶入' {
        $c = $script:cfg.Clone(); $c.ScratchDirectory = 'D:\Scratch'
        Optimize-WinMediaImage -Path 'D:\m' -OptimizationTarget 'WIMBoot' -Config $c
        Should -Invoke -ModuleName WinMediaOptimize Optimize-WindowsImage -Times 1 -Exactly -ParameterFilter {
            $ScratchDirectory -eq 'D:\Scratch' -and $PesterBoundParameters.ContainsKey('ScratchDirectory')
        }
    }

    It '給定 WindowsDirectory 與 SystemDrive 時才帶入' {
        Optimize-WinMediaImage -Path 'D:\m' -OptimizationTarget 'WIMBoot' -WindowsDirectory 'Windows' -SystemDrive 'C:' -Config $script:cfg
        Should -Invoke -ModuleName WinMediaOptimize Optimize-WindowsImage -Times 1 -Exactly -ParameterFilter {
            $WindowsDirectory -eq 'Windows' -and $SystemDrive -eq 'C:'
        }
    }
}
