#!/usr/bin/env pwsh
# usage: hmirror [baseurl] [file]
param([Parameter(Position = 0)][string]$A, [Parameter(Position = 1)][string]$B)

$ErrorActionPreference = 'Stop'
function Say($m) { [Console]::Error.WriteLine("hmirror: $m") }
function Die($m) { Say $m; exit 1 }

$base = ''; $file = ''
if ($A -match '^https?://') { $base = $A.TrimEnd('/'); $file = $B }
else { $file = $A; if ($B) { Die 'usage: hmirror [baseurl] [file]' } }

$hget = Join-Path $PSScriptRoot 'hget.ps1'
if (-not (Test-Path $hget)) { Die 'cannot find hget.ps1' }
$pwshPath = (Get-Command pwsh).Source

function Fetch($url, $out) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwshPath
    foreach ($a in @('-NoProfile', '-File', $hget, $url)) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $fs = [System.IO.File]::Create($out)
    $p.StandardOutput.BaseStream.CopyTo($fs)
    $fs.Close()
    $e = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0 -and $e) { [Console]::Error.Write($e) }
    return $p.ExitCode
}

if ($file) {
    if (-not (Test-Path $file)) { Die "cannot read $file" }
    $lines = [System.IO.File]::ReadAllLines((Resolve-Path $file))
} else {
    $sr = [System.IO.StreamReader]::new([Console]::OpenStandardInput())
    $lines = ($sr.ReadToEnd() -split "`r?`n"); $sr.Close()
}
$ok = 0; $bad = 0
foreach ($line in $lines) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    $f = @($t -split '\s+' | Where-Object { $_ -ne '' })
    if ($f.Count -gt 1) { $want = $f[0].ToLower(); $entry = $f[1] } else { $want = ''; $entry = $f[0] }
    $entry = ($entry -replace '^\*', '') -replace '^\./', ''
    if ($entry -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $url = $entry; $name = ($entry -split '/')[-1] }
    elseif ($base) { $url = "$base/$($entry.TrimStart('/'))"; $name = $entry.TrimStart('/') }
    else { $url = $entry; $name = ($entry -split '/')[-1] }
    $name = ($name -split '\?')[0]
    if (-not $name) { Say "no filename in $entry"; $bad++; continue }
    if ("/$name/" -match '/\.\./') { Say "refusing .. in path: $entry"; $bad++; continue }
    $dir = Split-Path -Parent $name
    if ($dir) { $null = New-Item -ItemType Directory -Force -Path $dir }
    if ((Fetch $url $name) -ne 0) { Remove-Item $name -ErrorAction SilentlyContinue; $bad++; continue }
    if ($want) {
        $got = (Get-FileHash -Algorithm SHA256 $name).Hash.ToLower()
        if ($want -ne $got) { Say "CHECKSUM MISMATCH for $name, removed"; Remove-Item $name -ErrorAction SilentlyContinue; $bad++; continue }
        Say "$name verified"
    } else { Say "$name (unverified)" }
    $ok++
}
Say "$ok fetched, $bad failed"
if ($bad -ne 0) { exit 1 }
