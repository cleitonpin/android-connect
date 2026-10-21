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
  [switch]$DryRun,
  [switch]$VerboseOutput,
  [switch]$Json,
  [switch]$Yes,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Remaining
)
$ErrorActionPreference = 'Stop'
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
function Invoke-Native([string]$File,[string[]]$Args,[int]$TimeoutSec=12) {
  $psi=[Diagnostics.ProcessStartInfo]::new(); $psi.FileName=$File; $psi.UseShellExecute=$false; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.CreateNoWindow=$true
  # ProcessStartInfo.ArgumentList is unavailable on Windows PowerShell 5.1/.NET Framework.
  $quoted = foreach($arg in $Args) {
    $value=[string]$arg
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
  try { [void]$proc.Start();$started=$true; $outTask=$proc.StandardOutput.ReadToEndAsync(); $errTask=$proc.StandardError.ReadToEndAsync(); if(-not $proc.WaitForExit($TimeoutSec*1000)){ Stop-NativeChild $proc; return @{ exitCode=124; stdout=''; stderr='timeout' } }; $proc.WaitForExit(); return @{exitCode=$proc.ExitCode;stdout=$outTask.Result;stderr=$errTask.Result} } catch { if($started){Stop-NativeChild $proc};if($_.Exception -is [Management.Automation.PipelineStoppedException]){throw};return @{exitCode=127;stdout='';stderr=$_.Exception.Message} }
}
function Find-Usbipd { $p=Get-Command usbipd.exe,usbipd -ErrorAction SilentlyContinue | Select-Object -First 1; if($p){return $p.Source}; $candidate=Join-Path $env:ProgramW6432 'usbipd-win/usbipd.exe'; if(Test-Path $candidate){return $candidate}; return $null }
function Get-UsbipState([string]$Usbipd) {
  # usbipd ships a version-matched PowerShell module with typed state fields.
  $module=Join-Path $env:ProgramW6432 'usbipd-win/Usbipd.Powershell.dll'
  if(Test-Path -LiteralPath $module) {
    try {
      Import-Module $module -ErrorAction Stop
      $devices=@(Get-UsbipdDevice | ForEach-Object {
        $props=@{}; foreach($p in $_.PSObject.Properties){$props[$p.Name]=$p.Value}
        $hardware=[string]$props.HardwareId
        $vid='';$pid='';if($hardware -match 'VID_([0-9A-Fa-f]{4}).*PID_([0-9A-Fa-f]{4})'){$vid=$Matches[1].ToLower();$pid=$Matches[2].ToLower()}
        $instance=[string]$props.InstanceId
        $serial='';if($instance -match '\\([^\\]+)$'){$serial=$Matches[1]}
        $state=if($props.IsAttached){'Attached'}elseif($props.IsBound){'Shared'}else{'Not shared'}
        [pscustomobject]@{busid=[string]$props.BusId;description=[string]$props.Description;vid=$vid;pid=$pid;serial=$serial;deviceState=$state;state=$state;isConnected=[bool]$props.IsConnected;instanceId=$instance}
      })
      $v=Invoke-Native $Usbipd @('--version') 5
      return @{available=$true;version=$v.stdout.Trim();devices=$devices}
    } catch { return @{available=$false;error=$_.Exception.Message;devices=@()} }
  }
  return @{available=$false;error='Módulo Usbipd.Powershell.dll não encontrado; esperado na instalação versionada do usbipd-win.';devices=@()}
}
function Get-WslInfo {
  $list=Invoke-Native 'wsl.exe' @('--list','--verbose') 10
  $ver=Invoke-Native 'wsl.exe' @('--version') 10
  $listText=$list.stdout -replace "`0",'';$items=@(); foreach($line in ($listText -split "`r?`n")){ if($line -match '^\s*(\*)?\s*(.+?)\s+(Running|Stopped)\s+(\d+)\s*$'){ $items+=@{name=$Matches[2].Trim();state=$Matches[3];version=[int]$Matches[4];default=[bool]$Matches[1]} } }
  $kernel=Invoke-Native 'wsl.exe' @('-e','uname','-r') 8
  $network='unknown';$wslConfig=Join-Path $env:USERPROFILE '.wslconfig';if(Test-Path $wslConfig){$line=Get-Content $wslConfig|Where-Object {$_ -match '^\s*networkingMode\s*='}|Select-Object -First 1;if($line -match '=\s*(\S+)'){$network=$Matches[1]}}
  return @{ distributions=$items;version=($ver.stdout -replace "`0",'').Trim();kernel=$kernel.stdout.Trim();networkingMode=$network;error=$list.stderr }
}
function Get-Adb([string]$DistroName) {
  $cmd="command -v adb; adb version 2>&1; printf '\nENV\n'; env | grep -E '^(ADB_SERVER_SOCKET|ANDROID_ADB_SERVER_PORT|ANDROID_ADB_SERVER_ADDRESS)=' || true; printf '\nPORTS\n'; (ss -ltnp 2>/dev/null || true) | grep -E ':(503[7-9]|504[0-2])\b' || true; printf '\nUSB\n'; (lsusb 2>&1 || true); printf '\nPROCESSES\n'; (ps -eo pid,args 2>/dev/null || true) | grep '[a]db'; printf '\nLOGS\n'; (dmesg --ctime 2>/dev/null | tail -n 20 || true); (tail -n 30 /tmp/adb.*.log 2>/dev/null | tail -n 30 || true)"
  $r=Invoke-Native 'wsl.exe' @('-d',$DistroName,'--','bash','-lc',$cmd) 15
  return @{exitCode=$r.exitCode;raw=$r.stdout;error=$r.stderr}
}
function Parse-AdbDevices([string]$DistroName,[int]$AdbPort) {
  $args=@('-d',$DistroName,'--','env',"ANDROID_ADB_SERVER_PORT=$AdbPort","ADB_SERVER_SOCKET=tcp:localhost:$AdbPort",'adb','devices','-l')
  $r=Invoke-Native 'wsl.exe' $args 15
  $rows=@(); foreach($line in ($r.stdout -split "`r?`n")){ if($line -match '^([^\s]+)\s+(device|unauthorized|offline|no permissions)(?:\s+(.*))?$'){ $rows+=@{serial=$Matches[1];state=$Matches[2];details=$Matches[3]} } }
  return @{exitCode=$r.exitCode;devices=$rows;raw=$r.stdout;error=$r.stderr}
}
function Get-AdbListeningPorts([string]$DiagnosticText) {
  $ports=@();foreach($match in [regex]::Matches($DiagnosticText,':(503[7-9]|504[0-2])\s')){$ports+= [int]$match.Groups[1].Value};return @($ports|Select-Object -Unique)
}
function Show-Result($obj) { if($Json){$obj|ConvertTo-Json -Depth 12;return}; $obj }
function Select-Android($usbDevices,$Config) {
  $wanted=if($Serial){$Serial}else{[string]$Config.serial}
  $candidate=Find-UsbCandidate -Devices $usbDevices -Serial $wanted -BusId $Device -VidPids @($Config.usbIds) -StrictSerial ([bool]$Serial)
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
  $validation=Invoke-Native 'wsl.exe' @('-d',$selectedDistro,'--','env',"ANDROID_ADB_SERVER_PORT=$port","ADB_SERVER_SOCKET=tcp:localhost:$port",'adb','-s',$serialUsed,'shell','getprop','ro.product.model') 12
  if($validation.exitCode -ne 0 -or -not $validation.stdout.Trim()){throw 'O comando real getprop falhou; dispositivo não será declarado pronto.'}
  $model=$validation.stdout.Trim()
  $canonicalModel=$model.ToUpperInvariant().Replace('_','-');$expectedModel=([string]$config.expectedModel).ToUpperInvariant().Replace('_','-')
  if($expectedModel -and $canonicalModel -ne $expectedModel){throw "O dispositivo selecionado respondeu modelo '$model'; esperado '$($config.expectedModel)'. Não vou identificá-lo como o Galaxy A15 configurado."}
  $config.distro=$selectedDistro; $config.serial=$serialUsed; $config.adbPort=$port
  $dir=Split-Path -Parent $script:ConfigPath; [IO.Directory]::CreateDirectory($dir)|Out-Null; $config|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
  Write-Event connect ready "Serial validado em porta $port"
  $out=@{state='READY';serial=$serialUsed;model=$model;distro=$selectedDistro;port=$port;devices=$adb.devices;usbState='Attached';physicalValidation='adb shell getprop ro.product.model'}
  if($Json){$out|ConvertTo-Json -Depth 8}else{Write-Host "Android conectado — $($out.model) [$serialUsed] via ADB :$port ($selectedDistro)" -ForegroundColor Green}
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
android-connect [status|doctor|fix|devices|disconnect|logs|env|exec] [opções]
  --device BUSID | --serial SERIAL | --distro NAME | --port PORT
  --format text|json --output PATH (doctor)
  --dry-run --verbose --json --yes
Sem comando: conecta, aplica apenas correções seguras e valida com getprop.
'@; exit 0 }
  {$_ -in 'connect',''} { try{$code=Invoke-Connect;exit [int]$code}catch{Write-Event connect failed $_.Exception.Message error;Write-Error $_.Exception.Message;exit 1} }
  'status' { $config=Read-Config; $dist=if($Distro){$Distro}elseif($config.distro){$config.distro}else{(Get-WslInfo).distributions|Where-Object default|Select-Object -ExpandProperty name -First 1}; $port=if($Port){$Port}elseif($config.adbPort){$config.adbPort}else{5037}; $diag=if($dist){Get-Adb $dist}else{@{raw=''}};$d=if($dist -and $port -in (Get-AdbListeningPorts $diag.raw)){Parse-AdbDevices $dist $port}else{@{devices=@()}}; $o=@{distro=$dist;port=$port;adbDevices=$d.devices;usbipd=$(if($u=Find-Usbipd){Get-UsbipState $u}else{$null})}; if($Json){$o|ConvertTo-Json -Depth 8}else{$o|ConvertTo-Json -Depth 8};exit 0 }
  'doctor' { Invoke-Doctor;exit 0 }
  'fix' { if(-not $DryRun){Write-Host 'Aplicando somente correções seguras via fluxo de conexão.'}; try{$code=Invoke-Connect;exit [int]$code}catch{Write-Error $_.Exception.Message;exit 1} }
  'devices' { $config=Read-Config; $dist=if($Distro){$Distro}elseif($config.distro){$config.distro}else{(Get-WslInfo).distributions|Where-Object default|Select-Object -ExpandProperty name -First 1}; $port=if($Port){$Port}elseif($config.adbPort){$config.adbPort}else{5037};$diag=Get-Adb $dist;$o=if($port -in (Get-AdbListeningPorts $diag.raw)){(Parse-AdbDevices $dist $port).devices}else{@()}; if($Json){$o|ConvertTo-Json -Depth 5}else{$o|Format-Table -AutoSize};exit 0 }
  'disconnect' { $config=Read-Config; $dist=if($Distro){$Distro}elseif($config.distro){$config.distro}else{(Get-WslInfo).distributions|Where-Object default|Select-Object -ExpandProperty name -First 1}; $ser=if($Serial){$Serial}else{[string]$config.serial}; if(-not $ser){throw 'Configure ou informe --serial.'}; $u=Find-Usbipd;$st=Get-UsbipState $u;$dev=@($st.devices|Where-Object {$_.deviceState -match 'Attached' -and ($_.serial -eq $ser -or $_.description -match [regex]::Escape($ser))})|Select-Object -First 1; if(-not $dev){Write-Host 'Dispositivo não está Attached.';exit 0}; if(-not $Yes){$answer=Read-Host "Desconectar $($dev.busid) do WSL? [s/N]";if($answer -notmatch '^(s|sim)$'){exit 3}}; $r=Invoke-Native $u @('detach','--busid',[string]$dev.busid) 15; if($r.exitCode){throw $r.stderr}; Write-Host "Desconectado: $($dev.busid)";exit 0 }
  'logs' { if(Test-Path $script:LogPath){Get-Content $script:LogPath -Tail 50}else{Write-Host 'Nenhum log disponível.'};exit 0 }
  'env' { $config=Read-Config;$port=if($Port){$Port}elseif($config.adbPort){$config.adbPort}else{5037}; Write-Output "ANDROID_ADB_SERVER_PORT=$port"; Write-Output "ADB_SERVER_SOCKET=tcp:localhost:$port";exit 0 }
  'exec' { if(-not $Remaining -or $Remaining[0] -ne '--'){throw 'Uso: android-connect exec -- <comando> [argumentos]'}; $config=Read-Config;$dist=if($Distro){$Distro}elseif($config.distro){$config.distro}else{(Get-WslInfo).distributions|Where-Object default|Select-Object -ExpandProperty name -First 1};$port=if($Port){$Port}elseif($config.adbPort){$config.adbPort}else{5037};$cmds=@($Remaining|Select-Object -Skip 1);if(-not $cmds){throw 'Comando vazio.'}; & wsl.exe -d $dist -- env "ANDROID_ADB_SERVER_PORT=$port" "ADB_SERVER_SOCKET=tcp:localhost:$port" @cmds; exit $LASTEXITCODE }
  default { Write-Error "Comando desconhecido: $Command";exit 2 }
}
