# hget / hexec / hwait / hmirror

A small family of HTTP tools written in bash, with no curl and no wget anywhere
in the path.

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

It also assumes curl is there, which on a minimal image it often is not — hence
all the install docs that open with `apt-get install -y curl`. Bash has been able
to open TCP sockets on its own since 1996, so wherever bash is the system shell
there is nothing to add.

Alpine is the honest exception, and worth stating plainly: it ships neither curl
nor bash, and busybox ash has no `/dev/tcp` at all, so `apk add bash` is exactly
the same friction as `apk add curl`. The argument here holds for Debian, Ubuntu
and macOS. It does not hold for Alpine.

`hexec` closes both gaps: it buffers to a file, verifies, and only then executes.
Nothing runs if the hash does not match.

The four tools are deliberately separate implementations rather than one library
with front-ends. Each is a single file that works on its own, which is the point
of a tool you might have to paste onto a box that has nothing. The cost is that
the socket and response code exists four times, and a fix to one is a fix to make
four times.

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
do what you expect. There are no flags. The scheme may be omitted and
defaults to `http`, and redirects are always followed, up to five. Any non-2xx status is an error: it goes to stderr and
exits 1, so a 404 page is never mistaken for content. When TLS fails, the openssl error lines are printed and nothing else —
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

## hwait

```
hwait <url> [timeout]
```

```bash
hwait http://127.0.0.1:8080/health 30 && ./run-the-tests
```

Polls once a second until the url answers 2xx, then exits 0. Exits 1 if the
timeout passes first, default 60 seconds. A refused connection is "not ready
yet" rather than an error, which is the whole point — it is for waiting on a
service that has not finished starting. Anything that is not 2xx, a 404
included, counts as not ready.

## hmirror

```
hmirror [baseurl] [file]
```

```bash
hmirror manifest.txt                          # or: hmirror < manifest.txt
hmirror https://ex.io/dist/ SHASUMS256.txt    # names resolved against the base
```

Reads lines of `<url>` or `<sha256>  <name>` from a file or stdin and fetches
each into the current directory, named after the last path element. Lines with a
hash are verified and the file is removed if it does not match. Blank lines and
`#` comments are skipped. Every line is attempted; failures are reported at the
end and exit 1.

Given a baseurl, entries that are not already absolute urls are resolved against
it, so a project's published manifest works untouched — including the leading `*`
that `sha256sum` writes for binary mode. An entry that *is* absolute ignores the
base. A trailing slash on the base is optional.

```
# what a published SHASUMS256.txt actually looks like
9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08  tool.tar.gz
232f4ee673fdd82c622a4d0c7543e49482f2eeb8b312460f3196fe0cdc251b37  *blob.bin
```

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

56 tests, passing on bash 3.2 and 5.3.

---

## Licence

Apache 2.0. See [LICENSE](LICENSE).
