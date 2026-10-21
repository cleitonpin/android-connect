#requires -Version 5.1
# Native Windows entry point. Keep child arguments separate from CLI options.
$forward = [Collections.Generic.List[string]]::new()
$flags = @{
  '--device'='-Device'; '--serial'='-Serial'; '--distro'='-Distro'; '--port'='-Port'
  '--output'='-OutputPath'; '--format'='-Format'; '--json'='-Json'; '--yes'='-Yes'
  '--dry-run'='-DryRun'; '--verbose'='-VerboseOutput'
}
$execSeen = $false
$passthrough = $false
$hasSeparator = $args -contains '--'
foreach ($arg in $args) {
  if ($passthrough) { $forward.Add([string]$arg); continue }
  # PowerShell consumes a bare -- when invoking a script directly with &.
  if ($execSeen -and -not $hasSeparator) { $forward.Add('--'); $forward.Add([string]$arg); $passthrough = $true; continue }
  if ($execSeen -and $arg -eq '--') { $forward.Add('--'); $passthrough = $true; continue }
  if ($flags.ContainsKey([string]$arg)) { $forward.Add($flags[[string]$arg]) }
  else { $forward.Add([string]$arg); if ($arg -eq 'exec') { $execSeen = $true } }
}
$engine = if ($env:ANDROID_CONNECT_POWERSHELL) { $env:ANDROID_CONNECT_POWERSHELL } else { 'powershell.exe' }
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/AndroidConnect.ps1'
$nativeArgs = @($forward.ToArray())
& $engine -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath @nativeArgs
exit $LASTEXITCODE
