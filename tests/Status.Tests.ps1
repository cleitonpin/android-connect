BeforeAll {
  $script:EntryPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/AndroidConnect.ps1'
  Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/AndroidConnect.Core.psm1') -Force
  # Load the real adapter functions without executing the CLI dispatch or touching hardware.
  $tokens = $null; $parseErrors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($script:EntryPath, [ref]$tokens, [ref]$parseErrors)
  if ($parseErrors) { throw ($parseErrors | Out-String) }
  $definitions = $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]}, $false)
  . ([scriptblock]::Create(($definitions.Extent.Text -join "`n")))
}

Describe 'Native process arguments and deadlines' {
  It 'passes bound arguments, including empty and quoted values, to a real process' {
    $echoPath = Join-Path $TestDrive 'echo args.ps1'
    Set-Content -LiteralPath $echoPath -Value '[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $args | ConvertTo-Json -Compress'
    $result = Invoke-Native 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$echoPath,'value with spaces','a;b','a"b','') 5
    $result.exitCode | Should -Be 0
    $actual = $result.stdout | ConvertFrom-Json
    $actual.Count | Should -Be 4
    $actual[0] | Should -Be 'value with spaces'
    $actual[1] | Should -Be 'a;b'
    $actual[2] | Should -Be 'a"b'
    $actual[3] | Should -Be ''
  }
  It 'enforces a deadline on its own child instead of hanging' {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-Native 'powershell.exe' @('-NoProfile','-Command','Start-Sleep -Seconds 20') 1
    $result.exitCode | Should -Be 124
    $timer.Elapsed.TotalSeconds | Should -BeLessThan 5
  }
}

Describe 'WSL distribution discovery' {
  It 'parses state columns without depending on their language' {
    $rows = @(ConvertFrom-WslList "  NOM  ETAT  VERSION`n* Ubuntu Dev  En cours d'execution  2`n  Other  Arrete  1")
    $rows.Count | Should -Be 2
    $rows[0].name | Should -Be 'Ubuntu Dev'
    $rows[0].default | Should -BeTrue
    $rows[1].version | Should -Be 1
  }
  It 'accepts UTF16-style nulls left in legacy WSL output' {
    $line = '* Ubuntu  Running  2'.ToCharArray() -join "`0"
    @(ConvertFrom-WslList $line)[0].name | Should -Be 'Ubuntu'
  }
  It 'gets metadata without querying the kernel or booting a distro' {
    Mock Invoke-Native {
      param($File,$Arguments,$TimeoutSec)
      if ($Arguments -contains '--running') { return @{exitCode=0;stdout="Ubuntu`n";stderr=''} }
      return @{exitCode=0;stdout="* Ubuntu  Running  2`n  StoppedDistro  Stopped  2";stderr=''}
    }
    $snapshot = Get-WslDistributions
    $snapshot.distributions.Count | Should -Be 2
    $snapshot.distributions[0].running | Should -BeTrue
    $snapshot.distributions[1].running | Should -BeFalse
    Should -Invoke Invoke-Native -Times 0 -ParameterFilter { $Arguments -contains 'uname' -or $Arguments -contains '--version' }
  }
}

Describe 'Typed usbipd devices' {
  It 'reads VID and PID from the actual typed shape without assigning the reserved PID variable' {
    $device = [pscustomobject]@{BusId='4-1';HardwareId=[pscustomobject]@{Vid=1256;Pid=26720};InstanceId='USB\VID_04E8&PID_6860\PHONE';Description='Android';IsConnected=$true;IsBound=$true;IsAttached=$true}
    $actual = ConvertFrom-UsbipDevice $device
    $actual.vid | Should -Be '04e8'
    $actual.pid | Should -Be '6860'
    $actual.serial | Should -Be 'PHONE'
    $actual.busid | Should -Be '4-1'
    $actual.deviceState | Should -Be 'Attached'
  }
  It 'also accepts the defensive textual hardware identifier format' {
    $device = [pscustomobject]@{BusId='4-2';HardwareId='USB\VID_04E8&PID_6860';InstanceId='USB\DEVICE\OTHER';Description='Other';IsConnected=$true;IsBound=$false;IsAttached=$false}
    (ConvertFrom-UsbipDevice $device).pid | Should -Be '6860'
  }
  It 'keeps a disconnected persisted entry separate from connected hardware' {
    $device = [pscustomobject]@{BusId=$null;HardwareId='04e8:6860';InstanceId='USB\DEVICE\OLD';Description='Persisted';IsConnected=$false;IsBound=$true;IsAttached=$false}
    (ConvertFrom-UsbipDevice $device).isConnected | Should -BeFalse
  }
}

Describe 'Read-only status orchestration' {
  BeforeEach {
    Mock Read-Config { @{distro='';adbPort=0;serial='PHONE';usbIds=@('04e8:6860')} }
    Mock Get-WslDistributions { @{distributions=@(@{name='Ubuntu';default=$true;running=$true;version=2});error=''} }
    Mock Find-Usbipd { 'usbipd.exe' }
    Mock Get-UsbipState { @{available=$true;version='5.3.0';devices=@(@{serial='PHONE';busid='3-3';vid='04e8';pid='6860';deviceState='Attached';isConnected=$true;description='Phone'})} }
    Mock Get-AdbStatus { @{state='AVAILABLE';devices=@(@{serial='PHONE';state='device'});path='/usr/bin/adb';error=''} }
    Mock Get-Adb { throw 'doctor-only diagnostics must not run during status' }
    Mock Parse-AdbDevices { throw 'status must not invoke an ADB client that can start/restart a daemon' }
  }
  It 'returns a distro name and a physical transport without invoking doctor or adb start paths' {
    $actual = Get-StatusSnapshot
    $actual.distro | Should -Be 'Ubuntu'
    $actual.state | Should -Be 'USB_ATTACHED'
    $actual.adbDevices[0].serial | Should -Be 'PHONE'
    Should -Invoke Get-Adb -Times 0
    Should -Invoke Parse-AdbDevices -Times 0
  }
  It 'does not start a stopped distribution to gather status' {
    Mock Get-WslDistributions { @{distributions=@(@{name='Ubuntu';default=$true;running=$false;version=2});error=''} }
    $actual = Get-StatusSnapshot
    $actual.adb.state | Should -Be 'WSL_STOPPED'
    Should -Invoke Get-AdbStatus -Times 0
  }
  It 'reports missing distributions as a null value and a readable error' {
    Mock Get-WslDistributions { @{distributions=@();error='no distributions'} }
    $actual = Get-StatusSnapshot
    $actual.distro | Should -BeNullOrEmpty
    $actual.errors.Count | Should -BeGreaterThan 0
    Should -Invoke Get-AdbStatus -Times 0
  }
  It 'formats the default output as readable lines instead of dumping JSON' {
    $text = Format-StatusSnapshot (Get-StatusSnapshot)
    $text | Should -Match 'WSL\s*:\s*Ubuntu'
    $text | Should -Match 'USB\s*:\s*Attached'
    $text | Should -Match 'ADB\s*:'
    $text.TrimStart() | Should -Not -Match '^\{'
  }
  It 'exposes an adapter failure instead of silently reporting an empty device list' {
    Mock Get-UsbipState { @{available=$false;error='USB discovery failed';devices=@()} }
    $actual = Get-StatusSnapshot
    $actual.errors | Should -Contain 'USB discovery failed'
  }
}

Describe 'Passive ADB server protocol adapter' {
  It 'parses a real server-shaped response without invoking the ADB client' {
    Mock Invoke-Native { @{exitCode=0;stdout="ADB_PATH`t/usr/bin/adb`nADB_STATUS`tAVAILABLE`nADB_DEVICES`nPHONE`tdevice model:SM_A155M`nemulator-5554`tdevice`n";stderr=''} }
    $actual = Get-AdbStatus Ubuntu 5038
    $actual.state | Should -Be 'AVAILABLE'
    $actual.devices.Count | Should -Be 2
    $actual.devices[0].serial | Should -Be 'PHONE'
    Should -Invoke Invoke-Native -Times 1 -ParameterFilter { $Arguments -contains '--exec' -and $Arguments -notcontains 'devices' }
  }
  It 'reports a free port without starting an ADB server' {
    Mock Invoke-Native { @{exitCode=0;stdout="ADB_PATH`t/usr/bin/adb`nADB_STATUS`tSERVER_ABSENT`n";stderr=''} }
    (Get-AdbStatus Ubuntu 5038).state | Should -Be 'SERVER_ABSENT'
  }
  It 'reports an incompatible protocol without killing its listener' {
    Mock Invoke-Native { @{exitCode=0;stdout="ADB_PATH`t/usr/bin/adb`nADB_STATUS`tERROR`nADB_ERROR`tOther protocol`n";stderr=''} }
    $actual = Get-AdbStatus Ubuntu 5038
    $actual.state | Should -Be 'ERROR'
    $actual.error | Should -Be 'Other protocol'
  }
}

Describe 'CLI status JSON contract' {
  It 'dispatches status with parseable JSON and a nonzero exit for an invalid distro' {
    $result = Invoke-Native 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:EntryPath,'status','-Distro','__android_connect_missing_test__','-Json') 15
    $result.exitCode | Should -Be 1
    $payload = $result.stdout | ConvertFrom-Json
    $payload.distro | Should -BeNullOrEmpty
    $payload.errors.Count | Should -BeGreaterThan 0
    $payload.elapsedMs | Should -BeLessThan 12000
  }
}
