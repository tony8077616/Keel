Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# 通用外部程式執行模組（不依賴 WinMediaRefresh，可直接複製到其他專案）
# 需要的 Config 鍵：DebugTrace（0–3）、OperationLog（同 WinMediaOperation）
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinMediaLog.psm1') -Force
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'WinMediaOperation.psm1') -Force

function Invoke-WinMediaExternal {
    # 第三方程式執行（§4.1）：同步讀取 stdout 與 stderr，避免緩衝區死鎖；參數先遮蔽再紀錄
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][hashtable]$Config,
        # 指定時把檔案內容寫入子程序的標準輸入（例如 wimlib-imagex update 只接受 stdin 指令）
        [string]$StandardInputPath
    )

    $quoted = foreach ($argument in $ArgumentList) {
        if ($argument -match '\s') { '"{0}"' -f $argument } else { $argument }
    }
    $target = '{0} {1}' -f $FilePath, ($quoted -join ' ')

    $run = {
        $startInfo = New-Object -TypeName System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $FilePath
        $startInfo.Arguments = $quoted -join ' '
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.RedirectStandardInput = [bool]$StandardInputPath
        $startInfo.CreateNoWindow = $true

        $process = New-Object -TypeName System.Diagnostics.Process
        $process.StartInfo = $startInfo
        [void]$process.Start()
        if ($StandardInputPath) {
            $process.StandardInput.Write([System.IO.File]::ReadAllText($StandardInputPath))
            $process.StandardInput.Close()
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $stdout = $stdoutTask.Result

        [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdout
            StdErr   = $stderr
        }
    }

    $outcome = Invoke-WinMediaOperation -Category External -Operation ([System.IO.Path]::GetFileName($FilePath)) -Target $target -ScriptBlock $run -Config $Config

    if ([int]$Config.DebugTrace -ge 3) {
        Write-WinMediaLog -Config $Config -Level Debug -Message ('stdout: ' + (Protect-WinMediaLogValue -Value $outcome.StdOut))
        Write-WinMediaLog -Config $Config -Level Debug -Message ('stderr: ' + (Protect-WinMediaLogValue -Value $outcome.StdErr))
    }

    return $outcome
}

Export-ModuleMember -Function Invoke-WinMediaExternal
