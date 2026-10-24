#Requires -Version 5.1

Import-Module -Name (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Imaging\WinMediaWimlib.psm1') -Force

Describe 'Expand-WinMediaWimlibZip（驗證與解壓使用同一份位元組）' -Tag 'Unit' {
    InModuleScope WinMediaWimlib {
        BeforeAll {
            Add-Type -AssemblyName System.IO.Compression
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $script:zip = Join-Path -Path $TestDrive -ChildPath 'fake.zip'
            $fs = [System.IO.File]::Open($script:zip, [System.IO.FileMode]::Create)
            $archive = [System.IO.Compression.ZipArchive]::new($fs, [System.IO.Compression.ZipArchiveMode]::Create)
            $entry = $archive.CreateEntry('wimlib-imagex.exe')
            $writer = New-Object -TypeName System.IO.StreamWriter -ArgumentList $entry.Open()
            $writer.Write('genuine')
            $writer.Dispose()
            $archive.Dispose()
            $fs.Dispose()
            $script:hash = (Get-FileHash -LiteralPath $script:zip -Algorithm SHA256).Hash
        }

        It '雜湊相符時解壓到目的目錄' {
            $dest = Join-Path -Path $TestDrive -ChildPath 'ok'
            Expand-WinMediaWimlibZip -Zip $script:zip -DestinationDir $dest -Sha256 $script:hash
            Test-Path -LiteralPath (Join-Path -Path $dest -ChildPath 'wimlib-imagex.exe') | Should -BeTrue
        }

        It '雜湊不符時拋錯，且不產生任何檔案' {
            $dest = Join-Path -Path $TestDrive -ChildPath 'bad'
            { Expand-WinMediaWimlibZip -Zip $script:zip -DestinationDir $dest -Sha256 ('0' * 64) } | Should -Throw '*SHA-256*'
            Test-Path -LiteralPath $dest | Should -BeFalse
        }
    }
}

Describe 'Resolve-WinMediaWimlib（非預設 Wimlib.Path 不清空既有目錄）' -Tag 'Unit' {
    InModuleScope WinMediaWimlib {
        BeforeAll {
            Add-Type -AssemblyName System.IO.Compression
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $script:ndZip = Join-Path -Path $TestDrive -ChildPath 'nd-fake.zip'
            $fs = [System.IO.File]::Open($script:ndZip, [System.IO.FileMode]::Create)
            $archive = [System.IO.Compression.ZipArchive]::new($fs, [System.IO.Compression.ZipArchiveMode]::Create)
            $entry = $archive.CreateEntry('wimlib-imagex.exe')
            $writer = New-Object -TypeName System.IO.StreamWriter -ArgumentList $entry.Open()
            $writer.Write('genuine')
            $writer.Dispose()
            $archive.Dispose()
            $fs.Dispose()
            $script:ndHash = (Get-FileHash -LiteralPath $script:ndZip -Algorithm SHA256).Hash
        }

        It '目錄含多餘檔案時拒絕解壓，且保留既有檔案（stray.dll）' {
            $custom = Join-Path -Path $TestDrive -ChildPath 'custom'
            New-Item -ItemType Directory -Path $custom -Force | Out-Null
            Set-Content -LiteralPath (Join-Path -Path $custom -ChildPath 'stray.dll') -Value 'x'
            Mock Get-WinMediaWimlibSpec { [pscustomobject]@{ FileName = 'fake.zip'; Url = 'https://example.invalid/fake.zip'; Sha256 = $script:ndHash } }
            Mock Invoke-WebRequest { Copy-Item -LiteralPath $script:ndZip -Destination $OutFile }
            $cfg = @{
                Wimlib = @{ Path = (Join-Path -Path $custom -ChildPath 'wimlib-imagex.exe') }
                WorkDir = (Join-Path -Path $TestDrive -ChildPath 'work')
                LogLevel = 'Error'; OperationLog = ''; DebugTrace = 0; LogFile = (Join-Path -Path $TestDrive -ChildPath 'w.log')
            }
            { Resolve-WinMediaWimlib -Config $cfg } | Should -Throw '*非空*'
            Test-Path -LiteralPath (Join-Path -Path $custom -ChildPath 'stray.dll') | Should -BeTrue
        }

        It '非預設路徑的目錄不存在時，正常解壓出 wimlib-imagex.exe' {
            $fresh = Join-Path -Path $TestDrive -ChildPath 'fresh\bin'
            Mock Get-WinMediaWimlibSpec { [pscustomobject]@{ FileName = 'fake.zip'; Url = 'https://example.invalid/fake.zip'; Sha256 = $script:ndHash } }
            Mock Invoke-WebRequest { Copy-Item -LiteralPath $script:ndZip -Destination $OutFile }
            $cfg = @{
                Wimlib = @{ Path = (Join-Path -Path $fresh -ChildPath 'wimlib-imagex.exe') }
                WorkDir = (Join-Path -Path $TestDrive -ChildPath 'work2')
                LogLevel = 'Error'; OperationLog = ''; DebugTrace = 0; LogFile = (Join-Path -Path $TestDrive -ChildPath 'w2.log')
            }
            Resolve-WinMediaWimlib -Config $cfg | Should -Be (Join-Path -Path $fresh -ChildPath 'wimlib-imagex.exe')
            Test-Path -LiteralPath (Join-Path -Path $fresh -ChildPath 'wimlib-imagex.exe') | Should -BeTrue
        }
    }
}
