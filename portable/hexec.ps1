#!/usr/bin/env bash
# 2026 Remco van Mook @rvmnl - Apache-2.0 - github.com/remcovanmook/notcurl
# hexec - fetch, verify against a sha256, then run
#
# Built by "make portable" from bash/hget, bash/hexec, powershell/hget.ps1 and powershell/hexec.ps1. Do not edit here.
#
#   ./hexec.ps1 ARGS   (Unix: the shebang wins, the extension is ignored)
#   .\hexec.ps1 ARGS   (Windows PowerShell)

function run_bash_half
{
eval "$(sed -n '/^# SHELL$/,/^# ENDSHELL$/p' "$0")"
exit
}
${undef:-run_bash_half "$@"}

<#
# SHELL
# >>> hget
# Fetch a url to stdout. The body is a subshell, not a brace block, so the
# helpers, fd 5 and the exits all stay inside it: a caller gets an ordinary
# exit status back and keeps its own say/die. portable/build lifts everything
# between these two markers.
hget() (
    set -u
    USAGE='usage: hget <url>'
    say()   { printf 'hget: %s\n' "$*" >&2; }
    die()   { say "$@"; exit 1; }
    usage() { printf '%s\n' "$USAGE" >&2; exit 2; }
    req()   { printf 'GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: hget\r\nAccept: */*\r\n\r\n' "$path" "$hostport"; }

    parse() {
        local url=$1 rest
        rest=${url#*://} scheme=http
        [ "$rest" != "$url" ] && scheme=${url%%://*}
        hostport=${rest%%/*} path=/
        [ "${rest#*/}" != "$rest" ] && path=/${rest#*/}
        host=${hostport%%:*} port=${hostport##*:}
        [ "$port" = "$hostport" ] && port=
        case $scheme in http) port=${port:-80} ;; https) port=${port:-443} ;; *) die "unsupported scheme: $scheme" ;; esac
        [ -n "$host" ] || die "no host in url: $url"
    }

    get() {
        local proto h
        parse "$1"
        if [ "$scheme" = http ]; then
            exec 5<>"/dev/tcp/$host/$port" || die "cannot connect to $host:$port"
            req >&5
        else
            ssl=$(command -v openssl); [ -x "${ssl:-}" ] || die "https needs openssl(1)"
            err=${err:-$(mktemp "${TMPDIR:-/tmp}/hget.XXXXXX")} || die "cannot create temp file"
            exec 5< <(req | "$ssl" s_client -quiet -verify_return_error -servername "$host" -connect "$host:$port" 2>"$err")
        fi
        read -r proto code reason <&5 && [ -n "$code" ] || { grep -E 'verify error|:error:' "${err:-/dev/null}" >&2; die "no usable response from $host:$port"; }
        reason=${reason%$'\r'} loc= chunked=
        shopt -s nocasematch
        while IFS= read -r h <&5 && h=${h%$'\r'} && [ -n "$h" ]; do
            [[ $h == location:* ]] && read -r loc <<<"${h#*:}"
            [[ $h == transfer-encoding:*chunked* ]] && chunked=1
        done
        shopt -u nocasematch
    }

    [ $# -eq 1 ] || usage
    url=$1 err=
    trap '[ -n "$err" ] && rm -f "$err"' EXIT INT TERM

    while :; do
        get "$url"
        [ -n "$loc" ] && [[ $code == 30[12378] ]] || break
        [ $((hop = ${hop:-0} + 1)) -le 5 ] || die "more than 5 redirects"
        case $loc in
            *://*) url=$loc ;;
            /*)    url=$scheme://$hostport$loc ;;
            *)     url=$scheme://$hostport${path%/*}/$loc ;;
        esac
        exec 5<&-
    done

    [[ $code == 2* ]] || die "$url returned $code $reason"
    [ -n "$chunked" ] || { cat <&5; exit; }
    while IFS= read -r n <&5; do
        n=${n%$'\r'} n=${n%%;*}
        case $n in ''|*[!0-9A-Fa-f]*) die "bad chunk header from $url" ;; esac
        [ $((16#$n)) -gt 0 ] || break
        dd bs=1 count=$((16#$n)) <&5 2>/dev/null
        IFS= read -r n <&5
    done
)
# <<< hget

# 2026 Remco van Mook @rvmnl - Apache-2.0 - github.com/remcovanmook/notcurl
USAGE='usage: hexec [-n] <url> [<sha256-url>|<sha256>] [-- args...]
  -n   fetch and verify only, then print the path

A 64-hex second argument is the hash itself, anything else a url to fetch it from.
Args after -- go to the script, whose exit status is passed through.
With DEFAULT_URL set in this file, the url and checksum may be omitted.'

set -u
# --- ship a zero-argument installer by filling in these two lines ----------
DEFAULT_URL=            # place hardcoded default URL here
DEFAULT_SUM=            # place its sha256 here, or a url to a checksum file
# ---------------------------------------------------------------------------

dry=0 sum= url=
say()   { printf 'hexec: %s\n' "$*" >&2; }
die()   { say "$@"; exit 1; }
usage() { printf '%s\n' "$USAGE" >&2; exit 2; }

# Parsed by hand so the "--" survives to the lines below: with no url given,
# "hexec -- --prefix=/opt" passes --prefix=/opt to the script. getopts consumes it.
while [ $# -gt 0 ]; do
    case $1 in
        -n) dry=1; shift ;;
        --) break ;;
        -*) usage ;;
        *)  break ;;
    esac
done
if [ $# -gt 0 ] && [ "$1" != -- ]; then
    url=$1; shift
    [ $# -gt 0 ] && [ "$1" != -- ] && { sum=$1; shift; }
fi
[ "${1:-}" = -- ] && shift
[ -n "$url" ] || { url=$DEFAULT_URL; sum=$DEFAULT_SUM; }   # zero-argument run
[ -n "$url" ] || usage

if   [ -x "${0%/*}/hget" ];       then hget=${0%/*}/hget
elif type hget >/dev/null 2>&1;   then hget=hget   # a function, or one on PATH
else die "cannot find hget(1)"
fi
SHA=$(command -v sha256sum || command -v shasum || command -v openssl) || die "no sha256 tool"
case ${SHA##*/} in shasum) SHA="$SHA -a 256" ;; openssl) SHA="$SHA dgst -sha256" ;; esac

tmp=$(mktemp "${TMPDIR:-/tmp}/hexec.XXXXXX") || die "cannot create temp file"
trap 'rm -f "$tmp" "$tmp.sum"' EXIT INT TERM

"$hget" "$url" >"$tmp" || die "download failed: $url"
[ -s "$tmp" ] || die "downloaded an empty file: $url"

if [ -z "$sum" ]; then
    say "WARNING: no checksum given, running $url unverified"
else
    want=$(printf '%s' "$sum" | tr A-F a-f)
    if [ ${#sum} -ne 64 ] || [ -n "${sum//[0-9A-Fa-f]/}" ]; then
        "$hget" "$sum" >"$tmp.sum" || die "download failed: $sum"
        want=$(awk -v n="${url##*/}" 'tolower($1)~/^[0-9a-f]{64}$/{if(!h)h=$1; sub(/^[*]/,"",$2); sub(/.*\//,"",$2); if($2==n){h=$1;exit}} END{print tolower(h)}' "$tmp.sum")
        [ -n "$want" ] || die "no sha256 for ${url##*/} in $sum"
    fi
    got=$($SHA < "$tmp" | grep -o '[0-9a-f]\{64\}' | head -1)
    [ "$want" = "$got" ] || die "CHECKSUM MISMATCH, refusing to run
  expected $want
  got      $got"
    say "sha256 verified: $got"
fi

if [ $dry -eq 1 ]; then
    rm -f "$tmp.sum"; trap - EXIT INT TERM
    say "not executing (-n); script saved at:"; printf '%s\n' "$tmp"; exit 0
fi

read -r sb < "$tmp"; interp=bash
case $sb in '#!'*) interp=${sb#\#!} ;; esac
say "executing $url"
$interp "$tmp" "$@"
# ENDSHELL
#>

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

function Invoke-Hexec
{
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

# --- ship a zero-argument installer by filling in these two lines ----------
$DefaultUrl = ''        # place hardcoded default URL here
$DefaultSum = ''        # place its sha256 here, or a url to a checksum file
# ---------------------------------------------------------------------------

if (-not $Url) { $Url = $DefaultUrl; $Sum = $DefaultSum }
if (-not $Url) {
    [Console]::Error.WriteLine("usage: hexec [-n] <url> [<sha256-url>|<sha256>] [args...]`n  -n   fetch and verify only, then print the path`n`nWith `$DefaultUrl set in this file, both may be omitted.")
    exit 2
}
$inproc = $null -ne (Get-Command Invoke-Hget -ErrorAction SilentlyContinue)
$hget = Join-Path $PSScriptRoot 'hget.ps1'
if (-not $inproc -and -not (Test-Path $hget)) { Die 'cannot find hget.ps1' }
$pwshPath = (Get-Command pwsh).Source
if ($null -eq $Rest) { $Rest = @() }
while ($Rest.Count -gt 0 -and ($Rest[0] -eq '--' -or $Rest[0] -eq '')) { $Rest = @($Rest[1..($Rest.Count - 1)]) }

function Fetch($url, $out) {
    if ($inproc) {                     # hget was pulled in; no process needed
        $fs = [System.IO.File]::Create($out)
        try { Invoke-Hget -Url $url -OutStream $fs } finally { $fs.Close() }
        return 0
    }
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

}
Invoke-Hexec @args
