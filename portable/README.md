# portable

One file that is a shell script on Unix and a PowerShell script on Windows.

```bash
./hget.ps1 https://example.com     # Unix: the shebang wins, the extension is ignored
.\hget.ps1 https://example.com     # Windows PowerShell
```

It is generated from `bash/hget` and `powershell/hget.ps1` — `make portable`
rebuilds it, so the implementations stay in one place. This README is about the
dispatch that lets both live in the same file.

### Why the name ends in `.ps1`

The extension is the last piece of the dispatch, and it is doing real work on
exactly one side.

**Windows** needs it. PowerShell will only run a script file called `.ps1` —
`.\hget` is treated as a native executable, and this file has no PE header, so
it fails. The extension is also what the shell's file association and *Run with
PowerShell* key off.

**Unix** ignores it entirely. The kernel dispatches on the `#!` line in the
first two bytes and never looks at the name, so `./hget.ps1` runs under bash
exactly as `./hget` did. Verified here, along with every pwsh invocation form:

| invocation | result |
|-----------|--------|
| `./hget.ps1` (shebang → bash) | body, redirect, 404 status all ✓ |
| `pwsh -NoProfile -File hget.ps1` | ✓ |
| `pwsh -NoProfile hget.ps1` | ✓ |

So `.ps1` costs nothing on the side that does not need it and is mandatory on
the side that does. If you would rather type `hget` on a Unix box, copy or
symlink it to that name — the shebang does not care.

Two Windows caveats I could not test from here, both documented behaviour rather
than anything specific to this file: running any `.ps1` is subject to the
execution policy, and a copy downloaded from the internet carries a
mark-of-the-web that `RemoteSigned` will block until it is unblocked.

---

## Why jart's APE trick does not transfer

An Actually Portable Executable works because the formats it satisfies are read
**positionally** by loaders that ignore everything they do not care about. The
DOS/PE loader reads the `MZ` header at offset 0, the ELF loader reads its magic
at offset 0, and a shell reads the file as text. Each one takes its slice and
never objects to the rest.

Two script languages give you no such slack. `sh` and PowerShell both consume
the whole file as text, and PowerShell parses **all** of it into an AST before
executing a single line — so a syntax error at the bottom stops the top from
running. There is no offset to hide in. Anything the other language must not see
has to be inside a comment or a string *of the language that is reading it*.

## The trick: `$true`

`$true` is a PowerShell automatic variable holding boolean true, which
interpolates into a string as `True`. To `sh` it is an unset variable that
expands to nothing. So one token reads as two different names:

```
"choose$true"   ->  sh: "choose"        pwsh: "chooseTrue"
```

No external command, no filesystem, nothing platform-specific — which is exactly
why it survives on Windows where `true` and `test` do not exist. Everything below
is built on that one difference.

---

## The four moving parts

### 1. The dispatch line

```sh
${true:-choose "$@"}
```

**sh** — `true` is unset, so `${var:-default}` yields the default: the words
`choose "$@"`. The expansion is unquoted, so it word-splits into a command and
its arguments, and bash calls the function `choose` with the script's arguments.

**PowerShell** — `${...}` delimits a *variable name*, not an expression. The
entire `true:-choose "$@"` is read as the name of one undefined variable, which
evaluates to `$null`. A statement whose value is `$null` emits nothing. No
output, no error, execution continues to the next line.

The arguments must sit **inside** the braces. Outside they are a PowerShell parse
error, and the naked form emits the function name onto stdout:

| dispatch | sh | PowerShell |
|----------|-----|------------|
| `"choose$true"` | calls `choose` ✓ | prints `chooseTrue` to **stdout** ✗ |
| `${true:-choose} "$@"` | calls with args ✓ | ParserError ✗ |
| `${true:-choose "$@"}` | calls with args ✓ | silent `$null` ✓ |

Stray stdout is not cosmetic here: `hget` writes the response body to stdout, so
one extra line corrupts every download.

### 2. The shell body hides in comments

PowerShell parses function bodies too, so it is not enough for `choose` to go
uncalled — its contents must still *parse* as PowerShell. Real shell does not:

```
say()   { printf 'hget: %s\n' "$*" >&2; }
        ~
        An expression was expected after '('.
```

So the shell implementation is not in the function. Every line of it carries a
`#|` prefix, which makes the whole program a run of PowerShell comments, and
`choose` reconstitutes it:

```sh
function choose
{
eval "$(sed -n 's/^#|//p' "$0")"
exit
}
```

That body *is* valid PowerShell syntax — a command, a string with a
subexpression, and `exit` — which is all that matters, because PowerShell never
calls it. `sh` runs it and gets the real program back.

The trailing `exit` is a guard. If the payload fails to eval, `choose` would
return and `sh` would carry on into the PowerShell section and print a wall of
syntax errors. `exit` makes the shell side terminate no matter what.

### 3. Ordering keeps the shell out of the PowerShell

The reverse problem — PowerShell code that `sh` must not parse — needs no trick,
only sequence. `sh` parses one command at a time and executes as it goes, so
anything after a command that exits is never read. The layout is therefore:

```
function choose { ... }          both parse this
#| ...shell implementation...    pwsh: comments      sh: comments, eval'd later
${true:-choose "$@"}             sh: runs, exits     pwsh: $null, continues
function choosetrue { ... }      sh: NEVER PARSED    pwsh: the real implementation
& "choose$true" @args            sh: NEVER PARSED    pwsh: calls it
```

Below the dispatch the file can be pure PowerShell, including `param()` blocks
and `[System.Net.Sockets.TcpClient]`, because no shell ever reads that far.

### 4. The PowerShell call

```powershell
& "choose$true" @args
```

`&` is the call operator, which invokes a command whose name is computed —
`chooseTrue` here. PowerShell's function lookup is case-insensitive, so it finds
`choosetrue`. `@args` splats the script's arguments into it.

---

## What runs it

Verified on macOS with the repo's own fixtures — binary body byte-exact,
chunked decoding, redirects, 404 exit status, clean stdout on error, usage exit
2, and live HTTPS:

| engine | result |
|--------|--------|
| `./hget` (shebang → bash) | 7/7 |
| `pwsh ./hget` | 7/7 |

So "portable across effectively everything" means bash and PowerShell, which
between them cover macOS, most Linux, the BSDs and Windows. The other three sets
remain the answer for zsh and busybox.

---

## Sharp edges

- Needs `sed`. A pure-shell extraction loop would not parse as PowerShell, and
  the extraction has to live inside a function body that does.
- Generated, not hand-written. Edit `bash/hget` or `powershell/hget.ps1` and run
  `make portable`; edits made directly to this file are lost.
- It is deliberately the least readable file in the repo. The other four sets
  exist to be read; this one exists to prove a point.
- Only `hget` is built this way. `hexec`, `hwait` and `hmirror` need a program
  called `hget` on `PATH` and do not care how it was made, so they run over this
  file unchanged.
