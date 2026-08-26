# ash

`hget`, `hexec`, `hwait` and `hmirror` in POSIX `sh` as busybox provides it —
Alpine's `/bin/sh`. Usage is in [../README.md](../README.md); this file is about
how the code works.

This is the most interesting set to read, because ash is the one shell here with
**no way to open a socket at all**. No `/dev/tcp`, no loadable module, no
sockets in the language. The socket has to come from another process, and that
single constraint reshapes the whole program.

It is also the set with the fewest moving parts: busybox `nc` and busybox
`ssl_client` are applets inside the same binary that provides `sh`, so on a
stock Alpine image there is nothing to install.

---

## About busybox wget

The same busybox that provides `sh` and `nc` will, in most builds, also provide
`wget`. This set does not pretend otherwise. `ssl_client`, which it uses for
TLS, exists in the first place as busybox wget's helper — the TLS here is
borrowed from the very downloader it does without.

### What wget actually replaces

| tool | does busybox wget give you this? |
|------|----------------------------------|
| `hget` | **Yes.** `wget -q -O -` is the same job. |
| `hwait` | Arguably. It is a poll loop around a downloader, and this set's `hwait` is literally that — six lines over `hget`. |
| `hexec` | **No.** Fetch, verify against a hash pinned out of band, run only on a match. |
| `hmirror` | **No.** Manifest parsing, per-line verification, subdirectory creation, `..` refusal, failure accounting. |

The two that have no equivalent are the two the repo exists for. A downloader
fetches; it does not refuse to run something whose hash you did not pin, and it
does not delete a file that failed its manifest line.

### hexec and hmirror do not need this hget

They shell out to a program named `hget` — sibling first, then `PATH`:

```sh
hget=${0%/*}/hget
[ -x "$hget" ] || hget=$(command -v hget) || die "cannot find hget(1)"
```

The contract is just: take a url, write the body to stdout, exit non-zero on
failure. Anything meeting it will do, so on an image that has `wget` and does
not have `nc -e`, the two tools that matter still work over a shim:

```sh
#!/bin/sh
exec busybox wget -q -O - "$1"
```

That is worth knowing because it means the two verifying tools are not coupled
to the socket code, and will keep working on a build this set's `hget` cannot
run on.

It is not an argument for leaving `hget` out. The whole ash set is 7.8 KB of
shell, `hget` being 2.6 KB of it: no build step, no dependency to resolve,
nothing to keep patched, and it works whether or not the image has `wget`.
Having it sit next to `wget` costs nothing worth measuring. The shim above is a
fallback for a busybox without `nc -e`, not a decision anyone needs to make in
advance.

### Why the socket code is still here

**Applets are a compile-time choice.** busybox is famously configurable: `wget`,
`nc`, `ssl_client` and every other applet is an independent build option, and
stripped or vendor builds routinely ship a different set than Alpine's does.
"busybox is installed" tells you nothing about which commands exist — `busybox
--list` does. That cuts both ways: a build without `nc -e` is one this set's
`hget` cannot run on either.

**Removing the downloader does not remove the ability to download.** If `wget`
is gone — deleted from an image, left out of the build, or blocked by an
execution policy — `sh` and `nc` are still there, and this file is what that
costs: one page of ordinary POSIX shell. That is the argument the repo's
[Why](../README.md#why) section makes, and ash is its clearest case, because
here the shell and the socket are the same executable. You cannot block one
without blocking the other.

---

## hget

### The shape

The other three sets stream: they hold a live socket on descriptor 5 and read
the response off it as it arrives. This one cannot. Instead it hands the socket
to `nc`, tells `nc` to pour the whole response into a temp file, waits for that
to finish, and only then parses the file.

```sh
exec 4>"$raw"
nc "$host" "$port" -e /bin/sh -c '...'      # fills $raw
exec 4>&-
exec 5<"$raw"                                # parse from the file
```

The cost is that a body is buffered on disk before a byte of it reaches stdout,
so a very large download needs the space. The compensation shows up in the chunk
decoder below.

### The nc trick, plaintext

```sh
nc "$host" "$port" -e /bin/sh -c 'cat "$H_REQ"; cat <&0 >&4 2>"$H_ERR"'
```

busybox `nc -e PROG` connects and then runs `PROG` with the **socket as both
stdin and stdout**. So inside that little `sh -c`:

- stdout is the socket, so `cat "$H_REQ"` sends the request;
- stdin is the socket, so `cat <&0` reads the response;
- `>&4` sends it somewhere that is not the socket.

Descriptor 4 is the escape hatch. The parent opened it onto `$raw` before
calling `nc`, and descriptors are inherited through `nc` into the child, so the
response has a way out even though 0 and 1 are both taken by the connection.

The command is in **single quotes**, so `$H_REQ` and `$H_ERR` are expanded by
the inner shell, not the outer one. That inner shell is a different process and
sees only exported variables — hence:

```sh
export H_REQ H_ERR H_HOST
```

Interpolating the values into the string instead would work until a path or a
hostname contained a quote.

### The nc trick, TLS

```sh
nc "$host" "$port" -e /bin/sh -c \
   'exec 3<&0; exec ssl_client -s 3 -n "$H_HOST" <"$H_REQ" >&4'
```

busybox `ssl_client` is the TLS half of busybox `wget`, exposed as its own
applet, and it is built to be driven exactly like this:

- `exec 3<&0` moves the socket off stdin, freeing stdin for something else;
- `-s 3` tells `ssl_client` the socket is on descriptor 3;
- `-n "$H_HOST"` is the SNI name, and the name to check the certificate against;
- `<"$H_REQ"` feeds it the plaintext to encrypt and send;
- `>&4` takes the decrypted response out to `$raw`.

The second `exec` replaces the shell with `ssl_client` rather than forking, so
nothing sits between it and the socket.

Note what is *not* here: an equivalent of openssl's `-verify_return_error`.
busybox validates internally and how strictly depends on the busybox build and
on the certificate bundle present in the image. If HTTPS correctness matters on
your image, test it — `hget https://expired.badssl.com/` should fail, and that
is exactly what `HGET_NET=1 ./test.sh` checks for the sets it can run.

### Finding the status line

```sh
while read -r proto code reason <&5; do
    case $proto in HTTP/*) break ;; esac
done
[ -n "$code" ] || die "no usable response from $host:$port"
```

The other sets read the first line and expect a status line. Here the raw file
may have picked up a blank line or a stray diagnostic on the way through `nc`,
so it scans until it finds something starting `HTTP/`. Hitting EOF instead
leaves `$code` empty, which is the error case.

### No `$'\r'`

```sh
reason=${reason%$(printf '\r')}
```

`$'\r'` is a bash/zsh/ksh extension. busybox ash has it only when compiled with
`ASH_BASH_COMPAT`, so this set does not use it. The price is a command
substitution — and therefore a subprocess — for every header line, which is the
kind of trade portable POSIX shell keeps making.

The same shortage shows up in the `Location` handling. There is no `<<<` in ash,
so instead of `read`-trimming the value:

```sh
loc=$(printf '%s' "${h#*:}" | tr -d ' ')
```

Deleting every space rather than trimming the ends is safe here because a URL
cannot contain a raw space.

Header names are matched with character classes — `[Ll]ocation:*` — because
there is no `nocasematch` and no `${(L)}`.

### The body, and why the chunk decoder is different

```sh
case $code in 2*) ;; *) die "$url returned $code $reason" ;; esac
[ -n "$chunked" ] || { cat <&5; exit; }
```

Non-2xx exits 1 so a 404 page is never mistaken for content, and `cat` moves the
body because no shell variable can hold a NUL byte.

```sh
[ $((0x$n)) -gt 0 ] || break
dd bs=$((0x$n)) count=1 <&5 2>/dev/null
```

Two differences from the bash set, both consequences of the temp file.

`0x$n` instead of `16#$n`: C-style hex literals are POSIX arithmetic, `base#`
notation is not.

`bs=N count=1` instead of `bs=1 count=N`: descriptor 5 here is a **regular
file**, where a `read()` of N bytes returns N unless it hits EOF. The other sets
read from a live socket, where a large read comes back short with whatever has
arrived so far, and so have to grind through the chunk one byte at a time. Doing
it the cheap way is the one thing this set gets for free by giving up streaming.

The `case $n in ''|*[!0-9A-Fa-f]*)` guard still runs first — arithmetic
expansion on unvalidated bytes off the network is a bad habit in any shell.

---

## hexec

Structurally the bash version, with the POSIX substitutions:

- `case $sum in *[!0-9A-Fa-f]*) isurl=1` instead of `${sum//[0-9A-Fa-f]/}`.
  POSIX has no pattern-substitution expansion.
- The awk uses `length($1)==64 && tolower($1)~/^[0-9a-f]+$/` rather than a
  `{64}` interval, which small awks have not always supported.
- `interp=sh` as the default when a script has no shebang, because Alpine has no
  bash to fall back to.

The core is unchanged and is the reason the tool exists:

```sh
read -r sb < "$tmp"; interp=sh
case $sb in '#!'*) interp=${sb#\#!} ;; esac
$interp "$tmp" "$@"
```

`$interp` unquoted so `#!/usr/bin/env sh` splits into a command and an argument;
the interpreter invoked *with the file as an argument*, so the download never
needs an execute bit and still runs when `/tmp` is mounted `noexec`.

---

## hwait

The only tool here that is structurally weaker than its bash counterpart. bash
and zsh probe with their own socket and stop after the status line; ash has no
socket and busybox `read` has no `-t`, so it just runs `hget` and throws the
result away:

```sh
"$hget" "$url" >/dev/null 2>&1 && exit 0
```

Which means each poll downloads the whole body of the health endpoint. For a
`/health` returning a line of JSON that is nothing; for anything larger, point
`hwait` at a cheaper URL.

`SECONDS` is a bash/zsh/ksh builtin, so the deadline is computed once with
`date +%s` and compared each round.

---

## hmirror

Line for line the bash version with `$((x + 1))` arithmetic instead of `((x++))`
and `tr 'A-F' 'a-f'` instead of a lowercase expansion. The manifest is read on
descriptor 3 so nothing the loop runs can consume it, with `/dev/stdin` by name
as the default. `entry=${entry#\*}` drops `sha256sum`'s binary-mode marker,
`${name%%\?*}` drops a query string, and `case /$name/ in */../*)` catches every
shape of `..` by wrapping the name in slashes before testing it.

Failures are counted rather than fatal, the partial file is removed on a failed
fetch or a mismatch, and the run exits 1 at the end.

---

## Sharp edges

- Needs busybox `nc` **with `-e`**. Some distributions ship OpenBSD netcat as
  `nc`, which dropped `-e` years ago, and a busybox can be built without the
  applet entirely — check with `busybox --list`. The tests check for it with
  `nc --help 2>&1 | grep -q -- '-e PROG'`.
- The whole response is buffered to a temp file before any of it is written out.
- No connect timeout, and `hwait` re-downloads the body on every poll.
- Certificate validation is whatever the image's busybox and CA bundle give you.
  Verify it rather than assuming it.
- No IPv6 literals; `host:port` is split on the last colon.
- The test harness itself cannot run on Alpine — no bash, no python3 — so this
  set is driven against fixtures served from another host.
