#Requires -Version 5.1

Import-Module -Name (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Imaging\WinMediaWimlib.psm1') -Force

Describe 'Resolve-WinMediaWimlib 預設快取完整性（zip 校驗 + 逐檔雜湊 + 拒絕多餘檔）' -Tag 'Unit' {
    InModuleScope WinMediaWimlib {
        BeforeAll {
            # 以真實檔案組出假的 wimlib 發行包；規格改指向它，不連網
            $script:src = Join-Path -Path $TestDrive -ChildPath 'src'
            New-Item -ItemType Directory -Path $script:src -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $script:src 'wimlib-imagex.exe'), 'genuine-exe')
            [System.IO.File]::WriteAllText((Join-Path $script:src 'libwim-15.dll'), 'genuine-dll')
            $script:zipSrc = Join-Path -Path $TestDrive -ChildPath 'fake-wimlib.zip'
            Compress-Archive -Path (Join-Path $script:src '*') -DestinationPath $script:zipSrc -Force
            $script:zipHash = (Get-FileHash -LiteralPath $script:zipSrc -Algorithm SHA256).Hash
        }

        BeforeEach {
            Mock Write-WinMediaLog { }
            Mock Invoke-WinMediaOperation { param([scriptblock]$ScriptBlock) & $ScriptBlock }
            Mock Invoke-WebRequest { }
            Mock Get-WinMediaWimlibSpec {
                [pscustomobject]@{ Version = 'test'; Architecture = 'x86_64'; FileName = 'fake-wimlib.zip'; Url = 'https://example.invalid/fake-wimlib.zip'; Sha256 = $script:zipHash }
            }
            $script:oldLocal = $env:LOCALAPPDATA
            $env:LOCALAPPDATA = Join-Path -Path $TestDrive -ChildPath ('local-' + [guid]::NewGuid().ToString('N'))
            $script:toolDir = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'WinMediaRefresh\tools\wimlib-1.14.5'
            $script:exe = Join-Path -Path $script:toolDir -ChildPath 'wimlib-imagex.exe'
            $script:config = @{ Wimlib = @{ Path = '' }; WorkDir = (Join-Path $TestDrive 'work') }
            # 快取內完整內容：zip 本身 + 解壓內容
            New-Item -ItemType Directory -Path $script:toolDir -Force | Out-Null
            Copy-Item -LiteralPath $script:zipSrc -Destination $script:toolDir
            Copy-Item -Path (Join-Path $script:src '*') -Destination $script:toolDir
        }

        AfterEach {
            $env:LOCALAPPDATA = $script:oldLocal
        }

        It '快取完整時命中，不重新下載也不重新解壓' {
            Mock Expand-Archive { }
            Resolve-WinMediaWimlib -Config $script:config | Should -Be $script:exe
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Expand-Archive -Times 0 -Exactly
        }

        It 'exe 被竄改時刪除快取並從已驗證的 zip 重新解壓（不連網）' {
            [System.IO.File]::WriteAllText($script:exe, 'EVIL')
            Resolve-WinMediaWimlib -Config $script:config | Should -Be $script:exe
            [System.IO.File]::ReadAllText($script:exe) | Should -Be 'genuine-exe'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It '多出 zip 沒有的 DLL 時重新解壓並移除該 DLL' {
            $evil = Join-Path -Path $script:toolDir -ChildPath 'version.dll'
            [System.IO.File]::WriteAllText($evil, 'EVIL')
            Resolve-WinMediaWimlib -Config $script:config | Should -Be $script:exe
            Test-Path -LiteralPath $evil | Should -BeFalse
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It '快取 zip 本身被竄改時，改走下載流程重新取得' {
            [System.IO.File]::WriteAllText((Join-Path $script:toolDir 'fake-wimlib.zip'), 'junk')
            Mock Invoke-WebRequest { param([string]$OutFile) Copy-Item -LiteralPath $script:zipSrc -Destination $OutFile -Force }
            Resolve-WinMediaWimlib -Config $script:config | Should -Be $script:exe
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
            (Get-FileHash -LiteralPath (Join-Path $script:toolDir 'fake-wimlib.zip')).Hash | Should -Be $script:zipHash
        }
    }
}
