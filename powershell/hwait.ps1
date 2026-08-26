#!/usr/bin/env pwsh
# usage: hwait <url> [timeout]
param([Parameter(Position = 0)][string]$Url, [Parameter(Position = 1)][string]$Timeout = '60')

$ErrorActionPreference = 'Stop'
function Say($m) { [Console]::Error.WriteLine("hwait: $m") }
function Die($m) { Say $m; exit 1 }

if (-not $Url) {
    [Console]::Error.WriteLine("usage: hwait <url> [timeout]`n`nPolls until the url answers 2xx, then exits 0. Default timeout 60 seconds.")
    exit 2
}
if ($Timeout -notmatch '^[0-9]+$') { Die "timeout must be a whole number of seconds: $Timeout" }

$hget = Join-Path $PSScriptRoot 'hget.ps1'
if (-not (Test-Path $hget)) { Die 'cannot find hget.ps1' }
$pwshPath = (Get-Command pwsh).Source
$deadline = (Get-Date).AddSeconds([int]$Timeout)

while ($true) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwshPath
    foreach ($a in @('-NoProfile', '-File', $hget, $Url)) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardOutput.BaseStream.CopyTo([System.IO.Stream]::Null)
    $p.StandardError.ReadToEnd() | Out-Null
    $p.WaitForExit()
    if ($p.ExitCode -eq 0) { exit 0 }
    if ((Get-Date) -ge $deadline) { Die "gave up on $Url after ${Timeout}s" }
    Start-Sleep -Seconds 1
}
