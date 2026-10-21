BeforeAll {
  $script:ProjectRoot = Split-Path -Parent $PSScriptRoot
  $script:Installer = Join-Path $script:ProjectRoot 'install.ps1'
  $script:FixtureRoot = Join-Path $TestDrive 'payload'
  New-Item -ItemType Directory -Path $script:FixtureRoot | Out-Null
  Copy-Item (Join-Path $script:ProjectRoot 'SHA256SUMS') $script:FixtureRoot
  Copy-Item (Join-Path $script:ProjectRoot 'LICENSE') $script:FixtureRoot
  Copy-Item (Join-Path $script:ProjectRoot 'src') $script:FixtureRoot -Recurse
  Copy-Item (Join-Path $script:ProjectRoot 'bin') $script:FixtureRoot -Recurse
}

Describe 'Standalone PowerShell installer' {
  BeforeEach {
    $downloadRoot = $script:FixtureRoot
    Mock Invoke-WebRequest -MockWith ({
      param($Uri, $OutFile)
      $relative = ([string]$Uri) -replace '^https://raw.githubusercontent.com/cleitonpin/android-connect/v0\.1\.2/', ''
      Copy-Item -LiteralPath (Join-Path $downloadRoot $relative) -Destination $OutFile
    }.GetNewClosure())
  }

  It 'installs from an expression without a checkout and supports spaces' {
    $dest = Join-Path $TestDrive 'standalone install'
    $installerBlock = [scriptblock]::Create((Get-Content -Raw -LiteralPath $script:Installer))
    & $installerBlock -InstallDirectory $dest -NoPath
    Test-Path (Join-Path $dest 'current/src/AndroidConnect.ps1') | Should -BeTrue
    Test-Path (Join-Path $dest 'bin/android-connect.cmd') | Should -BeTrue
    Test-Path (Join-Path $dest 'current/src/android-connect.bash') | Should -BeTrue
    Test-Path (Join-Path $dest 'current/LICENSE') | Should -BeTrue
  }

  It 'can be installed twice without nesting directories or losing files' {
    $dest = Join-Path $TestDrive 'repeated'
    & $script:Installer -InstallDirectory $dest -NoPath
    & $script:Installer -InstallDirectory $dest -NoPath
    $actual = (Get-FileHash (Join-Path $dest 'current/src/AndroidConnect.ps1') -Algorithm SHA256).Hash
    $expected = (Get-FileHash (Join-Path $script:FixtureRoot 'src/AndroidConnect.ps1') -Algorithm SHA256).Hash
    $actual | Should -Be $expected
    Test-Path (Join-Path $dest 'current/current') | Should -BeFalse
  }

  It 'runs the installed Windows command from a directory with spaces' {
    $dest = Join-Path $TestDrive 'native smoke install'
    & $script:Installer -InstallDirectory $dest -NoPath
    $output = & (Join-Path $dest 'bin/android-connect.cmd') help
    $LASTEXITCODE | Should -Be 0
    ($output -join "`n") | Should -Match 'android-connect'
  }

  It 'rejects checksum mismatch and preserves the existing install' {
    $dest = Join-Path $TestDrive 'existing'
    New-Item -ItemType Directory -Path (Join-Path $dest 'current') -Force | Out-Null
    Set-Content (Join-Path $dest 'current/marker') 'preserve'
    $downloadRoot = $script:FixtureRoot
    Mock Invoke-WebRequest -MockWith ({
      param($Uri, $OutFile)
      $relative = ([string]$Uri) -replace '^https://raw.githubusercontent.com/cleitonpin/android-connect/v0\.1\.2/', ''
      Copy-Item -LiteralPath (Join-Path $downloadRoot $relative) -Destination $OutFile
      if ($relative -eq 'src/AndroidConnect.ps1') { Add-Content $OutFile 'corrupted' }
    }.GetNewClosure())
    { & $script:Installer -InstallDirectory $dest -NoPath } | Should -Throw '*SHA256*'
    Get-Content (Join-Path $dest 'current/marker') | Should -Be 'preserve'
  }

  It 'rejects invalid version identifiers before downloading' {
    { & $script:Installer -Version '../../main' -InstallDirectory (Join-Path $TestDrive 'unsafe') -NoPath } | Should -Throw
    Should -Invoke Invoke-WebRequest -Times 0
  }
}

Describe 'Windows command argument forwarding' {
  BeforeAll {
    $script:OldEngine = $env:ANDROID_CONNECT_POWERSHELL
    $script:OldCapture = $env:ANDROID_CONNECT_TEST_ARGS
    $script:Capture = Join-Path $TestDrive 'args.json'
    $script:FakeEngine = Join-Path $TestDrive 'fake engine.ps1'
    Set-Content -LiteralPath $script:FakeEngine -Value '$args | ConvertTo-Json | Set-Content -LiteralPath $env:ANDROID_CONNECT_TEST_ARGS; exit 0'
    $env:ANDROID_CONNECT_POWERSHELL = $script:FakeEngine
    $env:ANDROID_CONNECT_TEST_ARGS = $script:Capture
  }
  AfterAll {
    $env:ANDROID_CONNECT_POWERSHELL = $script:OldEngine
    $env:ANDROID_CONNECT_TEST_ARGS = $script:OldCapture
  }
  It 'translates CLI flags before the child command boundary' {
    & (Join-Path $script:ProjectRoot 'bin/android-connect.ps1') doctor --json --output 'report with spaces.json'
    $actual = Get-Content -Raw $script:Capture | ConvertFrom-Json
    $actual | Should -Contain '-Json'
    $actual | Should -Contain '-OutputPath'
    $actual | Should -Contain 'report with spaces.json'
  }
  It 'preserves Expo flags and shell metacharacters as child arguments' {
    & (Join-Path $script:ProjectRoot 'bin/android-connect.ps1') exec -- npx expo run:android --device 'serial with spaces' '--flag=a;b'
    $actual = Get-Content -Raw $script:Capture | ConvertFrom-Json
    $actual | Should -Contain '--device'
    $actual | Should -Contain 'serial with spaces'
    $actual | Should -Contain '--flag=a;b'
  }
  It 'maps the requested environment shell without changing the command arguments' {
    & (Join-Path $script:ProjectRoot 'bin/android-connect.ps1') env --shell powershell
    $actual = Get-Content -Raw $script:Capture | ConvertFrom-Json
    $actual | Should -Contain '-ShellName'
    $actual | Should -Contain 'powershell'
  }
}
