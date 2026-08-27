# hget / hexec / hwait / hmirror

Four HTTP tools, in four implementations, each using only what its environment
already has. No curl, no wget. And one file that is a bash script and a
PowerShell script at the same time.

---

## One file, two languages

`portable/hget.ps1` fetches a URL on Linux, macOS, BSD **and** Windows. Not two
files shipped together — one file, which both interpreters read as their own.
`portable/hexec.ps1` does the same for verify-then-run, with `hget` built into
it: no second file, no separate program.

```bash
./hget.ps1 https://example.com     # Unix: the shebang wins, the extension is ignored
.\hget.ps1 https://example.com     # Windows PowerShell
```

The whole dispatch is one token:

```sh
${true:-choose "$@"}
```

To a **shell**, `true` is an unset variable, so `${var:-default}` yields the
default — and this calls the function `choose` with the script's arguments.

To **PowerShell**, `${...}` delimits a *variable name*. The entire
`true:-choose "$@"` is the name of one undefined variable, which evaluates to
`$null`, and a statement whose value is `$null` emits nothing. No output, no
error, execution continues.

One line, two unrelated readings, and no external command anywhere in it — which
is why it still works on Windows, where the `true` and `test` binaries that make
lesser polyglots look correct do not exist.

The shell implementation rides along as `#:` comments that PowerShell reads as
comments and the shell `eval`s back. The PowerShell implementation sits below the
dispatch, where no shell ever parses, because a shell exits at the dispatch and
never reads on. Both halves are verified: binary body byte-exact, chunked
decoding, redirects, 404 exit status, clean stdout on error, live HTTPS.

`make portable` generates both from the `bash` and `powershell` sets, so there is
no third copy to drift — and `make test` exercises them, so it cannot happen
quietly. In `hexec` the shell half embeds `bash/hget` verbatim and evals it in a
subshell, while the PowerShell half wraps `hget.ps1` in a function that writes to
a file stream instead of spawning a process. These are files, not a set — copy
them rather than `make install SET=portable`.

**[portable/README.md](portable/README.md) is the full walkthrough** — why APE's
positional-header trick does not transfer to two whole-file parsers, the table of
seams that look like they should work and don't, and why zsh and busybox ash
cannot run it.

---

## The four sets

| set | shell | socket | TLS | tested on |
|-----|-------|--------|-----|-----------|
| `bash/` | bash 3.2+ | `/dev/tcp` | `openssl s_client` | macOS 26, bash 3.2 and 5.3 |
| `zsh/` | zsh 5.9 | `zmodload zsh/net/tcp` | `openssl s_client` | macOS 26 |
| `ash/` | POSIX sh | busybox `nc -e` | busybox `ssl_client` | Alpine 3.24 |
| `powershell/` | pwsh 7 | `TcpClient` | `SslStream` | pwsh 7.6 on macOS |

The sets share no code. Each tool is a single file that runs on its own, so one
can be copied to a host that has nothing else. No tool is over 3.7 KB and no
complete set over 11 KB, so keeping one around alongside whatever else the image
has costs nothing worth measuring.

---

## Why

**A pipe into a shell cannot be verified.** `curl URL | bash` executes line 1
while line 500 is still on the wire, so the content never exists as something you
could hash, read or reject. A connection cut halfway through runs half an
installer. `hexec` fetches to a file, checks it against a SHA-256 you supply out
of band, and runs it only if the hash matches — so a truncated download fails
verification instead of half-executing.

**curl is often not there.** On a minimal image neither curl nor wget is
installed, and pulling one in to fetch a single file means a package manager, an
index refresh and a larger image than you started with. Each set here uses only
what its environment already ships.

**Removing curl is not an egress control.** Deleting curl and wget, or
allowlisting which binaries may execute, is regularly presented as a way to stop
a host making outbound HTTP requests. It is not one, and these four sets are the
demonstration. bash speaks TCP through `/dev/tcp`, a feature of the shell itself.
zsh speaks it through a module shipped in its own distribution. busybox speaks it
through the `nc` applet inside the single binary that *is* the userland — you
cannot remove it without removing `sh`. pwsh speaks it through .NET's
`TcpClient`, which is part of the runtime pwsh is built on. None of this is
exotic: it is one file of ordinary shell per tool, no compiler, no download, and
in the ash and powershell sets HTTPS works with nothing added either.

If a host must not reach the network, stop it at the network: no route, egress
filtering, or a proxy that authenticates. An inventory of which binaries are
present tells you very little — the shell you left behind is an HTTP client.

Each tool is a standalone file. The socket and response code is repeated in each
rather than shared, so any one of them can be copied somewhere on its own.

---

## Requirements

Common to every set: `cat` or an equivalent to move the body, because no shell
variable can hold a NUL byte; and `sha256sum`, `shasum` or `openssl` for the
verification in `hexec` and `hmirror`. `python3` runs the test suite only.

- **bash** needs bash built with `--enable-net-redirections`, the default on
  Debian, Ubuntu and macOS, and `openssl` for HTTPS.
- **zsh** needs the `zsh/net/tcp` module, which ships with zsh, and `openssl`
  for HTTPS.
- **ash** needs busybox `nc` with `-e` and busybox `ssl_client`, both in the
  Alpine base image. Nothing to install there.
- **powershell** needs pwsh 7. Sockets and TLS come from .NET, so nothing else.

Pick a set with `make install SET=zsh`.

---

## Install

```bash
git clone https://github.com/remcovanmook/notcurl ~/src/notcurl
cd ~/src/notcurl
sudo make install            # /usr/local/bin, override with PREFIX=
```

---

## hget

```
hget <url>
```

```bash
hget https://example.com
hget https://raw.githubusercontent.com/torvalds/linux/master/README > linux.README
hget 127.0.0.1:8080/health | jq .
```

The body goes to stdout, everything else to stderr. No flags. The scheme may be
omitted and defaults to `http`. Redirects are followed, up to five. Any non-2xx
status exits 1, so a 404 page is never mistaken for content. On a TLS failure the
openssl error lines are printed; its chatter on a successful handshake is not.

## hexec

```
hexec [-n] <url> [<sha256-url>|<sha256>] [-- args...]

  -n   fetch and verify only; print the path and stop
```

```bash
hexec https://ex.io/install.sh https://ex.io/install.sh.sha256
hexec https://ex.io/install.sh 9f86d0818... -- --prefix=/opt
hexec -n https://ex.io/install.sh https://ex.io/SHASUMS256.txt
```

The second argument is a bare SHA-256 if it is 64 hex characters, otherwise a URL
to a checksum file. Checksum files in `sha256sum` format are matched by filename,
so a project-wide `SHASUMS256.txt` works.

Arguments after `--` are passed to the script. Its exit status becomes `hexec`'s.
With no checksum, `hexec` warns on stderr and proceeds.

## hwait

```
hwait <url> [timeout]
```

```bash
hwait http://127.0.0.1:8080/health 30 && ./run-the-tests
```

Polls once a second until the url answers 2xx, then exits 0. Exits 1 if the
timeout passes first; the default is 60 seconds. A refused connection means not
ready, not an error. Anything other than 2xx, a 404 included, means not ready.

## hmirror

```
hmirror [baseurl] [file]
```

```bash
hmirror manifest.txt                          # or: hmirror < manifest.txt
hmirror https://ex.io/dist/ SHASUMS256.txt
```

Reads lines of `<url>` or `<sha256>  <name>` from a file or stdin and fetches each
into the current directory. Lines with a hash are verified, and the file is
removed if it does not match. Blank lines and `#` comments are skipped. Every line
is attempted; failures are counted and exit 1.

With a baseurl, entries that are not absolute urls are resolved against it, so a
published manifest works untouched, including the leading `*` that `sha256sum`
writes for binary mode. Directories in a name are created, so `linux/tool.tgz` and
`darwin/tool.tgz` do not collide. A name containing a `..` component is refused
and fails the run. An absolute entry ignores the base and is written flat. A
trailing slash on the base is optional.

```
9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08  tool.tar.gz
232f4ee673fdd82c622a4d0c7543e49482f2eeb8b312460f3196fe0cdc251b37  *blob.bin
```

---

## How it works

Every set does the same four things: open a socket, write a request, read the
status line and headers one byte at a time so the body is not buffered away, then
hand the rest of the stream over untouched.

The request is HTTP/1.0, which forbids chunked transfer-encoding and has no
keep-alive, so the server closing the connection is what marks the end of the
body — no `Content-Length` accounting needed. Servers send chunked anyway
(github.com does), so the headers are checked and the body de-framed when they
say so.

`hexec` writes to a file rather than a pipe, which is what makes the content
hashable before anything runs. It invokes the interpreter named in the shebang
rather than executing the file, so the download never needs an execute bit and
still works where `$TMPDIR` is mounted `noexec`.

How each set gets its socket, its TLS and its bytes differs enough to be worth
reading on its own. One README per set, written as a walk through the code:

| set | how it connects | walkthrough |
|-----|-----------------|-------------|
| bash | `/dev/tcp` redirection, openssl for TLS | [bash/README.md](bash/README.md) |
| zsh | `ztcp` from `zsh/net/tcp`, openssl for TLS | [zsh/README.md](zsh/README.md) |
| ash | busybox `nc -e`, busybox `ssl_client` | [ash/README.md](ash/README.md) |
| powershell | .NET `TcpClient` and `SslStream` | [powershell/README.md](powershell/README.md) |
| portable | bash **and** PowerShell in one file | [portable/README.md](portable/README.md) |

---

---

## Differences between the sets

The tools behave identically apart from one thing: PowerShell consumes a bare
`--` before the caller sees it, so `hexec` there takes the script's arguments
straight after the checksum instead of behind a separator.

```bash
hexec https://ex.io/i.sh <sha> -- --prefix=/opt     # bash, zsh, ash
pwsh hexec.ps1 https://ex.io/i.sh <sha> --prefix=/opt
```

---

## Limitations

- The bash and zsh sets need the openssl binary for HTTPS, which is missing from
  many of the same minimal images that lack curl. The ash and powershell sets do
  not: busybox `ssl_client` and .NET `SslStream` are already present where those
  run.
- The busybox that gives the ash set its socket normally gives you a `wget`
  applet too, which covers `hget` and most of `hwait`. It does not cover `hexec`
  or `hmirror`, and those two run over any program that takes a url and writes
  the body to stdout — `wget` included.
  [ash/README.md](ash/README.md#about-busybox-wget) has the long version.
- A checksum is only as good as its source. A hash served from the host that
  serves the script defends against corruption, truncation and a MITM holding a
  valid certificate — not against a compromised origin. Pin it elsewhere.
- `openssl s_client` verifies against the system trust store. No pinning.
- No POST, no request headers, no cookies, no proxies, no IPv6 literals, no
  HTTP/2, no compression.

---

## Tests

```bash
make test               # every set this host can run
./test.sh zsh           # just one
make check              # also the tests that reach the internet
BASH_UNDER_TEST=/opt/homebrew/bin/bash ./test.sh bash
```

The harness detects which sets the host can run and skips the rest. 36 tests per
set, plus 12 for each engine that can run the `portable` files — 132 on a host
with bash, zsh, pwsh and the polyglots. bash, zsh and powershell pass on macOS; ash passes on Alpine, where the
harness itself cannot run — Alpine has neither bash nor python3 — so that set is
driven against fixtures served from another host.

---

## Author and licence

2026 Remco van Mook — [@rvmnl](https://github.com/rvmnl).
Apache 2.0; see [LICENSE](LICENSE).

Every tool carries the same line under its shebang, because these files are
meant to be copied out on their own and a file with no provenance is a file you
should not run.
