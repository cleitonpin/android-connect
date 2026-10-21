# Run with: Invoke-Pester ./tests (Pester 5.7.1)
Import-Module "$PSScriptRoot/../src/AndroidConnect.Core.psm1" -Force
Describe 'USB state machine' {
  It 'reports disconnected or unknown USB without acting' { Get-ConnectActions 'Unknown' $false $false | Should -Be @('DISCOVER_DEVICE') }
  It 'binds normally only after explicit higher privilege handling' { Get-ConnectActions 'Not shared' $false $false | Should -Be @('BIND_REQUIRES_ADMIN') }
  It 'attaches a shared device' { Get-ConnectActions 'Shared' $false $false | Should -Be @('ATTACH') }
  It 'waits for an attached device to appear in Linux' { Get-ConnectActions 'Attached' $false $false | Should -Be @('WAIT_FOR_USB') }
  It 'diagnoses ADB only after USB visibility' { Get-ConnectActions 'Attached' $true $false | Should -Be @('DIAGNOSE_ADB') }
  It 'validates an already healthy connection without detach or restart' { Get-ConnectActions 'Attached' $true $true | Should -Be @('VALIDATE_GETPROP') }
  It 'resolves the preferred serial against the current changed BUSID' { $d=Find-UsbCandidate @(@{serial='PHONE';busid='4-1';vid='04e8';pid='6860'}) 'PHONE' '' @('04e8:6860');$d.device.busid | Should -Be '4-1' }
  It 'refuses to guess between two connected Android devices' { (Find-UsbCandidate @(@{serial='A';busid='1-1';vid='04e8';pid='6860'},@{serial='B';busid='2-1';vid='04e8';pid='6860'}) '' '' @('04e8:6860')).status | Should -Be 'ambiguous' }
  It 'honors an explicit BUSID even when VID PID is outside the default device' { (Find-UsbCandidate @(@{serial='OTHER';busid='7-2';vid='1234';pid='5678'}) '' '7-2' @('04e8:6860')).device.serial | Should -Be 'OTHER' }
  It 'does not substitute another phone when an explicit serial is absent' { (Find-UsbCandidate @(@{serial='OTHER';busid='7-2';vid='04e8';pid='6860'}) 'TARGET' '' @('04e8:6860') $true).status | Should -Be 'none' }
  It 'does not make force-bind an available automatic action' { (Get-ConnectActions 'Not shared' $false $false) -notcontains 'BIND_FORCE' | Should -BeTrue }
}
Describe 'ADB selection and diagnosis' {
  It 'uses a usable standard port without starting another server' { (Select-AdbPort @(5037,5038) @(5037) @(5037)).startServer | Should -BeFalse }
  It 'selects a free candidate if standard and fallback ports are occupied' { (Select-AdbPort @(5037,5038,5040) @(5037,5038)).port | Should -Be 5040 }
  It 'chooses 5038 when 5037 is occupied by an unusable listener' { (Select-AdbPort @(5038) @(5037)).port | Should -Be 5038 }
  It 'identifies the physical phone while an emulator is present' { Get-AdbReadiness @(@{serial='emulator-5554';state='device'},@{serial='PHONE';state='device'}) 'PHONE' | Should -Be 'READY' }
  It 'reports absent when lsusb device has no ADB transport' { Get-AdbReadiness @() 'PHONE' | Should -Be 'DEVICE_ABSENT' }
  It 'reports unauthorized distinctly' { Get-AdbReadiness @(@{serial='PHONE';state='unauthorized'}) 'PHONE' | Should -Be 'UNAUTHORIZED' }
  It 'reports offline distinctly' { Get-AdbReadiness @(@{serial='PHONE';state='offline'}) 'PHONE' | Should -Be 'OFFLINE' }
  It 'handles both configured ports occupied without killing a server' { (Select-AdbPort @(5037,5038) @(5037,5038)).port | Should -Be 0 }
  It 'selects the requested serial among multiple ADB transports' { Get-AdbReadiness @(@{serial='A';state='device'},@{serial='B';state='device'}) 'B' | Should -Be 'READY' }
  It 'distinguishes USB permission errors' { Get-AdbReadiness @(@{serial='PHONE';state='no permissions'}) 'PHONE' | Should -Be 'USB_PERMISSIONS' }
}
Describe 'safe retries' {
  It 'uses exactly three bounded delays after transient attach disconnects' { Get-AttachRetrySchedule 3 | Should -Be @(400,800,1200) }
  It 'reports a stopped service without restarting it or changing system state' { Get-ServiceRecoveryPolicy 'Stopped' $false | Should -Be 'REPORT_SERVICE_STOPPED' }
  It 'offers a manual service action to an administrator instead of restarting automatically' { Get-ServiceRecoveryPolicy 'Stopped' $true | Should -Be 'OFFER_MANUAL_SERVICE_START' }
  It 'does not restart usbipd as part of safe recovery' { Get-ServiceRecoveryPolicy 'Running' $true | Should -Be 'NO_ACTION' }
  It 'rejects unbounded retry schedules' { { Get-AttachRetrySchedule 99 } | Should -Throw }
  It 'stops only the active child process when cancellation interrupts a native wait' { $p=[pscustomobject]@{HasExited=$false;Killed=$false};$p|Add-Member ScriptMethod Kill {$this.Killed=$true};Stop-NativeChild $p;$p.Killed | Should -BeTrue }
  It 'does not stop an already exited child during cancellation cleanup' { $p=[pscustomobject]@{HasExited=$true;Killed=$false};$p|Add-Member ScriptMethod Kill {$this.Killed=$true};Stop-NativeChild $p;$p.Killed | Should -BeFalse }
}
