# bash

`hget`, `hexec`, `hwait` and `hmirror` written for bash 3.2 and later — 3.2 is
what macOS still ships as `/bin/bash`, so no `${var,,}`, no `mapfile`, no
associative arrays. Usage is in [../README.md](../README.md); this file is about
how the code works.

The only thing this set needs that a plain bash does not already have is
`openssl` for HTTPS. Plain HTTP needs nothing at all.

---

## hget

### Opening the socket

```bash
exec 5<>"/dev/tcp/$host/$port"
```

`/dev/tcp` is not a device file. Nothing of that name exists on disk on Linux or
macOS. It is a path bash recognises inside a redirection and turns into a
`socket()`/`connect()` pair, when bash was built with `--enable-net-redirections`.
To check a given bash:

```bash
bash -c 'exec 3<>/dev/tcp/127.0.0.1/80'
# "Connection refused"        -> the feature is there, nothing was listening
# "No such file or directory" -> built without it
```

`<>` opens read-write, so one descriptor both sends the request and receives the
response. Descriptor 5 rather than 0, 1 or 2 (already spoken for — the body has
to go to stdout) and rather than 3 or 4, which callers and `hmirror` use.

### TLS

bash cannot do TLS, so `openssl s_client` does it and bash keeps only the
plaintext ends of the pipe:

```bash
exec 5< <(req | "$ssl" s_client -quiet -verify_return_error \
                 -servername "$host" -connect "$host:$port" 2>"$err")
```

`<(...)` is process substitution: bash runs the command and substitutes a
filename (`/dev/fd/N`) that reads its stdout. So the request is written into
openssl's stdin, openssl encrypts it, and openssl's decrypted output becomes
fd 5. The descriptor is read-only in this branch, which is fine because a GET
has no body and the whole request was already written before the read starts.
That is the point of the arrangement: once `get()` returns, everything after it
reads fd 5 and has no idea which branch produced it.

Three flags matter:

- `-quiet` suppresses the session banner and stops openssl closing the
  connection when the request pipe hits EOF.
- `-verify_return_error` turns a failed certificate check into a closed stream
  and a non-zero exit. Without it openssl prints `verify error` to stderr and
  hands you the body anyway. This flag is the one doing the security work.
- `-servername` sends SNI, without which any host that serves more than one
  certificate on an address gives you the wrong one.

openssl chatters on stderr even on success, so it goes to a temp file and is
only shown — filtered for `verify error` and `:error:` — if the response turns
out to be unusable.

### The request

```
GET /path HTTP/1.0\r\n
Host: host:port\r\n
User-Agent: hget\r\n
Accept: */*\r\n
\r\n
```

HTTP/1.0 rather than 1.1 on purpose. 1.0 has no keep-alive, so the server closes
the connection when the body is done and EOF is the end-of-body marker — no
`Content-Length` to parse and count against. 1.0 also forbids chunked
transfer-encoding. Servers send it regardless (github.com does), so `hget` still
checks and de-frames, but the common case stays a straight copy.

### Status line and headers

```bash
read -r proto code reason <&5
```

Word splitting does the parsing: three fields out of `HTTP/1.1 301 Moved
Permanently`, with `reason` collecting the rest.

```bash
reason=${reason%$'\r'}
```

HTTP lines end CRLF and `read` only consumes the LF, so every line needs its CR
stripped. `$'\r'` is bash's C-style quoting.

```bash
while IFS= read -r h <&5 && h=${h%$'\r'} && [ -n "$h" ]; do
```

`IFS=` keeps leading and trailing spaces in header values. The assignment sits
in the middle of the `&&` chain purely as a "strip the CR here" step — an
assignment always succeeds, so it never affects the loop condition. The loop
ends on the empty line that separates headers from body.

That leaves fd 5 positioned at the first byte of the body, which is the whole
reason `read` is used here. `read` takes one byte at a time from the descriptor,
because it cannot know where a line ends without looking; anything that
block-buffers would pull kilobytes of body into a buffer that `cat` can never
see. Every set in this repo solves this the same way.

`shopt -s nocasematch` for the duration of the loop, because HTTP header names
are case-insensitive.

```bash
[[ $h == location:* ]] && read -r loc <<<"${h#*:}"
```

`${h#*:}` is everything after the first colon, which still has the space from
`Location: http://...`. Feeding it to `read` with the default `IFS` trims
leading and trailing whitespace, which is a builtin doing what would otherwise
be a `sed` subprocess.

### Redirects

```bash
[ -n "$loc" ] && [[ $code == 30[12378] ]] || break
```

301, 302, 303, 307 and 308 with a `Location`. 304 (not modified) and the
obsolete 305/306 are deliberately not in that set. Five hops maximum.

Resolution is the three ordinary cases — absolute, root-relative, and relative
to the current directory `${path%/*}/`. Then `exec 5<&-` closes the descriptor
before looping; without it each hop leaks a descriptor and, on HTTPS, leaves an
openssl child attached to a pipe nobody reads.

### The body

```bash
[[ $code == 2* ]] || die "$url returned $code $reason"
[ -n "$chunked" ] || { cat <&5; exit; }
```

Any non-2xx exits 1, so a 404 error page is never mistaken for content.

Then the shell hands the descriptor to `cat` and gets out of the way. This is
the only correct way to move a body: no shell variable can hold a NUL byte, so
`body=$(cat <&5)` silently corrupts anything binary. `cat` copies bytes.

### Chunked

Each chunk is a hex length line (possibly with a `;extension`), that many bytes,
then CRLF. A zero length ends the body.

```bash
case $n in ''|*[!0-9A-Fa-f]*) die "bad chunk header from $url" ;; esac
[ $((16#$n)) -gt 0 ] || break
dd bs=1 count=$((16#$n)) <&5 2>/dev/null
IFS= read -r n <&5
```

The `case` guard is not politeness. Bash arithmetic evaluates its argument as an
expression, and expansions inside an array subscript there are themselves
evaluated — feeding `$(( ))` unvalidated text off the network is a bad idea.
Restricting it to hex digits first removes the question.

`bs=1 count=N` and *not* `bs=N count=1`. Fd 5 is a socket or a pipe, where one
`read()` returns whatever has arrived so far, not necessarily all N bytes.
`bs=N count=1` would do a single short read and lose the rest of the chunk.
`bs=1 count=N` does N one-byte reads: slower, but exact, and it stops on the
last byte of the chunk so the following `read` lands on the CRLF that separates
it from the next length line. (The `ash` set gets to use `bs=N count=1`, because
it reads from a regular file — see [../ash/README.md](../ash/README.md).)

---

## hexec

The interesting part is the last three lines:

```bash
read -r sb < "$tmp"; interp=bash
case $sb in '#!'*) interp=${sb#\#!} ;; esac
$interp "$tmp" "$@"
```

`$interp` is deliberately unquoted so `#!/usr/bin/env bash` word-splits into a
command and its argument. Running the interpreter *with the file as an argument*
rather than executing the file means the download never needs an execute bit,
and it still works when `$TMPDIR` is mounted `noexec`, which is common on
hardened hosts and is exactly where `curl | bash` gets used as the workaround.

The honest caveat: an unquoted expansion word-splits and glob-expands. The
shebang comes from a file whose hash was just verified, so it is not
attacker-controlled at that point — but if you skip the checksum, it is.

The rest, in order:

- `getopts ':n'`, then `shift $((OPTIND - 1))`. The leading colon puts getopts
  in silent-error mode so `usage` prints instead of getopts' own message.
- Arguments: the url, then anything that is not `--` is the checksum, then an
  optional `--` and the script's own arguments.
- `hget=${0%/*}/hget` first, `command -v hget` second. A copied pair works from
  a directory that is not on `PATH`.
- Hash tool: `sha256sum` (GNU), `shasum` (macOS), or `openssl`, each with its
  argument fixup. It is always fed on **stdin**, never given a filename, so the
  output contains no path — then `grep -o '[0-9a-f]\{64\}' | head -1` pulls the
  digest out of all three formats — a trailing `-`, or a `(stdin)=` prefix that
  varies by openssl version — with one line.
- `[ -s "$tmp" ]` rejects an empty download before hashing. It would otherwise
  fail as a checksum mismatch, which is a confusing way to report a fetch that
  returned nothing.
- Bare hash or url? `[ ${#sum} -ne 64 ] || [ -n "${sum//[0-9A-Fa-f]/}" ]` —
  delete every hex character and see whether anything is left.
- The awk over a checksum file keeps the first 64-hex field as a fallback, then
  looks for a line whose second field — with `sha256sum`'s binary-mode `*` and
  any directory prefix stripped — equals the basename of the url. That is what
  makes a project-wide `SHASUMS256.txt` work.
- `-n` clears the trap after removing `$tmp.sum`, so the verified file survives
  for the caller to inspect.

---

## hwait

`hwait` does not call `hget`. It repeats the parse and the socket setup inline
and reads **only the status line**, then closes:

```bash
read -t 10 -r proto code reason <&5
exec 5<&-
[[ ${code:-} == 2* ]]
```

Downloading a health endpoint's body once a second for a minute is pointless, and
stopping at the status line makes each poll a single round trip. `read -t 10`
bounds the case where a server accepts the connection and then says nothing —
without it, one half-open connection hangs the poll forever.

`SECONDS` is a bash builtin counting seconds since it was last assigned, so the
loop costs no `date` subprocess per iteration.

A refused connection returns 1 from `probe` and counts as "not ready" rather
than an error, which is the case you are usually waiting on — the server has not
started listening yet. So does any non-2xx, a 404 included: a service that is up
enough to 404 is not up.

---

## hmirror

```bash
exec 3< "${1:-/dev/stdin}"
while read -r a b <&3; do
```

The manifest goes on descriptor 3, not stdin. A `while read` loop that runs
commands should never share its input with them — anything the child reads from
stdin would eat manifest lines. Reading `/dev/stdin` by name keeps
`hmirror < manifest` working anyway.

`read -r a b` splits each line into at most two fields, so `<hash>  <name>` and
a bare `<url>` are told apart by whether `$b` is empty.

The name is then cleaned up in the order the formats require:

```bash
entry=${entry#\*} entry=${entry#./}   # sha256sum binary mode writes *name
name=${name%%\?*}                     # drop a query string
case /$name/ in */../*) ... refuse
```

Wrapping the name in slashes before the `..` test means one pattern catches
`../x`, `x/..`, `x/../y` and a bare `..`.

The failure policy is the same on every path: count it, remove the partial file,
carry on to the next line, exit 1 at the end. A run leaves you either a file
that matches its hash or no file.

---

## Sharp edges

- Needs bash built with `--enable-net-redirections`. See the check above.
- No connect timeout. `/dev/tcp` blocks for however long the OS TCP stack takes
  on an unresponsive host; only `hwait` bounds anything, and only the read.
- `dd bs=1` is one syscall per byte. Fine for scripts and manifests, slow for a
  large chunked body.
- No IPv6 literals. The parser splits `host:port` on the last colon, and
  `/dev/tcp/[::1]/80` is not a thing.
- HTTPS needs the `openssl` binary, which is missing from plenty of the same
  minimal images that lack curl. The `ash` and `powershell` sets do not have
  this problem.
