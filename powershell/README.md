# powershell

`hget.ps1`, `hexec.ps1`, `hwait.ps1` and `hmirror.ps1` for pwsh 7. Usage is in
[../README.md](../README.md); this file is about how the code works.

This is the set with the fewest requirements. Sockets and TLS both come from
.NET, which is the runtime pwsh is built on, so on any host that can run pwsh
these work with nothing else installed — no openssl, no busybox, no compiler.

There is an obvious question: pwsh has `Invoke-WebRequest`. It is not used here
for the same reason the bash set does not use curl. The premise of the repo is a
client assembled from primitives, and `Invoke-WebRequest` is a complete HTTP
stack — using it would answer a different question. `TcpClient` is this set's
`/dev/tcp`.

---

## hget

### Connecting

```powershell
$client = [System.Net.Sockets.TcpClient]::new($u.Host, $u.Port)
$stream = $client.GetStream()
if ($u.Scheme -eq 'https') {
    $ssl = [System.Net.Security.SslStream]::new($stream, $false)
    $ssl.AuthenticateAsClient($u.Host)
    $stream = $ssl
}
```

`SslStream` wraps the socket's stream and the variable is reassigned over it, so
everything downstream reads `$stream` without caring which it got. Same
convergence the shell sets get by putting both branches on descriptor 5.

`AuthenticateAsClient($u.Host)` does the handshake, sends that name as SNI, and
validates the chain and the hostname against the OS trust store. Note that this
is the *default* — a bad certificate throws, and the `try`/`catch` turns it into
a clean error. Compare openssl, where verification failure prints a warning and
hands you the body anyway unless you remember `-verify_return_error`. This set
is safe by default; the other two have to ask.

### Parsing the URL

The shell sets do string surgery with `${}`. Here `[Uri]` does it, and gives
back `.Host`, `.Port` (already defaulted per scheme), `.PathAndQuery` and
`.Authority`.

The one thing it will not do is a bare `host:port/path` — `[Uri]"127.0.0.1:8080/x"`
reads `127.0.0.1` as the scheme. So the scheme is checked for first and `http://`
prefixed when it is missing, matching the other sets:

```powershell
if ($Url -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $Url = "http://$Url" }
```

### Read-Line, and why it reads one byte at a time

```powershell
function Read-Line($s) {
    $b = [System.Collections.Generic.List[byte]]::new()
    while ($true) {
        $c = $s.ReadByte()
        if ($c -lt 0 -or $c -eq 10) { break }
        $b.Add([byte]$c)
    }
    ([System.Text.Encoding]::ASCII.GetString($b.ToArray())).TrimEnd("`r")
}
```

This is the most important function in the file, and the obvious alternative is
a trap. `[StreamReader]::ReadLine()` **buffers**: to find a line ending it pulls
a whole block off the socket, and every byte past the line ending is then inside
the reader's private buffer. The moment you stop using the reader and start
reading the body off the raw stream, those first few kilobytes are gone — and
the body is silently truncated at the front.

Reading a byte at a time is the only way to stop exactly on the header/body
boundary. Every set in this repo does the same thing; `read` in bash, zsh and
ash reads a byte at a time for exactly this reason.

The final `TrimEnd` strips the CR, since only the LF was consumed.

### The request, and HTTP/1.0

```powershell
$req = "GET $($u.PathAndQuery) HTTP/1.0`r`nHost: $($u.Authority)`r`n..."
```

1.0 rather than 1.1: no keep-alive, so the server closing the connection marks
the end of the body and there is no `Content-Length` to count against; and
chunked encoding is not allowed. Servers send chunked anyway, so it is still
handled.

### The body

```powershell
$out = [Console]::OpenStandardOutput()
...
$stream.CopyTo($out)
```

`OpenStandardOutput()` is the raw stdout stream, deliberately bypassing the
PowerShell pipeline. `Write-Output` on bytes would format them as objects — one
decimal number per line — and `Write-Host` is worse. `CopyTo` moves bytes, so a
binary body arrives byte for byte. This is the counterpart to `cat <&5`.

### Chunked

```powershell
$buf = [byte[]]::new($n); $got = 0
while ($got -lt $n) {
    $r = $stream.Read($buf, $got, $n - $got)
    if ($r -le 0) { break }
    $got += $r
}
$out.Write($buf, 0, $got)
Read-Line $stream | Out-Null
```

A single `Read` on a network stream returns what has arrived, not what you asked
for, so it loops until the chunk is complete. This is the same hazard bash avoids
with `dd bs=1 count=N`; .NET just lets you write the loop directly, which is why
this set can allocate the chunk and read into it rather than grinding a byte at
a time. The trailing `Read-Line` eats the CRLF between chunks.

---

## hexec

### It runs hget as a program

```powershell
$psi.FileName = $pwshPath
foreach ($a in @('-NoProfile', '-File', $hget, $url)) { $psi.ArgumentList.Add($a) }
$psi.RedirectStandardOutput = $true
$p = [System.Diagnostics.Process]::Start($psi)
$fs = [System.IO.File]::Create($out)
$p.StandardOutput.BaseStream.CopyTo($fs)
```

Dot-sourcing `hget.ps1` would be cheaper, but then `hget` stops being a program
with an exit status and a stdout stream, and this set stops matching the others.
So it spawns one.

Two details in there matter:

- `.BaseStream.CopyTo($fs)` and not `$p.StandardOutput.ReadToEnd()`. `ReadToEnd`
  decodes to a string, which mangles any byte that is not valid text. The base
  stream is bytes.
- `$psi.ArgumentList.Add(...)` rather than assembling an `Arguments` string.
  .NET quotes each element, so a url containing a space or a quote cannot turn
  itself into extra arguments.

`-NoProfile` on every child, so a user profile cannot change behaviour or add
startup time to a poll loop.

### The `--` difference

This is the one place the sets genuinely behave differently. PowerShell's
parameter binder consumes a bare `--` before the script ever sees it, so
`hexec.ps1` takes the script's arguments straight after the checksum:

```bash
hexec https://ex.io/i.sh <sha> -- --prefix=/opt     # bash, zsh, ash
pwsh hexec.ps1 https://ex.io/i.sh <sha> --prefix=/opt
```

`[Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest` collects the
tail, and the loop that strips leading `--` and empty entries from `$Rest` is
there for people who type the separator out of habit.

### Running the script

```powershell
if ($first -and $first.StartsWith('#!')) {
    $parts = @($first.Substring(2).Trim() -split '\s+')
    $iargs = @(); if ($parts.Count -gt 1) { $iargs = $parts[1..($parts.Count - 1)] }
    $a1 = $iargs + @($tmp) + $Rest
    & $parts[0] @a1
} else {
    $a2 = @('-NoProfile', '-File', $tmp) + $Rest
    & $pwshPath @a2
}
```

Same principle as the shell sets: read the shebang, split it, and invoke the
interpreter *with the temp file as an argument*. The download never needs an
execute bit, and it works when the temp directory is mounted `noexec`. A file
with no shebang is handed to pwsh, since a `.ps1` will not have one.

`@a1` is splatting — the array becomes separate arguments — and `exit
$LASTEXITCODE` passes the script's status through.

### Cleanup

```powershell
$tmp = [System.IO.Path]::GetTempFileName()
try { ... if ($n) { ...; $tmp = $null; exit 0 } }
finally { if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp } }
```

`finally` is this set's `trap ... EXIT`, and setting `$tmp` to `$null` on the
`-n` path is how that branch opts out of the cleanup so the verified file
survives for the caller — the same job as `trap - EXIT` in the shells.

`Get-FileHash -Algorithm SHA256` replaces the three-way `sha256sum`/`shasum`/
`openssl` detection the shell sets need. It is built in.

---

## hwait

Spawns a full `pwsh` running `hget.ps1` on each poll and discards the output.
That makes it the heaviest `hwait` of the four — process startup per second, and
the body of the health endpoint downloaded each time — but at a one-second
interval it is still comfortably idle. `bash` and `zsh` avoid both costs by
probing with their own socket and stopping after the status line; there is no
in-process equivalent here without duplicating `hget` inside `hwait`.

Both output streams are drained (`CopyTo([Stream]::Null)` and `ReadToEnd()`)
before `WaitForExit()`. Skipping that risks the child blocking on a full pipe
while the parent waits for it to exit.

---

## hmirror

The same manifest format and the same failure policy: every line attempted,
partial files removed, `exit 1` if anything failed.

```powershell
$f = @($t -split '\s+' | Where-Object { $_ -ne '' })
if ($f.Count -gt 1) { $want = $f[0].ToLower(); $entry = $f[1] } else { ... }
$entry = ($entry -replace '^\*', '') -replace '^\./', ''
if ("/$name/" -match '/\.\./') { Say "refusing .. in path: $entry"; $bad++; continue }
```

`-split '\s+'` with the empty filter is the regex spelling of `read -r a b`; the
`^\*` strip handles `sha256sum` binary mode; and the traversal check wraps the
name in slashes first so one pattern catches `../x`, `x/..` and `x/../y`.

One structural difference from the shells: the manifest is read entirely up
front (`ReadAllLines`, or `ReadToEnd` on stdin) rather than streamed line by
line. Manifests are small, and reading it all first removes any question of the
loop's input being shared with the processes it spawns — which is what the shell
sets use descriptor 3 to prevent.

---

## Sharp edges

- `hwait` costs a process per poll and downloads the body each time.
- No connect timeout — `TcpClient`'s constructor blocks for as long as the OS
  TCP stack does.
- No IPv6 literals, matching the other sets.
- `$ErrorActionPreference = 'Stop'` is set in every file so a non-terminating
  error does not let the script carry on past a failure. Worth keeping if you
  edit these.
- A `.ps1` is not directly executable the way a shell script is; `make install`
  installs the four files and they are run as `pwsh -File hget.ps1 ...` or
  through a wrapper.
