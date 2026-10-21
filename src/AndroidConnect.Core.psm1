Set-StrictMode -Version Latest
function Get-UsbStateClass([string]$State) {
  if($State -match 'Not\s*shared|NotShared|Unbound'){return 'USB_NOT_SHARED'}
  if($State -match 'Attached'){return 'USB_ATTACHED'}
  if($State -match 'Shared|Bound'){return 'USB_SHARED'}
  return 'USB_UNKNOWN'
}
function Find-UsbCandidate([object[]]$Devices,[string]$Serial,[string]$BusId,[string[]]$VidPids,[bool]$StrictSerial=$false) {
  if($BusId){$chosen=@($Devices|Where-Object {$_.busid -eq $BusId});if($chosen.Count -eq 1){return @{status='selected';device=$chosen[0];candidates=$chosen}};return @{status='none';device=$null;candidates=@()}}
  if($Serial){$chosen=@($Devices|Where-Object {$_.serial -eq $Serial});if($chosen.Count -eq 1){return @{status='selected';device=$chosen[0];candidates=$chosen}};if($StrictSerial){return @{status='none';device=$null;candidates=@()}}}
  $candidates=@($Devices|Where-Object {$_.vid -and $_.pid -and (('{0}:{1}' -f ([string]$_.vid).ToLower(),([string]$_.pid).ToLower()) -in $VidPids)})
  if($candidates.Count -eq 1){return @{status='selected';device=$candidates[0];candidates=$candidates}}
  if($candidates.Count -gt 1){return @{status='ambiguous';device=$null;candidates=$candidates}}
  return @{status='none';device=$null;candidates=@()}
}
function Select-AdbPort([int[]]$Candidates,[int[]]$ListeningPorts,[int[]]$UsablePorts=@()) {
  foreach($port in $Candidates){ if($port -in $UsablePorts){ return @{port=$port;startServer=$false} } }
  foreach($port in $Candidates){ if($port -notin $ListeningPorts){ return @{port=$port;startServer=$true} } }
  return @{port=0;startServer=$false}
}
function Get-AdbReadiness([object[]]$Devices,[string]$Serial) {
  $device=@($Devices|Where-Object {$_.serial -eq $Serial}|Select-Object -First 1)
  if(-not $device){return 'DEVICE_ABSENT'}
  switch($device[0].state){'device' {return 'READY'} 'unauthorized' {return 'UNAUTHORIZED'} 'offline' {return 'OFFLINE'} 'no permissions' {return 'USB_PERMISSIONS'} default {return 'UNKNOWN'}}
}
function Get-ConnectActions([string]$UsbState,[bool]$VisibleInWsl,[bool]$Authorized,[bool]$DryRun=$false) {
  $actions=[Collections.Generic.List[string]]::new()
  switch(Get-UsbStateClass $UsbState){
    'USB_NOT_SHARED' { $actions.Add('BIND_REQUIRES_ADMIN'); return @($actions) }
    'USB_SHARED' { $actions.Add('ATTACH'); return @($actions) }
    'USB_ATTACHED' { if(-not $VisibleInWsl){$actions.Add('WAIT_FOR_USB');return @($actions)};if(-not $Authorized){$actions.Add('DIAGNOSE_ADB');return @($actions)};$actions.Add('VALIDATE_GETPROP');return @($actions) }
    default {$actions.Add('DISCOVER_DEVICE');return @($actions)}
  }
}
function Get-AttachRetrySchedule([int]$MaximumAttempts=3) {
  if($MaximumAttempts -lt 1 -or $MaximumAttempts -gt 3){throw 'Retry limit must be between one and three.'}
  return @(1..$MaximumAttempts | ForEach-Object { [int](400 * $_) })
}
function Get-ServiceRecoveryPolicy([string]$ServiceState,[bool]$IsAdministrator) {
  if($ServiceState -eq 'Running'){return 'NO_ACTION'}
  if($IsAdministrator){return 'OFFER_MANUAL_SERVICE_START'}
  return 'REPORT_SERVICE_STOPPED'
}
function Stop-NativeChild($Process) {
  if($Process -and -not $Process.HasExited){try{$Process.Kill()}catch{}}
}
Export-ModuleMember -Function Get-UsbStateClass,Find-UsbCandidate,Select-AdbPort,Get-AdbReadiness,Get-ConnectActions,Get-AttachRetrySchedule,Get-ServiceRecoveryPolicy,Stop-NativeChild
