#Requires -Version 5.1

Import-Module -Name (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Imaging\WinMediaAdk.psm1') -Force

Describe 'Test-WinMediaSignerIsMicrosoft（簽署者 O 欄位完整比對）' -Tag 'Unit' {
    InModuleScope WinMediaAdk {
        BeforeAll {
            function Get-TestSignerCert {
                param([Parameter(Mandatory)][string]$Subject)
                $rsa = [System.Security.Cryptography.RSA]::Create(2048)
                $req = New-Object -TypeName System.Security.Cryptography.X509Certificates.CertificateRequest -ArgumentList $Subject, $rsa, ([System.Security.Cryptography.HashAlgorithmName]::SHA256), ([System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
                return $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
            }
        }

        It '真正的 O=Microsoft Corporation 簽署者通過' {
            $cert = Get-TestSignerCert -Subject 'CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
            Test-WinMediaSignerIsMicrosoft -Certificate $cert | Should -BeTrue
        }

        It '引號 CN 內夾帶 O=Microsoft Corporation 的假簽署者被拒' {
            $cert = Get-TestSignerCert -Subject 'CN="x, O=Microsoft Corporation, y", O=Evil'
            Test-WinMediaSignerIsMicrosoft -Certificate $cert | Should -BeFalse
        }

        It 'O=Microsoft Corporation Fake 被拒' {
            $cert = Get-TestSignerCert -Subject 'CN=Evil, O=Microsoft Corporation Fake'
            Test-WinMediaSignerIsMicrosoft -Certificate $cert | Should -BeFalse
        }
    }
}

Describe 'Install-WinMediaAdk（假簽署者的安裝程式不得執行）' -Tag 'Unit' {
    InModuleScope WinMediaAdk {
        BeforeAll {
            $rsa = [System.Security.Cryptography.RSA]::Create(2048)
            $req = New-Object -TypeName System.Security.Cryptography.X509Certificates.CertificateRequest -ArgumentList 'CN="x, O=Microsoft Corporation, y", O=Evil', $rsa, ([System.Security.Cryptography.HashAlgorithmName]::SHA256), ([System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $script:fakeCert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(1))
        }

        It '簽章 Valid 但簽署者為假 Microsoft 時拋錯，且不執行安裝程式' {
            $work = Join-Path -Path $TestDrive -ChildPath 'adk-work'
            $cfg = @{ AdkRoot = (Join-Path -Path $TestDrive -ChildPath 'adk'); WorkDir = $work; LogLevel = 'Error'; OperationLog = ''; DebugTrace = 0; LogFile = (Join-Path -Path $TestDrive -ChildPath 'adk.log') }
            Mock Invoke-WebRequest {
                New-Item -ItemType Directory -Path (Split-Path -Parent $OutFile) -Force | Out-Null
                [System.IO.File]::WriteAllText($OutFile, 'not-really-an-installer')
            }
            $script:fakeSig = [pscustomobject]@{ Status = 'Valid'; SignerCertificate = $script:fakeCert }
            Mock Get-AuthenticodeSignature { $script:fakeSig }
            Mock Start-Process { throw '假簽署者的安裝程式不應被執行' }
            { Install-WinMediaAdk -Config $cfg } | Should -Throw '*簽章*'
            Should -Invoke Start-Process -Times 0 -Exactly
        }
    }
}
