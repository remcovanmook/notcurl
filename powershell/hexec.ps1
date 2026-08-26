#!/usr/bin/env pwsh
# 2026 Remco van Mook @rvmnl - Apache-2.0 - github.com/remcovanmook/notcurl
# usage: hexec [-n] <url> [<sha256-url>|<sha256>] [args...]
# PowerShell consumes a bare -- itself, so script arguments follow the checksum
# directly rather than after a separator.
param(
    [switch]$n,
    [Parameter(Position = 0)][string]$Url,
    [Parameter(Position = 1)][string]$Sum,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
function Say($m) { [Console]::Error.WriteLine("hexec: $m") }
function Die($m) { Say $m; exit 1 }

if (-not $Url) {
    [Console]::Error.WriteLine("usage: hexec [-n] <url> [<sha256-url>|<sha256>] [args...]`n  -n   fetch and verify only, then print the path")
    exit 2
}
$hget = Join-Path $PSScriptRoot 'hget.ps1'
if (-not (Test-Path $hget)) { Die 'cannot find hget.ps1' }
$pwshPath = (Get-Command pwsh).Source
if ($null -eq $Rest) { $Rest = @() }
while ($Rest.Count -gt 0 -and ($Rest[0] -eq '--' -or $Rest[0] -eq '')) { $Rest = @($Rest[1..($Rest.Count - 1)]) }

function Fetch($url, $out) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwshPath
    foreach ($a in @('-NoProfile', '-File', $hget, $url)) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $fs = [System.IO.File]::Create($out)
    $p.StandardOutput.BaseStream.CopyTo($fs)
    $fs.Close(); $p.WaitForExit()
    return $p.ExitCode
}

$tmp = [System.IO.Path]::GetTempFileName()
try {
    if ((Fetch $Url $tmp) -ne 0) { Die "download failed: $Url" }
    if ((Get-Item $tmp).Length -eq 0) { Die "downloaded an empty file: $Url" }

    if (-not $Sum) {
        Say "WARNING: no checksum given, running $Url unverified"
    } else {
        $want = $Sum.ToLower()
        if ($Sum.Length -ne 64 -or $Sum -notmatch '^[0-9A-Fa-f]+$') {
            $sf = "$tmp.sum"
            if ((Fetch $Sum $sf) -ne 0) { Die "download failed: $Sum" }
            $name = ($Url -split '/')[-1]
            $want = ''
            foreach ($line in [System.IO.File]::ReadAllLines($sf)) {
                $f = @($line -split '\s+' | Where-Object { $_ -ne '' })
                if ($f.Count -lt 1 -or $f[0].Length -ne 64 -or $f[0] -notmatch '^[0-9A-Fa-f]+$') { continue }
                if (-not $want) { $want = $f[0].ToLower() }
                if ($f.Count -gt 1) {
                    $n2 = ($f[1] -replace '^\*', '') -replace '.*/', ''
                    if ($n2 -eq $name) { $want = $f[0].ToLower(); break }
                }
            }
            Remove-Item $sf -ErrorAction SilentlyContinue
            if (-not $want) { Die "no sha256 for $name in $Sum" }
        }
        $got = (Get-FileHash -Algorithm SHA256 $tmp).Hash.ToLower()
        if ($want -ne $got) { Die "CHECKSUM MISMATCH, refusing to run`n  expected $want`n  got      $got" }
        Say "sha256 verified: $got"
    }

    if ($n) {
        Say 'not executing (-n); script saved at:'
        [Console]::Out.WriteLine($tmp)
        $tmp = $null
        exit 0
    }

    $first = ''
    $fs = [System.IO.File]::OpenRead($tmp)
    $sr = [System.IO.StreamReader]::new($fs)
    $first = $sr.ReadLine(); $sr.Close()
    Say "executing $Url"
    if ($first -and $first.StartsWith('#!')) {
        $parts = @($first.Substring(2).Trim() -split '\s+')
        $iargs = @(); if ($parts.Count -gt 1) { $iargs = $parts[1..($parts.Count - 1)] }
        $a1 = $iargs + @($tmp) + $Rest
        & $parts[0] @a1
    } else {
        $a2 = @('-NoProfile', '-File', $tmp) + $Rest
        & $pwshPath @a2
    }
    exit $LASTEXITCODE
} finally {
    if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp -ErrorAction SilentlyContinue }
}
