#Requires -Version 5.1

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Common\WinMediaProcess.psm1') -Force
    $script:cfg = @{ DebugTrace = 0; OperationLog = ''; LogLevel = 'Info'; LogFile = '' }

    # 子程序腳本：輸出實際收到的每個引數（$args 對 '-' 開頭字串可能有誤，改用命令列）。
    # 啟動參數固定為 6 個（powershell.exe、-NoProfile、-ExecutionPolicy、Bypass、-File、腳本路徑），已實測；此處以腳本路徑定位，不寫死數字。
    $script:echo = Join-Path $TestDrive 'echo-args.ps1'
    Set-Content -LiteralPath $script:echo -Encoding UTF8 -Value @'
$all = [Environment]::GetCommandLineArgs()
$i = [array]::IndexOf($all, $PSCommandPath)
if ($i -lt 0) { $i = 5 }
$all[($i + 1)..($all.Count - 1)] | ForEach-Object { "[$_]" }
'@

    # 以 Invoke-WinMediaExternal 呼叫子程序，回傳子程序實際收到的引數陣列
    $script:received = {
        param([string[]]$Arguments)
        $r = Invoke-WinMediaExternal -FilePath 'powershell.exe' -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:echo) + $Arguments) -Config $script:cfg
        $r.ExitCode | Should -Be 0 -Because $r.StdErr
        @($r.StdOut -split "\r?\n" | Where-Object { $_ -ne '' } | ForEach-Object { $_.Substring(1, $_.Length - 2) })
    }
}

Describe 'Invoke-WinMediaExternal 引數組合' -Tag 'Unit' {
    It '含空白且結尾為反斜線：結尾反斜線加倍，子程序收到單一完整引數' {
        $got = @(& $script:received 'C:\a b\')
        $got.Count | Should -Be 1
        $got[0] | Should -Be 'C:\a b\'
    }

    It '含空白的目錄：收到單一引數且空白保留' {
        $got = @(& $script:received 'C:\my dir\media')
        $got.Count | Should -Be 1
        $got[0] | Should -Be 'C:\my dir\media'
    }

    It '迴歸：不含空白、含引號的 bootdata 原樣傳出，結果等同 Windows 命令列解析' {
        $got = @(& $script:received '-bootdata:2#p0,e,b"C:\x\etfsboot.com"#pEF,e,b"C:\x\efisys.bin"')
        $got.Count | Should -Be 1
        $got[0] | Should -Be '-bootdata:2#p0,e,bC:\x\etfsboot.com#pEF,e,bC:\x\efisys.bin'
    }

    It '含空白的 bootdata（修正前會壞掉）：收到單一引數且空白保留' {
        $got = @(& $script:received '-bootdata:2#p0,e,b"C:\my dir\boot\etfsboot.com"#pEF,e,b"C:\my dir\efi\microsoft\boot\efisys.bin"')
        $got.Count | Should -Be 1
        $got[0] | Should -Be '-bootdata:2#p0,e,bC:\my dir\boot\etfsboot.com#pEF,e,bC:\my dir\efi\microsoft\boot\efisys.bin'
    }

    It '刻意的行為記錄：含空白也含引號的 say "hi" 原樣傳出，被拆成兩個引數' {
        $got = @(& $script:received 'say "hi"')
        $got.Count | Should -Be 2
        $got[0] | Should -Be 'say'
        $got[1] | Should -Be 'hi'
    }
}
