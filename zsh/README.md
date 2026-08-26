# zsh

`hget`, `hexec`, `hwait` and `hmirror` in zsh 5.x. Usage is in
[../README.md](../README.md); this file is about how the code works.

The shape is the same as the `bash` set — open a socket on descriptor 5, write a
request, read the status line and headers a byte at a time, hand the rest to
`cat` — so what follows concentrates on the parts zsh does differently, and on
the three places where writing bash-shaped code in zsh would be a bug.

---

## Preamble

```zsh
emulate -L zsh
setopt nounset
zmodload zsh/net/tcp
```

`emulate -L zsh` resets the option set to zsh's own defaults for the duration of
the script. Without it, anything the user has `setopt`ed in `~/.zshrc` —
`shwordsplit`, `nullglob`, `extendedglob`, `ksharrays` — changes the meaning of
the code underneath it. The `-L` scopes the reset so it unwinds on return. Any
zsh script meant to run on someone else's machine should start this way.

`zmodload zsh/net/tcp` loads the module that provides `ztcp`. It ships in the
zsh distribution; there is nothing to install.

---

## hget

### Opening the socket

```zsh
ztcp $host $port || die "cannot connect to $host:$port"
exec 5<&$REPLY
ztcp -c $REPLY
```

`ztcp host port` connects and reports the descriptor it got in `$REPLY`. The
next two lines duplicate it onto 5 and close the module's original, so exactly
one descriptor refers to the socket. That matters: if both were left open, the
`exec 5<&-` in the redirect loop would not actually close the connection, and
the server would keep waiting for a client that has moved on.

Duplicating with `<&` looks read-only, and then `req >&5` writes to it. That is
fine — `<&` and `>&` describe the redirection, but the duplicate shares the
underlying open file description, and a socket's is read-write. So descriptor 5
behaves exactly like bash's `exec 5<>/dev/tcp/...`.

### TLS

Identical to the bash set: zsh has no TLS either, so `openssl s_client` does the
handshake and zsh keeps the plaintext side.

```zsh
exec 5< <(req | $ssl s_client -quiet -verify_return_error \
                 -servername $host -connect $host:$port 2>$err)
```

`-verify_return_error` is what makes a bad certificate a failure rather than a
line on stderr followed by the body; `-servername` sends SNI; `-quiet` keeps
openssl from tearing the connection down when the request pipe closes. openssl's
stderr is held in a temp file and only printed, filtered, if the response turns
out unusable.

### The three zsh traps

**`path` is not a variable you may use.** zsh ties the array `path` to `$PATH`.
Assigning a string to it rewrites the command search path for the rest of the
process, and the next `command -v` or `mktemp` fails in a way that looks like
anything but a naming mistake. Hence `upath` everywhere in this set where the
bash version says `path`. The same applies to `cdpath`, `fpath`, `manpath` and
friends.

**zsh does not word-split unquoted parameters.** This is the biggest single
difference from every other shell here. `$SHA` holding `shasum -a 256` would be
run as one command whose name is the whole string, spaces included. `${=SHA}`
opts back into splitting for that one expansion:

```zsh
got=$(${=SHA} < $tmp | grep -o '[0-9a-f]\{64\}' | head -1)
${=interp} $tmp "$@"
```

The upside of the default is that `$hget $url >$name` in `hmirror` is safe with
a filename containing spaces, without any quoting.

**Comparisons still need quoting on the right.** `[[ $want == "$got" ]]` — an
unquoted right operand in `[[ == ]]` is a *pattern*, in zsh as in bash. The left
side is fine; the right side is quoted throughout.

### zsh spellings

| zsh | what the other sets write |
|-----|---------------------------|
| `${(L)h}` | `shopt -s nocasematch`, or `tr A-F a-f` |
| `${0:h}` `${0:t}` | `${0%/*}` `${0##*/}` — history modifiers for head and tail |
| `[[ $timeout == <-> ]]` | `case $timeout in *[!0-9]*)` — `<->` globs any run of digits |
| `print -u2 -r -- "$*"` | `printf '%s\n' "$*" >&2` |
| `integer hop=0`, `(( ++hop <= 5 ))` | `hop=$((hop + 1)); [ $hop -le 5 ]` |

`print -u2` writes to descriptor 2, `-r` stops backslash interpretation, and
`--` ends the options so a message beginning with `-` is not mistaken for one.

### Everything else

Status line by word splitting, `${reason%$'\r'}` to strip the CR that `read`
leaves behind, the header loop ending on the blank line, `read -r loc <<<
"${h#*:}"` to trim whitespace off a `Location` value, redirects on 30[12378]
with a five-hop cap, `cat <&5` for the body because no shell variable can hold a
NUL byte, and chunk decoding with `dd bs=1 count=N` — one byte per read, because
descriptor 5 is a socket and a single large read would come back short and lose
the rest of the chunk. All of it is explained at more length in
[../bash/README.md](../bash/README.md); the code is line-for-line the same idea.

The `case $n in (''|*[!0-9A-Fa-f]*)` guard before `(( 16#$n ))` is there for the
same reason as in bash: zsh arithmetic evaluates its argument as an expression,
and unvalidated bytes off the network have no business being one.

The leading `(` in `case` patterns is zsh convention and changes nothing.

---

## hexec

Same structure as the bash version — fetch to a file, resolve the checksum,
compare, then run the interpreter named in the shebang with the file as an
argument so it needs no execute bit and works under `noexec`. The zsh-specific
bits are `${(L)sum}` instead of `tr`, `${0:h}` and `${url:t}` instead of the
`%`/`##` forms, `(( ${#sum} != 64 ))` for the length test, and `${=SHA}` /
`${=interp}` to get word splitting where it is actually wanted.

`[[ -n ${sum//[0-9A-Fa-f]/} ]]` works the same as in bash: delete every hex
character and see whether the argument was a bare digest or a url.

---

## hwait

Does not call `hget`. It repeats the parse and socket setup inline and reads
only the status line before closing, so polling a health endpoint does not
download its body once a second. `read -t 10` bounds a server that accepts the
connection and then goes quiet. `SECONDS` is a zsh builtin, so the loop needs no
`date` subprocess.

A refused connection is "not ready", not an error — that is the state you are
waiting out. So is any non-2xx.

---

## hmirror

The manifest is read on descriptor 3 so that nothing the loop runs can eat its
input, with `/dev/stdin` by name as the default so `hmirror < manifest` still
works. `read -r a b` gives one or two fields, which is how a `<hash>  <name>`
line is told from a bare url.

`entry=${entry#\*}` drops the `*` that `sha256sum` writes in binary mode;
`${name%%\?*}` drops a query string; and `case /$name/ in (*/../*)` catches
every shape of `..` with a single pattern by wrapping the name in slashes first.

On any failure the partial file is removed and the line counted, and the run
exits 1 at the end — so you are left with files that match their hashes, or
nothing.

---

## Sharp edges

- HTTPS needs the `openssl` binary. The `ash` and `powershell` sets do not.
- No connect timeout; `ztcp` blocks for as long as the OS TCP stack does.
- `dd bs=1` is a syscall per byte, so a large chunked body is slow.
- No IPv6 literals — `host:port` is split on the last colon.
- `emulate -L zsh` protects the script's own options, not the environment it
  inherits. `PATH` and `TMPDIR` still come from the caller.
