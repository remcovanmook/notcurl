# hget / hexec

An HTTP client written in bash, and a verifying replacement for `curl URL | bash`.

`hget` fetches a URL using bash's own `/dev/tcp` socket redirection. Over HTTPS
it shells out to `openssl s_client` for the handshake and nothing else. There is
no curl and no wget anywhere in the path.

`hexec` fetches a script, checks it against a SHA-256 you supply out of band, and
only then runs it.

---

## Why

`curl URL | bash` cannot be verified. The shell is already executing line 1 while
line 500 is still on the wire, so there is no point at which the content exists
as a thing you could hash, read, or reject. Cut the connection halfway through
and you have run half an installer.

It also assumes curl is there. On a Debian or Alpine base image it is not, which
is why so many install docs open with `apt-get install -y curl`. Bash, meanwhile,
has been able to open TCP sockets on its own since 1996.

`hexec` closes both gaps: it buffers to a file, verifies, and only then executes.
Nothing runs if the hash does not match.

---

## Requirements

- bash 3.2 or newer, built with `--enable-net-redirections` (the default on
  Debian, Ubuntu and macOS). Stock `/bin/bash` on macOS is 3.2 and works.
- `cat(1)`, the only external command on the HTTP path. Bash variables cannot
  hold NUL bytes, so the body has to be moved by something that can.
- `openssl(1)` — only for HTTPS.
- `sha256sum`, `shasum` or `openssl` — only for `hexec` verification.
- `python3` — only to run the test suite.

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

The body goes to stdout and everything else to stderr, so redirection and pipes
do what you expect. There are no flags. The scheme may be omitted and defaults
to `http`, and redirects are always followed, up to five. Any non-2xx status is
an error: it goes to stderr and exits 1, so a 404 page is never mistaken for
content. When TLS fails, the openssl error lines are printed and nothing else —
its chatter on a successful handshake is held aside and dropped.

## hexec

```
hexec [-n] <url> [<sha256-url>|<sha256>] [-- args...]

  -n   fetch and verify only; print the path and stop, so you can read it first
```

```bash
# verify against a checksum file published next to the script
hexec https://ex.io/install.sh https://ex.io/install.sh.sha256

# or against a hash pinned in your Dockerfile — the stronger form
hexec https://ex.io/install.sh 9f86d0818... -- --prefix=/opt

# read it before running it
hexec -n https://ex.io/install.sh https://ex.io/SHASUMS256.txt
```

The second argument is a bare SHA-256 if it is 64 hex characters, otherwise a
URL to a checksum file. Checksum files in `sha256sum` format are matched by
filename, so a project-wide `SHASUMS256.txt` listing many files works.

Arguments after `--` are passed to the fetched script. Its exit status becomes
`hexec`'s. Redirects are always followed.

With no checksum, `hexec` warns loudly and proceeds — no worse than
`curl | bash`, and it tells you which one you are doing.

---

## How it works

`hget` opens `/dev/tcp/$host/$port` on fd 5 and writes a request. For HTTPS the
same fd comes from a process substitution around `openssl s_client`, so
everything downstream of the connect is one code path.

The request is **HTTP/1.0 on purpose**. HTTP/1.0 forbids chunked
transfer-encoding, so the body on the wire is the body and there is no chunk
framing to decode in shell. Headers are consumed with `read`, then `cat <&5`
hands over the rest untouched — the body stays byte-exact, binary included.

`hexec` writes to a temp file rather than a pipe. That is the whole point: it is
what makes the content exist as something hashable before anything runs. It also
means a truncated download fails verification instead of half-executing. The
shebang is honoured by invoking the named interpreter directly, which works even
where `$TMPDIR` is mounted `noexec`.

---

## What this does not do

- **TLS still needs openssl.** On the same minimal images where curl is missing,
  the openssl binary often is too. The HTTP path is genuinely dependency-free;
  the HTTPS path is not.
- **A checksum is only as good as where you got it.** If the hash sits on the
  same host as the script, whoever can change one can change the other. This
  defends against corruption, truncation and a MITM with a valid certificate —
  not against a compromised origin. Pin the hash somewhere else.
- No POST, no request headers, no cookies, no proxies, no IPv6 literals, no
  HTTP/2, no compression. It fetches things.
- `openssl s_client` verifies against the system trust store. There is no
  certificate pinning.

---

## Tests

```bash
make test          # local only, spins up its own server on a free port
make check         # also runs the tests that reach the internet
BASH_UNDER_TEST=/opt/homebrew/bin/bash ./test.sh
```

36 tests, passing on bash 3.2 and 5.3.

---

## Licence

Apache 2.0. See [LICENSE](LICENSE).
