#Requires -Version 5.1

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Common\WinMediaLog.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\Imaging\WinMediaWimlib.psm1') -Force
    # 守門：測試前後都不得動到真正的 %LOCALAPPDATA%\WinMediaRefresh
    $script:realTools = Join-Path $env:LOCALAPPDATA 'WinMediaRefresh'
    $script:toolsBefore = if (Test-Path -LiteralPath $script:realTools) { (Get-Item -LiteralPath $script:realTools).LastWriteTimeUtc.Ticks } else { 'absent' }
    $script:newCfg = {
        param([string]$WimlibPath)
        @{ DismProvider = 'Inbox'; LogLevel = 'Error'; LogFile = ''; OperationLog = ''; DebugTrace = 0; WorkDir = $TestDrive; Wimlib = @{ Path = $WimlibPath } }
    }
}

AfterAll {
    $after = if (Test-Path -LiteralPath $script:realTools) { (Get-Item -LiteralPath $script:realTools).LastWriteTimeUtc.Ticks } else { 'absent' }
    if ($after -ne $script:toolsBefore) { throw "測試動到了 $script:realTools" }
}

Describe 'Get-WinMediaWimlibSpec' -Tag 'Unit' {
    It '<arch> 對應 <machine>' -ForEach @(
        @{ arch = 'AMD64'; machine = 'x86_64' }
        @{ arch = 'ARM64'; machine = 'aarch64' }
        @{ arch = 'x86'; machine = 'i686' }
    ) {
        $spec = Get-WinMediaWimlibSpec -Architecture $arch
        $spec.Architecture | Should -Be $machine
        $spec.FileName | Should -BeLike "*$machine*"
        $spec.Url | Should -BeLike 'https://wimlib.net/downloads/*'
        $spec.Url | Should -Be ('https://wimlib.net/downloads/' + $spec.FileName)
        $spec.Sha256 | Should -Match '^[0-9a-f]{64}$'
    }

    It '不支援的架構會 throw' {
        { Get-WinMediaWimlibSpec -Architecture 'MIPS' } | Should -Throw '*不支援的處理器架構*'
    }
}

Describe 'Resolve-WinMediaWimlib' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName WinMediaWimlib Invoke-WinMediaOperation { param($ScriptBlock) & $ScriptBlock }
        Mock -ModuleName WinMediaWimlib Invoke-WebRequest { }
        Mock -ModuleName WinMediaWimlib Expand-Archive { param($DestinationPath) Set-Content -LiteralPath (Join-Path $DestinationPath 'wimlib-imagex.exe') -Value 'fake' }
        # 內附壓縮檔（tools\wimlib）驗證失敗，其餘（下載後的 zip）驗證通過
        Mock -ModuleName WinMediaWimlib Test-WinMediaFileHash { $false } -ParameterFilter { $Path -like '*tools\wimlib*' }
        Mock -ModuleName WinMediaWimlib Test-WinMediaFileHash { $true }
    }

    It 'Path 指向既有檔案時直接回傳，不下載、不解壓' {
        $exe = Join-Path $TestDrive 'existing-wimlib-imagex.exe'
        Set-Content -LiteralPath $exe -Value 'fake'
        $r = Resolve-WinMediaWimlib -Config (& $script:newCfg $exe)
        $r | Should -Be $exe
        Should -Invoke -ModuleName WinMediaWimlib Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke -ModuleName WinMediaWimlib Expand-Archive -Times 0 -Exactly
        Should -Invoke -ModuleName WinMediaWimlib Test-WinMediaFileHash -Times 0 -Exactly
    }

    It 'Path 不存在時下載、驗證並解壓到 Path 所在資料夾' {
        $exe = Join-Path $TestDrive 'dl\tools\wimlib-imagex.exe'
        $r = Resolve-WinMediaWimlib -Config (& $script:newCfg $exe)
        $r | Should -Be $exe
        Test-Path -LiteralPath $exe -PathType Leaf | Should -BeTrue
        Should -Invoke -ModuleName WinMediaWimlib Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -like 'https://wimlib.net/downloads/*' -and $OutFile -like "$TestDrive*" }
        Should -Invoke -ModuleName WinMediaWimlib Expand-Archive -Times 1 -Exactly
    }

    It '內附壓縮檔雜湊相符時不下載' {
        Mock -ModuleName WinMediaWimlib Test-WinMediaFileHash { $true } -ParameterFilter { $Path -like '*tools\wimlib*' }
        $exe = Join-Path $TestDrive 'bundled\tools\wimlib-imagex.exe'
        Resolve-WinMediaWimlib -Config (& $script:newCfg $exe) | Should -Be $exe
        Should -Invoke -ModuleName WinMediaWimlib Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke -ModuleName WinMediaWimlib Expand-Archive -Times 1 -Exactly
    }

    It '下載後雜湊不符時 throw 且不解壓' {
        Mock -ModuleName WinMediaWimlib Test-WinMediaFileHash { $false }
        $exe = Join-Path $TestDrive 'badhash\tools\wimlib-imagex.exe'
        { Resolve-WinMediaWimlib -Config (& $script:newCfg $exe) } | Should -Throw '*SHA-256 不符*'
        Should -Invoke -ModuleName WinMediaWimlib Expand-Archive -Times 0 -Exactly
    }

    It '解壓後找不到 exe 時 throw' {
        Mock -ModuleName WinMediaWimlib Expand-Archive { }
        $exe = Join-Path $TestDrive 'noexe\tools\wimlib-imagex.exe'
        { Resolve-WinMediaWimlib -Config (& $script:newCfg $exe) } | Should -Throw '*找不到 wimlib-imagex.exe*'
    }
}

Describe 'Invoke-WinMediaWimlib' -Tag 'Unit' {
    BeforeEach {
        Mock -ModuleName WinMediaWimlib Invoke-WinMediaOperation { param($ScriptBlock) & $ScriptBlock }
    }

    It 'ExitCode 0 時回傳結果物件並以解析到的 exe 與參數呼叫' {
        $exe = Join-Path $TestDrive 'ok-wimlib-imagex.exe'
        Set-Content -LiteralPath $exe -Value 'fake'
        Mock -ModuleName WinMediaWimlib Invoke-WinMediaExternal { [pscustomobject]@{ ExitCode = 0; StdOut = 'done'; StdErr = '' } }
        $r = Invoke-WinMediaWimlib -ArgumentList @('info', 'a.wim') -Config (& $script:newCfg $exe)
        $r.ExitCode | Should -Be 0
        $r.StdOut | Should -Be 'done'
        Should -Invoke -ModuleName WinMediaWimlib Invoke-WinMediaExternal -Times 1 -Exactly -ParameterFilter { $FilePath -eq $exe -and $ArgumentList[0] -eq 'info' -and $ArgumentList[1] -eq 'a.wim' }
    }

    It 'ExitCode 非 0 時 throw 並含結束碼' {
        $exe = Join-Path $TestDrive 'fail-wimlib-imagex.exe'
        Set-Content -LiteralPath $exe -Value 'fake'
        Mock -ModuleName WinMediaWimlib Invoke-WinMediaExternal { [pscustomobject]@{ ExitCode = 47; StdOut = ''; StdErr = 'boom' } }
        { Invoke-WinMediaWimlib -ArgumentList @('export', 'a.wim') -Config (& $script:newCfg $exe) } | Should -Throw '*結束碼 47*boom*'
    }

    It 'StandardInputPath 會傳給 Invoke-WinMediaExternal' {
        $exe = Join-Path $TestDrive 'stdin-wimlib-imagex.exe'
        Set-Content -LiteralPath $exe -Value 'fake'
        $in = Join-Path $TestDrive 'stdin-cmds.txt'
        Mock -ModuleName WinMediaWimlib Invoke-WinMediaExternal { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
        Invoke-WinMediaWimlib -ArgumentList @('update', 'a.wim') -Config (& $script:newCfg $exe) -StandardInputPath $in | Out-Null
        Should -Invoke -ModuleName WinMediaWimlib Invoke-WinMediaExternal -Times 1 -Exactly -ParameterFilter { $StandardInputPath -eq $in }
    }
}
