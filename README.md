# hget / hexec / hwait / hmirror

Four HTTP tools, in four implementations, each using only what its environment
already has. No curl, no wget.

| set | shell | socket | TLS | tested on |
|-----|-------|--------|-----|-----------|
| `bash/` | bash 3.2+ | `/dev/tcp` | `openssl s_client` | macOS 26, bash 3.2 and 5.3 |
| `zsh/` | zsh 5.9 | `zmodload zsh/net/tcp` | `openssl s_client` | macOS 26 |
| `ash/` | POSIX sh | busybox `nc -e` | busybox `ssl_client` | Alpine 3.24 |
| `powershell/` | pwsh 7 | `TcpClient` | `SslStream` | pwsh 7.6 on macOS |

The sets share no code. Each tool is a single file that runs on its own, so one
can be copied to a host that has nothing else.

---

## Why

`curl URL | bash` cannot be verified. The shell executes line 1 while line 500 is
still on the wire, so the content never exists as something you could hash, read
or reject. A connection cut halfway through runs half an installer.

It also assumes curl is installed, which on a minimal image it often is not.
`hexec` fetches to a file, checks it against a SHA-256 you supply out of band,
and runs it only if the hash matches.

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
git clone https://github.com/remcovanmook/hget ~/src/hget
cd ~/src/hget
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

`hget` opens `/dev/tcp/$host/$port` on fd 5 and writes a request. For HTTPS the
same fd comes from a process substitution around `openssl s_client`, so everything
after the connect is one code path.

The request is HTTP/1.0, which forbids chunked transfer-encoding. Servers send it
anyway — github.com does — so the response headers are checked and the body
de-framed when they say so. Headers are consumed with `read`, then `cat <&5`
hands over the rest untouched, binary included.

`hexec` writes to a file rather than a pipe, which is what makes the content
hashable before anything runs, and makes a truncated download fail verification
instead of half-executing. It invokes the interpreter named in the shebang, which
also works where `$TMPDIR` is mounted `noexec`.

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
set. bash, zsh and powershell pass on macOS; ash passes on Alpine, where the
harness itself cannot run — Alpine has neither bash nor python3 — so that set is
driven against fixtures served from another host.

---

## Licence

Apache 2.0. See [LICENSE](LICENSE).
