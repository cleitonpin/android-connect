BeforeAll {
  $script:EntryPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/AndroidConnect.ps1'
  $script:HookPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/android-connect.bash'
  Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/AndroidConnect.Core.psm1') -Force
  $tokens=$null; $parseErrors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($script:EntryPath,[ref]$tokens,[ref]$parseErrors)
  if($parseErrors){throw ($parseErrors|Out-String)}
  $definitions=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)
  . ([scriptblock]::Create(($definitions.Extent.Text -join "`n")))
}

Describe 'Session environment generation' {
  It 'exports the selected port for Bash child processes without CR characters' {
    $text=Format-AdbEnvironment -AdbPort 5041 -ShellName bash
    $text | Should -Be "export ANDROID_ADB_SERVER_PORT='5041'`nexport ADB_SERVER_SOCKET='tcp:localhost:5041'`n"
    $text.Contains("`r") | Should -BeFalse
  }
  It 'generates PowerShell session assignments explicitly' {
    $text=Format-AdbEnvironment -AdbPort 5038 -ShellName powershell
    $text | Should -Be "`$env:ANDROID_ADB_SERVER_PORT='5038'`n`$env:ADB_SERVER_SOCKET='tcp:localhost:5038'`n"
  }
  It 'rejects an invalid port instead of generating executable arbitrary text' {
    {Format-AdbEnvironment -AdbPort 0 -ShellName bash} | Should -Throw
    {Format-AdbEnvironment -AdbPort 65536 -ShellName bash} | Should -Throw
  }
  It 'does not generate code for an unknown shell' {
    {Format-AdbEnvironment -AdbPort 5038 -ShellName fish} | Should -Throw
  }
  It 'emits clean LF-only shell code through the real CLI' {
    $result=Invoke-Native 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:EntryPath,'env','-Port','5041') 5
    $result.exitCode | Should -Be 0
    $result.stdout | Should -Be "export ANDROID_ADB_SERVER_PORT='5041'`nexport ADB_SERVER_SOCKET='tcp:localhost:5041'`n"
  }
  It 'supports a JSON environment contract without executing anything' {
    $result=Invoke-Native 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:EntryPath,'env','-Port','5038','-Json') 5
    $result.exitCode | Should -Be 0
    $value=$result.stdout | ConvertFrom-Json
    $value.ANDROID_ADB_SERVER_PORT | Should -Be '5038'
    $value.ADB_SERVER_SOCKET | Should -Be 'tcp:localhost:5038'
  }
  It 'emits the installed shell hook unchanged with no terminal decoration' {
    $result=Invoke-Native 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:EntryPath,'shell-init') 5
    $result.exitCode | Should -Be 0
    $result.stdout | Should -Be (Get-Content -Raw -LiteralPath $script:HookPath)
    $result.stdout.Contains("`r") | Should -BeFalse
  }
}
