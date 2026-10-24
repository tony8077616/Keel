#Requires -Version 5.1

Import-Module -Name (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Imaging\WinMediaEsd.psm1') -Force

Describe 'Export-WinMediaEsd（目的檔已存在時先移除）' -Tag 'Unit' {
    BeforeAll {
        $script:cfg = @{ LogLevel = 'Error'; OperationLog = ''; DebugTrace = 0; LogFile = (Join-Path -Path $TestDrive -ChildPath 'esd.log') }
    }

    It '既有 install.esd 在 wimlib export 之前已被移除，不會附加到舊檔' {
        $dir = Join-Path -Path $TestDrive -ChildPath 'esd-force'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $wim = Join-Path -Path $dir -ChildPath 'install.wim'
        $esd = Join-Path -Path $dir -ChildPath 'install.esd'
        $flag = Join-Path -Path $dir -ChildPath 'existed-at-export.txt'
        [System.IO.File]::WriteAllText($wim, 'wim-payload')
        [System.IO.File]::WriteAllText($esd, 'old-esd')

        Mock -ModuleName WinMediaEsd Invoke-WinMediaWimlib {
            [System.IO.File]::WriteAllText((Join-Path -Path $TestDrive -ChildPath 'esd-force\existed-at-export.txt'), [string](Test-Path -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'esd-force\install.esd')))
        }

        Export-WinMediaEsd -SourceWim $wim -DestinationEsd $esd -Config $script:cfg
        [System.IO.File]::ReadAllText($flag) | Should -Be 'False'
    }
}
