#requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Position=0)][string]$Command = 'connect',
  [string]$Device,
  [string]$Serial,
  [string]$Distro,
  [int]$Port = 0,
  [string]$OutputPath,
  [ValidateSet('text','json')][string]$Format = 'text',
  [ValidateSet('bash','powershell')][string]$ShellName = 'bash',
  [switch]$DryRun,
  [switch]$VerboseOutput,
  [switch]$Json,
  [switch]$Yes,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Remaining
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = [Text.UTF8Encoding]::new($false)
try { [Console]::OutputEncoding = $OutputEncoding } catch { }
if($Port -lt 0 -or $Port -gt 65535){throw 'Port deve estar entre 1 e 65535.'}
$script:Started = [Diagnostics.Stopwatch]::StartNew()
$script:LogPath = Join-Path $env:LOCALAPPDATA 'android-connect/logs/events.jsonl'
$script:ConfigPath = Join-Path $env:LOCALAPPDATA 'android-connect/config.json'
$script:Events = [Collections.Generic.List[object]]::new()
$script:LastEventAt = Get-Date
Import-Module (Join-Path $PSScriptRoot 'AndroidConnect.Core.psm1') -Force

function Write-Event([string]$Operation,[string]$Result,[string]$Message,[string]$Severity='info') {
  $Message=Protect-Text $Message
  $now=Get-Date; $event = [ordered]@{ timestamp=[DateTime]::UtcNow.ToString('o'); severity=$Severity; operation=$Operation; result=$Result; durationMs=[int]($now-$script:LastEventAt).TotalMilliseconds; message=$Message };$script:LastEventAt=$now
  $script:Events.Add($event)
  try { $dir=Split-Path -Parent $script:LogPath; [IO.Directory]::CreateDirectory($dir) | Out-Null; [IO.File]::AppendAllText($script:LogPath,(($event | ConvertTo-Json -Compress)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false)) } catch { }
  if ($VerboseOutput) { Write-Host ("[{0}] {1}: {2}" -f $Severity,$Operation,$Message) }
}
function Protect-Text([string]$Text) {
  if($null -eq $Text){return ''}
  return ($Text -replace 'RX8[A-Z0-9]{6,}','…SERIAL' -replace '(?i)(token|authorization|password)([=: ]+)[^\s,;]+','$1$2[REDACTED]' -replace '(?s)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----','[PRIVATE KEY REDACTED]' -replace '(?i)([A-Z]:\\Users\\)[^\\\s]+','$1[USER]' -replace '/home/[^/\s]+','/home/[USER]')
}
function Read-Config {
  $default=[ordered]@{ version=1; distro=''; serial='RX8XA05QK1P'; expectedModel='SM-A155M'; adbPort=0; usbIds=@('04e8:6860') }
  if (Test-Path -LiteralPath $script:ConfigPath) { try { $loaded=Get-Content -Raw -LiteralPath $script:ConfigPath | ConvertFrom-Json; foreach($p in $loaded.PSObject.Properties){$default[$p.Name]=$p.Value} } catch { Write-Event config invalid 'Configuração inválida; usando padrões.' warning } }
  return $default
}
function Format-AdbEnvironment([ValidateRange(1,65535)][int]$AdbPort,[ValidateSet('bash','powershell')][string]$ShellName='bash') {
  if($ShellName -eq 'powershell'){
    return "`$env:ANDROID_ADB_SERVER_PORT='$AdbPort'`n`$env:ADB_SERVER_SOCKET='tcp:localhost:$AdbPort'`n"
  }
  return "export ANDROID_ADB_SERVER_PORT='$AdbPort'`nexport ADB_SERVER_SOCKET='tcp:localhost:$AdbPort'`n"
}
function Invoke-Native([string]$File,[string[]]$Arguments,[ValidateRange(1,60)][int]$TimeoutSec=12) {
  $timer=[Diagnostics.Stopwatch]::StartNew()
  $psi=[Diagnostics.ProcessStartInfo]::new(); $psi.FileName=$File; $psi.UseShellExecute=$false; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.RedirectStandardInput=$true; $psi.CreateNoWindow=$true
  $psi.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
  $psi.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
  # Per-child setting: WSL management output otherwise defaults to UTF-16LE.
  $psi.EnvironmentVariables['WSL_UTF8']='1'
  # ProcessStartInfo.ArgumentList is unavailable on Windows PowerShell 5.1/.NET Framework.
  $quoted = foreach($arg in $Arguments) {
    $value=[string]$arg
    if($value.Length -eq 0){'""';continue}
    if($value -notmatch '[\s"]'){ $value; continue }
    $builder=[Text.StringBuilder]::new(); [void]$builder.Append('"'); $slashes=0
    foreach($ch in $value.ToCharArray()) {
      if($ch -eq '\') { $slashes++; continue }
      if($ch -eq '"') { [void]$builder.Append(('\' * (2*$slashes+1))); [void]$builder.Append('"'); $slashes=0; continue }
      if($slashes){[void]$builder.Append(('\' * $slashes));$slashes=0};[void]$builder.Append($ch)
    }
    if($slashes){[void]$builder.Append(('\' * (2*$slashes)))};[void]$builder.Append('"');$builder.ToString()
  }
  $psi.Arguments=($quoted -join ' ')
  $proc=[Diagnostics.Process]::new(); $proc.StartInfo=$psi;$started=$false
  try {
    [void]$proc.Start();$started=$true;$proc.StandardInput.Close()
    $outTask=$proc.StandardOutput.ReadToEndAsync();$errTask=$proc.StandardError.ReadToEndAsync()
    $remaining=[Math]::Max(1,$TimeoutSec*1000-[int]$timer.ElapsedMilliseconds)
    if(-not $proc.WaitForExit($remaining)){Stop-NativeChild $proc;return @{exitCode=124;stdout='';stderr='timeout';durationMs=$timer.ElapsedMilliseconds}}
    foreach($task in @($outTask,$errTask)){
      $remaining=[Math]::Max(1,$TimeoutSec*1000-[int]$timer.ElapsedMilliseconds)
      if(-not $task.Wait($remaining)){return @{exitCode=124;stdout='';stderr='timeout reading process output';durationMs=$timer.ElapsedMilliseconds}}
    }
    return @{exitCode=$proc.ExitCode;stdout=$outTask.Result;stderr=$errTask.Result;durationMs=$timer.ElapsedMilliseconds}
  } catch {
    if($started){Stop-NativeChild $proc};if($_.Exception -is [Management.Automation.PipelineStoppedException]){throw}
    return @{exitCode=127;stdout='';stderr=$_.Exception.Message;durationMs=$timer.ElapsedMilliseconds}
  } finally {if($started -and -not $proc.HasExited){Stop-NativeChild $proc};$proc.Dispose()}
}
function ConvertFrom-UsbipDevice($DeviceObject) {
  $props=@{};foreach($property in $DeviceObject.PSObject.Properties){$props[$property.Name]=$property.Value}
  $vendorId='';$productId='';$hardware=$props.HardwareId
  if($null -ne $hardware -and $hardware.PSObject.Properties['Vid'] -and $hardware.PSObject.Properties['Pid']){
    $vendorId=('{0:x4}' -f [int]$hardware.Vid);$productId=('{0:x4}' -f [int]$hardware.Pid)
  } elseif([string]$hardware -match 'VID_([0-9A-Fa-f]{4}).*PID_([0-9A-Fa-f]{4})|^([0-9A-Fa-f]{4}):([0-9A-Fa-f]{4})$'){
    if($Matches[1]){$vendorId=$Matches[1].ToLower();$productId=$Matches[2].ToLower()}else{$vendorId=$Matches[3].ToLower();$productId=$Matches[4].ToLower()}
  }
  $instance=[string]$props.InstanceId;$usbSerial='';if($instance -match '\\([^\\]+)$'){$usbSerial=$Matches[1]}
  $usbState=if($props.IsAttached){'Attached'}elseif($props.IsBound){'Shared'}else{'Not shared'}
  return [pscustomobject]@{busid=[string]$props.BusId;description=[string]$props.Description;vid=$vendorId;pid=$productId;serial=$usbSerial;deviceState=$usbState;state=$usbState;isConnected=[bool]$props.IsConnected;instanceId=$instance}
}
function Find-Usbipd { $p=Get-Command usbipd.exe,usbipd -ErrorAction SilentlyContinue | Select-Object -First 1; if($p){return $p.Source}; $candidate=Join-Path $env:ProgramW6432 'usbipd-win/usbipd.exe'; if(Test-Path $candidate){return $candidate}; return $null }
function Get-UsbipState([string]$Usbipd) {
  # usbipd ships a version-matched PowerShell module with typed state fields.
  $module=Join-Path $env:ProgramW6432 'usbipd-win/Usbipd.Powershell.dll'
  if(Test-Path -LiteralPath $module) {
    try {
      Import-Module $module -ErrorAction Stop
      $devices=@(Get-UsbipdDevice | ForEach-Object {ConvertFrom-UsbipDevice $_})
      $v=Invoke-Native $Usbipd @('--version') 5
      return @{available=$true;version=$v.stdout.Trim();devices=$devices}
    } catch { return @{available=$false;error=$_.Exception.Message;devices=@()} }
  }
  return @{available=$false;error='Módulo Usbipd.Powershell.dll não encontrado; esperado na instalação versionada do usbipd-win.';devices=@()}
}
function ConvertFrom-WslList([string]$Text) {
  foreach($line in (($Text -replace "`0",'') -split "`r?`n")){
    if($line -match '^\s*(\*)?\s*(.+?)\s{2,}(.+?)\s+([12])\s*$'){
      [pscustomobject]@{name=$Matches[2].Trim();state=$Matches[3].Trim();version=[int]$Matches[4];default=[bool]$Matches[1];running=$false}
    }
  }
}
function Get-WslDistributions {
  $list=Invoke-Native 'wsl.exe' @('--list','--verbose') 3
  if($list.exitCode -ne 0){return @{distributions=@();error=('Falha ao listar WSL: '+$list.stderr);available=$false}}
  $items=@(ConvertFrom-WslList $list.stdout)
  $running=Invoke-Native 'wsl.exe' @('--list','--running','--quiet') 3
  if($running.exitCode -ne 0){return @{distributions=$items;error=('Falha ao consultar distribuições ativas: '+$running.stderr);available=$false}}
  $names=@(($running.stdout -replace "`0",'') -split "`r?`n" | ForEach-Object {$_.Trim()} | Where-Object {$_})
  foreach($item in $items){$item.running=$item.name -in $names}
  return @{distributions=$items;error='';available=$true}
}
function Get-WslInfo {
  $discovery=Get-WslDistributions
  $ver=Invoke-Native 'wsl.exe' @('--version') 10
  $kernel=Invoke-Native 'wsl.exe' @('-e','uname','-r') 8
  $network='unknown';$wslConfig=Join-Path $env:USERPROFILE '.wslconfig';if(Test-Path $wslConfig){$line=Get-Content $wslConfig|Where-Object {$_ -match '^\s*networkingMode\s*='}|Select-Object -First 1;if($line -match '=\s*(\S+)'){$network=$Matches[1]}}
  return @{ distributions=$discovery.distributions;version=($ver.stdout -replace "`0",'').Trim();kernel=$kernel.stdout.Trim();networkingMode=$network;error=$discovery.error }
}
function Get-Adb([string]$DistroName) {
  $cmd="command -v adb; adb version 2>&1; printf '\nENV\n'; env | grep -E '^(ADB_SERVER_SOCKET|ANDROID_ADB_SERVER_PORT|ANDROID_ADB_SERVER_ADDRESS)=' || true; printf '\nPORTS\n'; (ss -ltnp 2>/dev/null || true) | grep -E ':(503[7-9]|504[0-2])\b' || true; printf '\nUSB\n'; (lsusb 2>&1 || true); printf '\nPROCESSES\n'; (ps -eo pid,args 2>/dev/null || true) | grep '[a]db'; printf '\nLOGS\n'; (dmesg --ctime 2>/dev/null | tail -n 20 || true); (tail -n 30 /tmp/adb.*.log 2>/dev/null | tail -n 30 || true)"
  $r=Invoke-Native 'wsl.exe' @('-d',$DistroName,'--exec','bash','-c',$cmd) 15
  return @{exitCode=$r.exitCode;raw=$r.stdout;error=$r.stderr}
}
function ConvertFrom-AdbRows([string]$Text) {
  foreach($line in ($Text -split "`r?`n")){
    if($line -match '^([^\s]+)\s+(device|unauthorized|offline|no permissions)(?:\s+(.*))?$'){
      @{serial=$Matches[1];state=$Matches[2];details=$(if($Matches.ContainsKey(3)){$Matches[3]}else{''})}
    }
  }
}
function Parse-AdbDevices([string]$DistroName,[int]$AdbPort) {
  $nativeArguments=@('-d',$DistroName,'--exec','env',"ANDROID_ADB_SERVER_PORT=$AdbPort","ADB_SERVER_SOCKET=tcp:localhost:$AdbPort",'adb','devices','-l')
  $r=Invoke-Native 'wsl.exe' $nativeArguments 15
  $rows=@(ConvertFrom-AdbRows $r.stdout)
  return @{exitCode=$r.exitCode;devices=$rows;raw=$r.stdout;error=$r.stderr}
}
function Get-AdbStatus([string]$DistroName,[ValidateRange(1,65535)][int]$AdbPort) {
  # Query the smart socket directly. `adb devices` can start a daemon or replace
  # an incompatible one, so the read-only status path never invokes that client.
  $probe=@'
printf 'ADB_PATH\t'; command -v adb || true
fail() { printf 'ADB_STATUS\tERROR\nADB_ERROR\t%s\n' "$1"; exit 0; }
if ! { exec 3<>/dev/tcp/127.0.0.1/"$1"; } 2>/dev/null; then
  printf 'ADB_STATUS\tSERVER_ABSENT\n'; exit 0
fi
printf '000Ehost:devices-l' >&3
IFS= read -r -t 1 -N 4 reply <&3 || fail 'Servidor sem resposta ADB'
[[ "$reply" == OKAY || "$reply" == FAIL ]] || fail 'Porta ocupada por protocolo diferente de ADB'
IFS= read -r -t 1 -N 4 size <&3 || fail 'Resposta ADB incompleta'
[[ "$size" =~ ^[0-9a-fA-F]{4}$ ]] || fail 'Tamanho ADB invalido'
length=$((16#$size))
payload=''
if (( length )); then
  IFS= read -r -t 1 -N "$length" payload <&3 || fail 'Resposta ADB truncada ou lenta'
fi
if [[ "$reply" == FAIL ]]; then fail "$payload"; fi
printf 'ADB_STATUS\tAVAILABLE\nADB_DEVICES\n%s\n' "$payload"
'@
  $r=Invoke-Native 'wsl.exe' @('-d',$DistroName,'--exec','bash','-c',$probe,'android-connect-status',[string]$AdbPort) 5
  $result=@{state='ERROR';devices=@();path='';error=''}
  if($r.exitCode -ne 0){$result.error="Consulta ADB falhou (exit=$($r.exitCode)): $($r.stderr)";return $result}
  foreach($line in ($r.stdout -split "`r?`n")){
    if($line -match '^ADB_PATH\t(.*)$'){$result.path=$Matches[1]}
    if($line -match '^ADB_STATUS\t(AVAILABLE|SERVER_ABSENT|ERROR)$'){$result.state=$Matches[1]}
    if($line -match '^ADB_ERROR\t(.*)$'){$result.error=$Matches[1]}
  }
  $sections=$r.stdout -split '(?m)^ADB_DEVICES\r?$',2
  if($sections.Count -eq 2){$result.devices=@(ConvertFrom-AdbRows $sections[1])}
  if($result.state -eq 'ERROR' -and -not $result.error){$result.error='A consulta não retornou um estado ADB válido.'}
  return $result
}
function Get-StatusSnapshot([string]$DistroName='',[int]$AdbPort=0) {
  $timer=[Diagnostics.Stopwatch]::StartNew();$config=Read-Config
  $problems=[Collections.Generic.List[string]]::new()
  $wsl=Get-WslDistributions
  if($wsl.error){$problems.Add([string]$wsl.error)}
  $chosenName=if($DistroName){$DistroName}elseif($config.distro){[string]$config.distro}else{''}
  $distribution=if($chosenName){@($wsl.distributions|Where-Object {$_.name -eq $chosenName})|Select-Object -First 1}else{@($wsl.distributions|Where-Object default)|Select-Object -First 1}
  $selectedName=$null
  if($distribution){$selectedName=[string]$distribution.name}else{$problems.Add('Distribuição WSL não encontrada. Use --distro NOME para selecionar uma distribuição instalada.')}
  $selectedPort=if($AdbPort){$AdbPort}elseif($config.adbPort){[int]$config.adbPort}else{5037}
  $usbipdPath=Find-Usbipd
  $usb=if($usbipdPath){Get-UsbipState $usbipdPath}else{@{available=$false;devices=@();error='usbipd não encontrado no Windows.'}}
  if($usb.error){$problems.Add([string]$usb.error)}
  $connected=@($usb.devices|Where-Object isConnected)
  $selection=Find-UsbCandidate -Devices $connected -Serial ([string]$config.serial) -BusId '' -VidPids @($config.usbIds)
  $selectedUsb=$selection.device
  $statusState=if($selectedUsb){Get-UsbStateClass ([string]$selectedUsb.deviceState)}elseif($selection.status -eq 'ambiguous'){'DEVICE_SELECTION_REQUIRED'}else{'USB_NOT_FOUND'}
  $adb=if(-not $distribution){@{state='WSL_UNAVAILABLE';devices=@();path='';error=''}}elseif(-not $distribution.running){@{state='WSL_STOPPED';devices=@();path='';error=''}}else{Get-AdbStatus $selectedName $selectedPort}
  if($adb.error){$problems.Add([string]$adb.error)}
  return [ordered]@{state=$statusState;distro=$selectedName;port=$selectedPort;usbipd=$usb;selectedUsb=$selectedUsb;adb=$adb;adbDevices=@($adb.devices);errors=@($problems.ToArray());elapsedMs=$timer.ElapsedMilliseconds}
}
function Format-StatusSnapshot($Snapshot) {
  $lines=[Collections.Generic.List[string]]::new()
  $lines.Add('Android Connect - status')
  $distributionText=if($Snapshot.distro){$Snapshot.distro}else{'não encontrada'}
  $lines.Add("WSL : $distributionText")
  if($Snapshot.selectedUsb){$lines.Add("USB : $($Snapshot.selectedUsb.deviceState) | BUSID $($Snapshot.selectedUsb.busid) | $($Snapshot.selectedUsb.description)")}
  elseif(-not $Snapshot.usbipd.available){$lines.Add('USB : descoberta indisponível')}
  else{$lines.Add('USB : nenhum dispositivo selecionado conectado')}
  switch($Snapshot.adb.state){
    'AVAILABLE' {$lines.Add("ADB : servidor respondendo na porta $($Snapshot.port)")}
    'SERVER_ABSENT' {$lines.Add("ADB : nenhum servidor acessível na porta $($Snapshot.port); execute android-connect para conectar")}
    'WSL_STOPPED' {$lines.Add('ADB : não consultado; a distribuição está parada e foi preservada')}
    'WSL_UNAVAILABLE' {$lines.Add('ADB : não consultado; distribuição indisponível')}
    default {$lines.Add('ADB : consulta falhou')}
  }
  if($Snapshot.adb.path){$lines.Add("ADB Linux : $($Snapshot.adb.path)")}
  $lines.Add('Dispositivos ADB:')
  if(@($Snapshot.adbDevices).Count -eq 0){$lines.Add('  nenhum listado nesta consulta')}
  foreach($transport in $Snapshot.adbDevices){$kind=if($transport.serial -match '^emulator-'){'emulador'}else{'físico'};$lines.Add("  $($transport.serial) | $($transport.state) | $kind")}
  if($Snapshot.selectedUsb -and $Snapshot.adb.state -eq 'AVAILABLE'){
    $physical=@($Snapshot.adbDevices|Where-Object {$_.serial -eq $Snapshot.selectedUsb.serial})
    if($physical.Count -eq 0){$lines.Add('Celular : não listado neste servidor; execute android-connect para conectar')}
    else{$lines.Add("Celular : $($physical[0].state) no ADB; status não executa a validação shell de connect")}
  }
  foreach($problem in $Snapshot.errors){$lines.Add("Erro: $problem")}
  $seconds=([double]$Snapshot.elapsedMs/1000).ToString('0.00',[Globalization.CultureInfo]::InvariantCulture)
  $lines.Add("Consulta: ${seconds}s | use --json para saída estruturada ou doctor para diagnóstico completo")
  return $lines -join [Environment]::NewLine
}
function Get-AdbListeningPorts([string]$DiagnosticText) {
  $ports=@();foreach($match in [regex]::Matches($DiagnosticText,':(503[7-9]|504[0-2])\s')){$ports+= [int]$match.Groups[1].Value};return @($ports|Select-Object -Unique)
}
function Show-Result($obj) { if($Json){$obj|ConvertTo-Json -Depth 12;return}; $obj }
function Select-Android($usbDevices,$Config) {
  $wanted=if($Serial){$Serial}else{[string]$Config.serial}
  $candidate=Find-UsbCandidate -Devices @($usbDevices|Where-Object isConnected) -Serial $wanted -BusId $Device -VidPids @($Config.usbIds) -StrictSerial ([bool]$Serial)
  if($candidate.status -eq 'selected'){return $candidate.device}
  if($candidate.status -ne 'ambiguous'){return $null}
  $eligible=$candidate.candidates
  if([Console]::IsInputRedirected -or $Yes){$choices=($eligible|ForEach-Object {"$($_.busid) $($_.description)"}) -join '; ';throw "Mais de um Android corresponde: $choices. Selecione com --device BUSID."}
  for($i=0;$i -lt $eligible.Count;$i++){Write-Host ("[{0}] {1} — {2} [{3}:{4}]" -f ($i+1),$eligible[$i].description,$eligible[$i].busid,$eligible[$i].vid,$eligible[$i].pid)}
  $choice=Read-Host 'Escolha o número do dispositivo';$index=0;if(-not [int]::TryParse($choice,[ref]$index) -or $index -lt 1 -or $index -gt $eligible.Count){throw 'Seleção inválida.'};return $eligible[$index-1]
}
function Invoke-Connect {
  $config=Read-Config; if($Distro){$selectedDistro=$Distro}else{$selectedDistro=[string]$config.distro}
  $wsl=Get-WslInfo; if(-not $selectedDistro){$default=$wsl.distributions|Where-Object default|Select-Object -First 1; if($default){$selectedDistro=$default.name}}
  if(-not $selectedDistro){ throw 'Nenhuma distribuição WSL foi encontrada.' }
  $usbipd=Find-Usbipd; $state=$null; $target=$null
  if($usbipd){$state=Get-UsbipState $usbipd; $target=Select-Android $state.devices $config}
  if(-not $target){$adb=Get-Adb $selectedDistro;$safeDevices=@($state.devices|ForEach-Object{$s=[string]$_.serial;if($s.Length -gt 4){$s='…'+$s.Substring($s.Length-4)}elseif($s){$s='…'};@{busid=$_.busid;description=$_.description;vid=$_.vid;pid=$_.pid;serial=$s;state=$_.deviceState}});$result=@{state='USB_NOT_FOUND';distro=$selectedDistro;usbipd=@{path=$usbipd;available=$state.available;error=(Protect-Text $state.error);devices=$safeDevices};adb=@{summary=(Protect-Text (($adb.raw -split "`n"|Select-Object -First 4) -join ' '))};message='Nenhum dispositivo correspondente aos critérios configurados foi encontrado.'}; Show-Result $result; return 2}
  $bus=[string]$target.busid; $usbState=[string]$target.deviceState; if(-not $usbState){$usbState=[string]$target.state}
  try{$serviceState=(Get-Service usbipd -ErrorAction Stop).Status.ToString();if($serviceState -ne 'Running'){throw "Serviço usbipd está $serviceState. Inicie-o manualmente pelo Windows e tente novamente."}}catch{if($_.Exception.Message -like 'Serviço usbipd está*'){throw};throw 'Serviço usbipd não está disponível; verifique USBIP Device Host no Windows.'}
  if((Get-UsbStateClass $usbState) -eq 'USB_NOT_SHARED'){
    if($DryRun){Write-Host "Ação necessária: usbipd bind --busid $bus (requer administrador)."; return 3}
    if($bus -notmatch '^\d+-\d+$'){throw 'BUSID inesperado; operação interrompida por segurança.'}
    $confirm=$false
    if(-not [Console]::IsInputRedirected){$a=Read-Host "O dispositivo $bus precisa de bind normal, que persiste e requer administrador. Abrir UAC? [s/N]";$confirm=$a -match '^(s|sim)$'}
    if(-not $confirm){Write-Host 'Bind não autorizado. Use PowerShell como administrador para executar usbipd bind --busid <BUSID>.';return 3}
    $p=Start-Process -FilePath $usbipd -Verb RunAs -Wait -PassThru -ArgumentList @('bind','--busid',$bus)
    if($p.ExitCode -ne 0){Write-Event usbip-bind failed "bind saiu com código $($p.ExitCode)" error; throw 'Não foi possível compartilhar o dispositivo. Faça bind normal em PowerShell como administrador.'}
    Start-Sleep -Milliseconds 700; $state=Get-UsbipState $usbipd; $target=Select-Android $state.devices $config
    if(-not $target){throw 'Estado do dispositivo mudou após bind.'}; $usbState=[string]$target.deviceState
  }
  if((Get-UsbStateClass $usbState) -ne 'USB_ATTACHED'){
    if($DryRun){Write-Host "Ação necessária: usbipd attach --wsl --busid $bus"; return 3}
    $attached=$false
    for($try=1;$try -le 3;$try++){
      $r=Invoke-Native $usbipd @('attach','--wsl','--busid',$bus) 20
      Start-Sleep -Milliseconds (400 * $try); $state=Get-UsbipState $usbipd; $target=Select-Android $state.devices $config
      Write-Event usbip-attach "attempt-$try" "exit=$($r.exitCode); attached=$([bool]($target -and [string]$target.deviceState -match 'Attached'))"
      if($target -and ([string]$target.deviceState -match 'Attached' -or [string]$target.state -match 'Attached')){$attached=$true;break}
      if($try -lt 3){Start-Sleep -Milliseconds (500 * $try)}
    }
    if(-not $attached){ throw "Attach não validado após três tentativas. Último erro: $($r.stderr) $($r.stdout)" }
  }
  $linux=Get-Adb $selectedDistro
  if($linux.raw -notmatch ('(?im)^.*ID\s+'+[regex]::Escape(([string]$target.vid).ToLower()+':'+([string]$target.pid).ToLower()))){ Write-Event usb-visible missing 'Dispositivo ainda não aparece no lsusb da distribuição.' warning; throw 'USB/IP está Attached, mas o Android ainda não aparece no WSL. Consulte android-connect doctor.' }
  $port=$Port; if(-not $port){$port=[int]$config.adbPort}; if(-not $port){$port=5037}
  $listening=Get-AdbListeningPorts $linux.raw
  if($DryRun){Write-Host "Dry run: USB visível; ADB seria consultado na porta $port. Listeners detectados: $($listening -join ', ')";return 0}
  $adb=Parse-AdbDevices $selectedDistro $port
  $serialWanted=if($Serial){$Serial}elseif($config.serial){[string]$config.serial}else{''}
  $physical=@($adb.devices|Where-Object {$_.state -eq 'device' -and ($serialWanted -eq '' -or $_.serial -eq $serialWanted) -and $_.serial -notmatch '^emulator-'})
  if(-not $physical){
    if(-not $physical -and $port -eq 5037){
      foreach($candidatePort in 5038..5042){
        $wasListening=$candidatePort -in $listening
        $candidate=Parse-AdbDevices $selectedDistro $candidatePort
        $candidatePhysical=@($candidate.devices|Where-Object {$_.state -eq 'device' -and ($serialWanted -eq '' -or $_.serial -eq $serialWanted) -and $_.serial -notmatch '^emulator-'})
        if($candidatePhysical){$port=$candidatePort;$adb=$candidate;$physical=$candidatePhysical;break}
        $port=$candidatePort;$adb=$candidate
        # adb devices starts a daemon if the port was free; never create daemons on more ports.
        if(-not $wasListening){break}
      }
    }
  }
  if(-not $physical){
    $states=@($adb.devices|Where-Object {$serialWanted -eq '' -or $_.serial -eq $serialWanted})
    if($states.state -contains 'unauthorized'){throw 'Dispositivo unauthorized: desbloqueie o celular e aceite a chave RSA exibida.'}
    if($states.state -contains 'offline'){throw 'Dispositivo offline: verifique o cabo e confirme se o ADB do Windows não está disputando este dispositivo.'}
    if($states.state -contains 'no permissions'){throw 'ADB informou no permissions. Verifique as permissões USB/udev na distribuição; não vou instalar regras sem consentimento.'}
    if(($adb.raw+$adb.error) -match '(?i)server version.*doesn.t match|version mismatch'){throw 'A versão do servidor ADB não é compatível com o cliente Linux. O doctor mostra versões e processos; encerre apenas o servidor identificado após confirmar que não atende outros dispositivos.'}
    $statesSummary=(@($adb.devices|ForEach-Object{"$($_.state)"}) -join ', ');throw "ADB não disponibilizou o serial físico na porta $port. Estados observados: $statesSummary"
  }
  $serialUsed=$physical[0].serial
  $validation=Invoke-Native 'wsl.exe' @('-d',$selectedDistro,'--exec','env',"ANDROID_ADB_SERVER_PORT=$port","ADB_SERVER_SOCKET=tcp:localhost:$port",'adb','-s',$serialUsed,'shell','getprop','ro.product.model') 12
  if($validation.exitCode -ne 0 -or -not $validation.stdout.Trim()){throw 'O comando real getprop falhou; dispositivo não será declarado pronto.'}
  $model=$validation.stdout.Trim()
  $canonicalModel=$model.ToUpperInvariant().Replace('_','-');$expectedModel=([string]$config.expectedModel).ToUpperInvariant().Replace('_','-')
  if($expectedModel -and $canonicalModel -ne $expectedModel){throw "O dispositivo selecionado respondeu modelo '$model'; esperado '$($config.expectedModel)'. Não vou identificá-lo como o Galaxy A15 configurado."}
  $config.distro=$selectedDistro; $config.serial=$serialUsed; $config.adbPort=$port
  $dir=Split-Path -Parent $script:ConfigPath; [IO.Directory]::CreateDirectory($dir)|Out-Null; $config|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
  Write-Event connect ready "Serial validado em porta $port"
  $out=@{state='READY';serial=$serialUsed;model=$model;distro=$selectedDistro;port=$port;devices=$adb.devices;usbState='Attached';physicalValidation='adb shell getprop ro.product.model'}
  if($Json){$out|ConvertTo-Json -Depth 8}else{
    Write-Host "Android conectado — $($out.model) [$serialUsed] via ADB :$port ($selectedDistro)" -ForegroundColor Green
    Write-Host 'Para usar adb direto nesta sessão WSL: eval "$(android-connect env)"'
  }
  return 0
}
function Invoke-Doctor {
  $config=Read-Config; $usbipd=Find-Usbipd; $state=if($usbipd){Get-UsbipState $usbipd}else{@{available=$false;error='usbipd.exe não encontrado';devices=@()}}
  $wsl=Get-WslInfo; $dist=if($Distro){$Distro}elseif($config.distro){$config.distro}else{($wsl.distributions|Where-Object default|Select-Object -First 1).name}
  $adb=if($dist){Get-Adb $dist}else{@{raw='';error='sem distribuição WSL'}}
  $service=try{(Get-Service usbipd -ErrorAction Stop).Status.ToString()}catch{'indisponível'}
  $portProbe=if($Port){$Port}elseif($config.adbPort){$config.adbPort}else{5037}
  $adbListening=Get-AdbListeningPorts $adb.raw
  $adbDevices=if($dist -and $portProbe -in $adbListening){(Parse-AdbDevices $dist $portProbe).devices}else{@()}
  $safeUsb=@($state.devices|ForEach-Object{$s=[string]$_.serial;if($s.Length -gt 4){$s='…'+$s.Substring($s.Length-4)}elseif($s){$s='…'};@{busid=$_.busid;description=$_.description;vid=$_.vid;pid=$_.pid;serial=$s;state=$_.deviceState}})
  $safeAdb=@($adbDevices|ForEach-Object{$s=[string]$_.serial;if($s.Length -gt 4){$s='…'+$s.Substring($s.Length-4)}elseif($s){$s='…'};@{serial=$s;state=$_.state;details=$_.details}})
  $safeProcesses=Protect-Text (($adb.raw -split "PROCESSES`n"|Select-Object -Skip 1 -First 1))
  $hostPorts=@();foreach($p in @(5037,5038,5039,5040,5041,5042)){try{foreach($c in @(Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction Stop)){$owner=Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue|Select-Object -First 1;$exe=try{$owner.Path}catch{$null};$exeName=if($exe){Split-Path -Leaf $exe}else{$null};$version=if($exe -and $owner.ProcessName -match '^adb'){((Invoke-Native $exe @('version') 5).stdout -split "`r?`n"|Select-Object -First 2) -join ' '}else{$null};$hostPorts+=@{port=$p;pid=$c.OwningProcess;process=$owner.ProcessName;executable=$exeName;adbVersion=$version}}}catch{}}
  $windowsUsbLogs=@();try{$windowsUsbLogs=@(Get-WinEvent -FilterHashtable @{ProviderName='usbipd';StartTime=(Get-Date).AddHours(-1)} -MaxEvents 10 -ErrorAction Stop|ForEach-Object{@{time=$_.TimeCreated.ToUniversalTime().ToString('o');id=$_.Id;level=$_.LevelDisplayName;message=(Protect-Text $_.Message)}})}catch{}
  $recentLogs=Protect-Text (($adb.raw -split "LOGS`n"|Select-Object -Skip 1 -First 1))
  $report=@{generatedAt=[DateTime]::UtcNow.ToString('o');windows=[Environment]::OSVersion.VersionString;usbipd=@{path=$(if($usbipd){Split-Path -Leaf $usbipd}else{$null});available=$state.available;version=$state.version;error=(Protect-Text $state.error);service=$service;devices=$safeUsb;recentWindowsLogs=$windowsUsbLogs};wsl=$wsl;selectedDistro=$dist;adb=@{versionPath=($adb.raw -split "`n"|Select-Object -First 2);ports=($adb.raw -split "PORTS`n"|Select-Object -Skip 1 -First 1);windowsListeners=$hostPorts;devices=$safeAdb;environment=($adb.raw -split "ENV`n"|Select-Object -Skip 1 -First 1);processes=$safeProcesses;recentLogs=$recentLogs};hypotheses=@('Servidor ADB concorrente só pode ser confirmado identificando PID e executável que escutam na porta; falha de bind sem PID visível não prova interferência Windows/WSL.');events=@($script:Events)}
  $jsonText=$report|ConvertTo-Json -Depth 14
  $adbSummary=(($adb.raw -split "`n"|Select-Object -First 2) -join ' ')
  $textReport=@("Android Connect doctor — $($report.generatedAt)","Windows: $($report.windows)","WSL: $($wsl.version) | kernel $($wsl.kernel) | rede $($wsl.networkingMode)","Distro: $dist","usbipd: $($state.version) | serviço $service | disponível $($state.available)","ADB: $adbSummary","Listeners Windows: $($hostPorts|ConvertTo-Json -Compress)","Dispositivos USB (serial mascarado): $($safeUsb|ConvertTo-Json -Compress)","Transportes ADB (serial mascarado): $($safeAdb|ConvertTo-Json -Compress)","Hipótese: $($report.hypotheses[0])") -join [Environment]::NewLine
  $content=if($Json -or $Format -eq 'json'){$jsonText}else{$textReport}
  if($OutputPath){$content|Set-Content -LiteralPath $OutputPath -Encoding UTF8}
  Write-Output $content
}
switch($Command.ToLowerInvariant()){
  {$_ -in 'help','-h','--help'} { @'
android-connect [status|doctor|fix|devices|disconnect|logs|env|exec|shell-init] [opções]
  --device BUSID | --serial SERIAL | --distro NAME | --port PORT
  --format text|json --output PATH (doctor)
  --dry-run --verbose --json --yes
  env [--shell bash|powershell] [--json] : ambiente do servidor selecionado
  shell-init : integração Bash opcional; eval "$(android-connect shell-init)"
Sem comando: conecta, aplica apenas correções seguras e valida com getprop.
'@; exit 0 }
  {$_ -in 'connect',''} { try{$code=Invoke-Connect;exit [int]$code}catch{Write-Event connect failed $_.Exception.Message error;Write-Error $_.Exception.Message;exit 1} }
  'status' { $snapshot=Get-StatusSnapshot -DistroName $Distro -AdbPort $Port;if($Json){$snapshot|ConvertTo-Json -Depth 12}else{Format-StatusSnapshot $snapshot};if($snapshot.errors.Count){exit 1};exit 0 }
  'doctor' { Invoke-Doctor;exit 0 }
  'fix' { if(-not $DryRun){Write-Host 'Aplicando somente correções seguras via fluxo de conexão.'}; try{$code=Invoke-Connect;exit [int]$code}catch{Write-Error $_.Exception.Message;exit 1} }
  'devices' { $config=Read-Config; $dist=if($Distro){$Distro}elseif($config.distro){$config.distro}else{(Get-WslInfo).distributions|Where-Object default|Select-Object -ExpandProperty name -First 1}; $port=if($Port){$Port}elseif($config.adbPort){$config.adbPort}else{5037};$diag=Get-Adb $dist;$o=if($port -in (Get-AdbListeningPorts $diag.raw)){(Parse-AdbDevices $dist $port).devices}else{@()}; if($Json){$o|ConvertTo-Json -Depth 5}else{$o|Format-Table -AutoSize};exit 0 }
  'disconnect' { $config=Read-Config; $dist=if($Distro){$Distro}elseif($config.distro){$config.distro}else{(Get-WslInfo).distributions|Where-Object default|Select-Object -ExpandProperty name -First 1}; $ser=if($Serial){$Serial}else{[string]$config.serial}; if(-not $ser){throw 'Configure ou informe --serial.'}; $u=Find-Usbipd;$st=Get-UsbipState $u;$dev=@($st.devices|Where-Object {$_.deviceState -match 'Attached' -and ($_.serial -eq $ser -or $_.description -match [regex]::Escape($ser))})|Select-Object -First 1; if(-not $dev){Write-Host 'Dispositivo não está Attached.';exit 0}; if(-not $Yes){$answer=Read-Host "Desconectar $($dev.busid) do WSL? [s/N]";if($answer -notmatch '^(s|sim)$'){exit 3}}; $r=Invoke-Native $u @('detach','--busid',[string]$dev.busid) 15; if($r.exitCode){throw $r.stderr}; Write-Host "Desconectado: $($dev.busid)";exit 0 }
  'logs' { if(Test-Path $script:LogPath){Get-Content $script:LogPath -Tail 50}else{Write-Host 'Nenhum log disponível.'};exit 0 }
  'env' {
    $config=Read-Config;$chosenPort=if($Port){$Port}elseif($config.adbPort){[int]$config.adbPort}else{5037}
    $text=Format-AdbEnvironment -AdbPort $chosenPort -ShellName $ShellName
    if($Json){[ordered]@{ANDROID_ADB_SERVER_PORT=[string]$chosenPort;ADB_SERVER_SOCKET="tcp:localhost:$chosenPort"}|ConvertTo-Json}
    else{[Console]::Out.Write($text)}
    exit 0
  }
  'shell-init' {
    if($ShellName -ne 'bash'){throw 'shell-init suporta Bash. No PowerShell, aplique android-connect env --shell powershell com Invoke-Expression.'}
    [Console]::Out.Write((Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'android-connect.bash') -Encoding UTF8))
    exit 0
  }
  'exec' { if(-not $Remaining -or $Remaining[0] -ne '--'){throw 'Uso: android-connect exec -- <comando> [argumentos]'}; $config=Read-Config;$dist=if($Distro){$Distro}elseif($config.distro){$config.distro}else{(Get-WslInfo).distributions|Where-Object default|Select-Object -ExpandProperty name -First 1};$port=if($Port){$Port}elseif($config.adbPort){$config.adbPort}else{5037};$cmds=@($Remaining|Select-Object -Skip 1);if(-not $cmds){throw 'Comando vazio.'}; & wsl.exe -d $dist --exec env "ANDROID_ADB_SERVER_PORT=$port" "ADB_SERVER_SOCKET=tcp:localhost:$port" @cmds; exit $LASTEXITCODE }
  default { Write-Error "Comando desconhecido: $Command";exit 2 }
}
