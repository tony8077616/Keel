#Requires -Version 5.1

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
}

Describe 'DISM cmdlet 皆帶 -LogLevel' -Tag 'Unit' {
    AfterAll {
        if ($script:dismLoadedByTest) { Remove-Module -Name DISM -Force -ErrorAction SilentlyContinue }
    }

    # AST 掃描：以 DISM 模組的完整 cmdlet 清單比對 CommandAst，不靠字串或行首位置；
    # 字串、註解、跨行續接與行中呼叫都能正確處理。參數值必須是 $Config.DismLogLevel。
    It '所有非測試模組的 DISM cmdlet 呼叫都以 -LogLevel $Config.DismLogLevel 傳入（AST）' {
        if (-not (Get-Module -ListAvailable -Name DISM)) {
            Set-ItResult -Skipped -Because 'DISM 模組不存在於此環境'
            return
        }
        $script:dismLoadedByTest = -not (Get-Module -Name DISM)
        Import-Module -Name DISM -ErrorAction Stop
        $names = @((Get-Command -Module DISM).Name)
        $files = Get-ChildItem -LiteralPath @((Join-Path -Path $script:root -ChildPath 'Common'), (Join-Path -Path $script:root -ChildPath 'Imaging')) -Recurse -File |
            Where-Object { $_.Extension -in '.ps1', '.psm1' -and $_.FullName -notmatch '\\Tests\\' }
        $missing = @()
        foreach ($file in $files) {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            $errors | Should -BeNullOrEmpty
            $calls = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
            foreach ($call in $calls) {
                $name = $call.GetCommandName()
                if (-not $name -or $names -notcontains $name) { continue }
                $elements = @($call.CommandElements)
                $index = [array]::FindIndex($elements, [System.Predicate[object]] { param($e) $e -is [System.Management.Automation.Language.CommandParameterAst] -and $e.ParameterName -eq 'LogLevel' })
                # -LogLevel $x 拆成兩個元素：值在參數後面的元素（或參數本身的 Argument，語法 -LogLevel:$x）
                $value = if ($index -lt 0) { $null } elseif ($elements[$index].Argument) { $elements[$index].Argument } elseif ($index + 1 -lt $elements.Count) { $elements[$index + 1] } else { $null }
                $ok = $value -and $value.Extent.Text -eq '$Config.DismLogLevel'
                if (-not $ok) { $missing += ('{0}:{1} {2}' -f $file.Name, $call.Extent.StartLineNumber, $name) }
            }
        }
        $missing | Should -BeNullOrEmpty
    }
}
