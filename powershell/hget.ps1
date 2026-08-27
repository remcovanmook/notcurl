#!/usr/bin/env pwsh
# 2026 Remco van Mook @rvmnl - Apache-2.0 - github.com/remcovanmook/notcurl
# usage: hget <url>
param([Parameter(Position = 0)][string]$Url)

$ErrorActionPreference = 'Stop'
if (-not $Url) { [Console]::Error.WriteLine('usage: hget <url>'); exit 2 }

# >>> hget
# Fetch a url. Writes to $OutStream when handed one and to stdout otherwise,
# which is what lets hexec pass a file to hash instead of spawning a process.
# Say, Die and Read-Line are declared inside, so a caller keeps its own.
# portable/build lifts everything between these two markers.
function Invoke-Hget {
    param([Parameter(Position = 0)][string]$Url,
          [Parameter(Position = 1)][System.IO.Stream]$OutStream)

    function Say($m) { [Console]::Error.WriteLine("hget: $m") }
    function Die($m) { Say $m; exit 1 }
    function Read-Line($s) {
        $b = [System.Collections.Generic.List[byte]]::new()
        while ($true) {
            $c = $s.ReadByte()
            if ($c -lt 0 -or $c -eq 10) { break }
            $b.Add([byte]$c)
        }
        ([System.Text.Encoding]::ASCII.GetString($b.ToArray())).TrimEnd("`r")
    }

    $out = if ($OutStream) { $OutStream } else { [Console]::OpenStandardOutput() }
    $hop = 0

    while ($true) {
        if ($Url -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $Url = "http://$Url" }
        try { $u = [Uri]$Url } catch { Die "cannot parse url: $Url" }
        if ($u.Scheme -ne 'http' -and $u.Scheme -ne 'https') { Die "unsupported scheme: $($u.Scheme)" }
        if (-not $u.Host) { Die "no host in url: $Url" }

        try { $client = [System.Net.Sockets.TcpClient]::new($u.Host, $u.Port) }
        catch { Die "cannot connect to $($u.Host):$($u.Port)" }
        $stream = $client.GetStream()
        if ($u.Scheme -eq 'https') {
            $ssl = [System.Net.Security.SslStream]::new($stream, $false)
            try { $ssl.AuthenticateAsClient($u.Host) } catch { Die "TLS failed for $($u.Host): $($_.Exception.InnerException.Message)" }
            $stream = $ssl
        }

        $req = "GET $($u.PathAndQuery) HTTP/1.0`r`nHost: $($u.Authority)`r`nUser-Agent: hget`r`nAccept: */*`r`n`r`n"
        $rb = [System.Text.Encoding]::ASCII.GetBytes($req)
        $stream.Write($rb, 0, $rb.Length); $stream.Flush()

        $status = ''
        while ($true) {
            $status = Read-Line $stream
            if ($status -eq '' -or $status -like 'HTTP/*') { break }
        }
        if ($status -notlike 'HTTP/*') { Die "no usable response from $($u.Host):$($u.Port)" }
        $parts = $status -split ' ', 3
        $code = $parts[1]; $reason = if ($parts.Count -gt 2) { $parts[2] } else { '' }

        $loc = ''; $chunked = $false
        while ($true) {
            $h = Read-Line $stream
            if ($h -eq '') { break }
            if ($h -match '^(?i)location:\s*(.+)$') { $loc = $Matches[1].Trim() }
            if ($h -match '^(?i)transfer-encoding:.*chunked') { $chunked = $true }
        }

        if ($loc -and $code -match '^30[12378]$') {
            $hop++
            if ($hop -gt 5) { Die 'more than 5 redirects' }
            if ($loc -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $Url = $loc }
            elseif ($loc.StartsWith('/')) { $Url = "$($u.Scheme)://$($u.Authority)$loc" }
            else { $Url = "$($u.Scheme)://$($u.Authority)$($u.AbsolutePath -replace '[^/]*$', '')$loc" }
            $client.Close()
            continue
        }
        break
    }

    if ($code -notmatch '^2') { Die "$Url returned $code $reason" }

    if (-not $chunked) {
        $stream.CopyTo($out)
    } else {
        while ($true) {
            $line = (Read-Line $stream) -split ';' | Select-Object -First 1
            if ($line -eq '') { continue }
            if ($line -notmatch '^[0-9A-Fa-f]+$') { Die "bad chunk header from $Url" }
            $n = [Convert]::ToInt32($line, 16)
            if ($n -eq 0) { break }
            $buf = [byte[]]::new($n); $got = 0
            while ($got -lt $n) {
                $r = $stream.Read($buf, $got, $n - $got)
                if ($r -le 0) { break }
                $got += $r
            }
            $out.Write($buf, 0, $got)
            Read-Line $stream | Out-Null
        }
    }
    $out.Flush()
    $client.Close()
}
# <<< hget

Invoke-Hget $Url
