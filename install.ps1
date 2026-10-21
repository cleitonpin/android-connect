#requires -Version 5.1
[CmdletBinding()]
param(
  [ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+$')][string]$Version = 'v0.1.2',
  [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs/AndroidConnect'),
  [switch]$NoPath
)

# Local scope keeps preferences set by irm | iex out of the caller's session.
& {
  $ErrorActionPreference = 'Stop'
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $base = "https://raw.githubusercontent.com/cleitonpin/android-connect/$Version"
  $files = @('src/AndroidConnect.ps1', 'src/AndroidConnect.Core.psm1', 'src/android-connect.bash', 'bin/android-connect', 'bin/android-connect.ps1', 'LICENSE')
  [IO.Directory]::CreateDirectory($InstallDirectory) | Out-Null
  $stage = Join-Path $InstallDirectory ('.stage-' + [guid]::NewGuid().ToString('N'))
  $current = Join-Path $InstallDirectory 'current'
  $backup = Join-Path $InstallDirectory ('.backup-' + [guid]::NewGuid().ToString('N'))
  [IO.Directory]::CreateDirectory($stage) | Out-Null
  try {
    $manifest = Join-Path $stage 'SHA256SUMS'
    Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile $manifest -TimeoutSec 30
    $hashes = @{}
    foreach ($line in (Get-Content -LiteralPath $manifest)) {
      if ($line -match '^([a-fA-F0-9]{64})  (.+)$') { $hashes[$Matches[2]] = $Matches[1] }
    }
    foreach ($file in $files) {
      if (-not $hashes.ContainsKey($file)) { throw "SHA256 ausente no manifesto: $file" }
      $destination = Join-Path $stage $file
      [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
      Invoke-WebRequest -UseBasicParsing -Uri "$base/$file" -OutFile $destination -TimeoutSec 30
      if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $hashes[$file]) {
        throw "SHA256 divergente: $file. A instalacao existente foi preservada."
      }
    }
    # Promote verified files; restore the previous version if promotion fails.
    if (Test-Path -LiteralPath $current) { Move-Item -LiteralPath $current -Destination $backup }
    try { Move-Item -LiteralPath $stage -Destination $current }
    catch {
      if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $current }
      throw
    }
    if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
    $bin = Join-Path $InstallDirectory 'bin'
    [IO.Directory]::CreateDirectory($bin) | Out-Null
    $shim = @'
@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\current\bin\android-connect.ps1" %*
exit /b %errorlevel%
'@
    [IO.File]::WriteAllText((Join-Path $bin 'android-connect.cmd'), $shim, [Text.Encoding]::ASCII)
    if (-not $NoPath) {
      $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
      if ($bin.TrimEnd('\') -notin @($userPath -split ';' | ForEach-Object { $_.TrimEnd('\') })) {
        $newPath = if ($userPath) { $userPath.TrimEnd(';') + ';' + $bin } else { $bin }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
      }
      if ($bin.TrimEnd('\') -notin @($env:Path -split ';' | ForEach-Object { $_.TrimEnd('\') })) { $env:Path += ';' + $bin }
    }
    Write-Host "Android Connect $Version instalado em $InstallDirectory"
    Write-Host "Execute: android-connect help"
    if ($NoPath) { Write-Host "PATH nao alterado. Comando: $bin\android-connect.cmd" }
  }
  finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force } }
}
