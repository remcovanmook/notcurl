#!/usr/bin/env bash
# 2026 Remco van Mook @rvmnl - Apache-2.0 - github.com/remcovanmook/notcurl
#
# test.sh - runs the same suite against every implementation set this host can
# run. Needs python3 for the test servers.
#
#   ./test.sh               every set available here
#   ./test.sh zsh bash      only those
#   HGET_NET=1 ./test.sh    plus tests that reach the public internet

set -u
cd "${0%/*}" || exit 1
ROOT=$PWD
SH=${BASH_UNDER_TEST:-/bin/bash}

pass=0 fail=0
SET=
ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n         %s\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
has()  { case $3 in *"$2"*) ok "$1" ;; *) bad "$1" "output lacks [$2]: $(printf '%s' "$3" | head -c 120)" ;; esac; }
hasnt(){ case $3 in *"$2"*) bad "$1" "output should not contain [$2]" ;; *) ok "$1" ;; esac; }

sha() {
    if   command -v sha256sum >/dev/null 2>&1; then sha256sum   < "$1" | cut -d' ' -f1
    elif command -v shasum    >/dev/null 2>&1; then shasum -a 256 < "$1" | cut -d' ' -f1
    else openssl dgst -sha256 < "$1" | sed 's/.*= *//'
    fi
}
freeport() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

# ---- fixtures ----------------------------------------------------------
DOC=$(mktemp -d "${TMPDIR:-/tmp}/hgettest.XXXXXX") || exit 1
trap 'kill $SRV $CHSRV 2>/dev/null; rm -rf "$DOC"; rm -f "${TMPDIR:-/tmp}"/hexec.*' EXIT INT TERM
mkdir -p "$DOC/sub" "$DOC/deep/er"
printf 'sub index\n' > "$DOC/sub/index.html"
printf 'deep file\n' > "$DOC/deep/er/f.txt"
printf '#!/usr/bin/env bash\necho "installer ran, args: $*"\n' > "$DOC/install.sh"
printf '#!/bin/sh\necho failing on purpose\nexit 42\n' > "$DOC/fail.sh"
head -c 4096 /dev/urandom > "$DOC/binary.bin"
GOOD=$(sha "$DOC/install.sh")
DEEP=$(sha "$DOC/deep/er/f.txt")
BIN=$(sha "$DOC/binary.bin")
BADH=$(printf 'd%.0s' $(seq 1 64))
printf '%s  install.sh\n' "$GOOD" > "$DOC/install.sh.sha256"
{ printf '%s  binary.bin\n' "$BIN"
  printf '%s  other.tar.gz\n' "$(printf 'a%.0s' $(seq 1 64))"
  printf '%s  install.sh\n' "$GOOD"; } > "$DOC/SHASUMS256.txt"

PORT=$(freeport); ( cd "$DOC" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 & SRV=$!
B="http://127.0.0.1:$PORT"
CHP=$(freeport)
python3 -c "
import http.server
BODY = open('$DOC/binary.bin','rb').read()
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def do_GET(s):
        s.send_response(200); s.send_header('Transfer-Encoding','chunked'); s.end_headers()
        for i in range(0, len(BODY), 997):
            c = BODY[i:i+997]; s.wfile.write(b'%x\r\n' % len(c) + c + b'\r\n')
        s.wfile.write(b'0\r\n\r\n')
    def log_message(s, *a): pass
http.server.HTTPServer(('127.0.0.1', $CHP), H).serve_forever()" >/dev/null 2>&1 & CHSRV=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do $SH "$ROOT/bash/hget" "$B/install.sh" >/dev/null 2>&1 && break; sleep 0.3; done

# ---- the suite ---------------------------------------------------------
suite() {
    local MD out rc saved LP2 LATE
    printf '\n%s\n' "$SET"

    out=$($HGET "$B/install.sh" 2>&1);                   has "$SET fetches a file"        "installer ran" "$out"
    out=$($HGET "127.0.0.1:$PORT/install.sh" 2>&1);      has "$SET bare host:port works"  "installer ran" "$out"
    $HGET "$B/binary.bin" >"$DOC/o.bin" 2>/dev/null
    is "$SET body is binary-clean"  "$BIN" "$(sha "$DOC/o.bin" 2>/dev/null)"
    $HGET "http://127.0.0.1:$CHP/x" >"$DOC/c.bin" 2>/dev/null
    is "$SET decodes chunked"       "$BIN" "$(sha "$DOC/c.bin" 2>/dev/null)"
    out=$($HGET "$B/nope" 2>/dev/null);                  is "$SET errors keep off stdout" "" "$out"
    out=$($HGET "$B/sub" 2>&1);                          has "$SET follows redirects"     "sub index" "$out"
    $HGET "$B/nope" >/dev/null 2>&1;                     is "$SET 404 exits 1"            "1" "$?"
    $HGET >/dev/null 2>&1;                               is "$SET no args exits 2"        "2" "$?"
    $HGET "ftp://example.com:21/" >/dev/null 2>&1;       is "$SET bad scheme exits 1"     "1" "$?"
    $HGET "http://127.0.0.1:1/" >/dev/null 2>&1;         is "$SET refused exits 1"        "1" "$?"

    out=$($HEXEC "$B/install.sh" "$B/install.sh.sha256" $SEP --prefix=/opt 2>&1)
    has "$SET hexec verifies"        "sha256 verified" "$out"
    has "$SET hexec passes args"     "args: --prefix=/opt" "$out"
    out=$($HEXEC "$B/install.sh" "$GOOD" 2>&1);          has "$SET hexec bare hash"       "sha256 verified" "$out"
    out=$($HEXEC "$B/install.sh" "$B/SHASUMS256.txt" 2>&1)
    has "$SET hexec matches by name" "sha256 verified" "$out"
    out=$($HEXEC "$B/install.sh" "$BADH" 2>&1); rc=$?
    has   "$SET hexec mismatch says so" "CHECKSUM MISMATCH" "$out"
    hasnt "$SET hexec mismatch runs nothing" "installer ran" "$out"
    is    "$SET hexec mismatch exits 1" "1" "$rc"
    out=$($HEXEC "$B/install.sh" 2>&1);                  has "$SET hexec warns unverified" "WARNING" "$out"
    out=$($HEXEC -n "$B/install.sh" "$GOOD" 2>&1); rc=$?
    hasnt "$SET hexec -n does not run" "installer ran" "$out"
    is    "$SET hexec -n exits 0"      "0" "$rc"
    saved=$(printf '%s\n' "$out" | tail -1)
    is    "$SET hexec -n leaves file"  "$GOOD" "$(sha "$saved" 2>/dev/null)"; rm -f "$saved"
    $HEXEC "$B/fail.sh" >/dev/null 2>&1;                 is "$SET hexec propagates status" "42" "$?"
    $HEXEC "$B/nope.sh" >/dev/null 2>&1;                 is "$SET hexec missing exits 1"   "1" "$?"

    $HWAIT "$B/" 5 >/dev/null 2>&1;                      is "$SET hwait healthy exits 0"   "0" "$?"
    $HWAIT "http://127.0.0.1:1/" 2 >/dev/null 2>&1;      is "$SET hwait times out"         "1" "$?"
    $HWAIT "$B/nope" 2 >/dev/null 2>&1;                  is "$SET hwait 404 not ready"     "1" "$?"
    $HWAIT >/dev/null 2>&1;                              is "$SET hwait no args exits 2"   "2" "$?"
    LP2=$(freeport)
    ( sleep 2; cd "$DOC" && exec python3 -m http.server "$LP2" --bind 127.0.0.1 ) >/dev/null 2>&1 & LATE=$!
    $HWAIT "http://127.0.0.1:$LP2/" 20 >/dev/null 2>&1;  is "$SET hwait waits for a late server" "0" "$?"
    kill $LATE 2>/dev/null

    MD=$DOC/mirror.$SET; mkdir -p "$MD"
    ( cd "$MD" && printf '%s\n' "$B/install.sh" | $HMIRROR ) >/dev/null 2>&1
    is "$SET hmirror stdin"          "$GOOD" "$(sha "$MD/install.sh" 2>/dev/null)"
    rm -f "$MD/install.sh"
    ( cd "$MD" && printf '%s  *install.sh\n' "$GOOD" | $HMIRROR "$B/" ) >/dev/null 2>&1
    is "$SET hmirror baseurl and *"  "$GOOD" "$(sha "$MD/install.sh" 2>/dev/null)"
    ( cd "$MD" && printf '%s  deep/er/f.txt\n' "$DEEP" | $HMIRROR "$B" ) >/dev/null 2>&1
    is "$SET hmirror keeps subdirs"  "$DEEP" "$(sha "$MD/deep/er/f.txt" 2>/dev/null)"
    ( cd "$MD" && printf '%s  install.sh\n' "$BADH" | $HMIRROR "$B/" ) >/dev/null 2>&1
    is "$SET hmirror mismatch exits 1" "1" "$?"
    is "$SET hmirror mismatch removes" "" "$(ls "$MD/install.sh" 2>/dev/null)"
    ( cd "$MD" && printf '../esc.txt\n' | $HMIRROR "$B/" ) >/dev/null 2>&1
    is "$SET hmirror refuses .."     "1" "$?"
    is "$SET hmirror nothing escaped" "" "$(ls "$DOC/esc.txt" 2>/dev/null)"
    ( cd "$MD" && printf '# comment\n\n%s\n' "$B/install.sh" | $HMIRROR ) >/dev/null 2>&1
    is "$SET hmirror skips comments" "0" "$?"

    if [ "${HGET_NET:-0}" = "1" ]; then
        out=$($HGET https://example.com 2>&1);           has "$SET https works" "Example Domain" "$out"
        $HGET https://expired.badssl.com/ >/dev/null 2>&1
        is "$SET expired cert refused" "1" "$?"
    fi
}

WANT=${*:-}
have() { case " $WANT " in *" $1 "*) return 0 ;; esac; [ -z "$WANT" ]; }

if have bash; then
    SET=bash SEP=-- HGET="$SH $ROOT/bash/hget" HEXEC="$SH $ROOT/bash/hexec" \
        HWAIT="$SH $ROOT/bash/hwait" HMIRROR="$SH $ROOT/bash/hmirror"; suite
fi
if have zsh && command -v zsh >/dev/null 2>&1; then
    SET=zsh SEP=-- HGET="zsh $ROOT/zsh/hget" HEXEC="zsh $ROOT/zsh/hexec" \
        HWAIT="zsh $ROOT/zsh/hwait" HMIRROR="zsh $ROOT/zsh/hmirror"; suite
fi
if have ash && command -v nc >/dev/null 2>&1 && nc --help 2>&1 | grep -q -- '-e PROG'; then
    SET=ash SEP=-- HGET="sh $ROOT/ash/hget" HEXEC="sh $ROOT/ash/hexec" \
        HWAIT="sh $ROOT/ash/hwait" HMIRROR="sh $ROOT/ash/hmirror"; suite
fi
if have powershell && command -v pwsh >/dev/null 2>&1; then
    SET=powershell SEP= HGET="pwsh -NoProfile -File $ROOT/powershell/hget.ps1" \
        HEXEC="pwsh -NoProfile -File $ROOT/powershell/hexec.ps1" \
        HWAIT="pwsh -NoProfile -File $ROOT/powershell/hwait.ps1" \
        HMIRROR="pwsh -NoProfile -File $ROOT/powershell/hmirror.ps1"; suite
fi

# ---- portable: the polyglot files, under both engines ------------------
portable_suite() {
    local out rc saved
    printf '\n%s\n' "$SET"
    $PHGET "$B/install.sh" >/dev/null 2>&1;             is "$SET hget fetches"          "0" "$?"
    $PHGET "$B/binary.bin" >"$DOC/p.bin" 2>/dev/null
    is "$SET hget body is binary-clean" "$BIN" "$(sha "$DOC/p.bin" 2>/dev/null)"
    $PHGET "http://127.0.0.1:$CHP/x" >"$DOC/pc.bin" 2>/dev/null
    is "$SET hget decodes chunked"      "$BIN" "$(sha "$DOC/pc.bin" 2>/dev/null)"
    out=$($PHGET "$B/sub" 2>&1);                        has "$SET hget follows redirects" "sub index" "$out"
    $PHGET "$B/nope" >/dev/null 2>&1;                   is "$SET hget 404 exits 1"      "1" "$?"
    out=$($PHEXEC "$B/install.sh" "$B/SHASUMS256.txt" $PSEP --prefix=/opt 2>&1)
    has "$SET hexec verifies"        "sha256 verified" "$out"
    has "$SET hexec passes args"     "args: --prefix=/opt" "$out"
    out=$($PHEXEC "$B/install.sh" "$BADH" 2>&1); rc=$?
    has   "$SET hexec mismatch says so"      "CHECKSUM MISMATCH" "$out"
    hasnt "$SET hexec mismatch runs nothing" "installer ran" "$out"
    is    "$SET hexec mismatch exits 1"      "1" "$rc"
    out=$($PHEXEC -n "$B/install.sh" "$GOOD" 2>&1)
    saved=$(printf '%s\n' "$out" | tail -1)
    is "$SET hexec -n leaves file"   "$GOOD" "$(sha "$saved" 2>/dev/null)"; rm -f "$saved"
    $PHEXEC "$B/fail.sh" >/dev/null 2>&1;               is "$SET hexec propagates status" "42" "$?"
}

if have portable && [ -f "$ROOT/portable/hget.ps1" ]; then
    SET="portable (bash)" PSEP=-- PHGET="$SH $ROOT/portable/hget.ps1" \
        PHEXEC="$SH $ROOT/portable/hexec.ps1"; portable_suite
fi
if have portable && command -v pwsh >/dev/null 2>&1 && [ -f "$ROOT/portable/hget.ps1" ]; then
    SET="portable (pwsh)" PSEP= PHGET="pwsh -NoProfile -File $ROOT/portable/hget.ps1" \
        PHEXEC="pwsh -NoProfile -File $ROOT/portable/hexec.ps1"; portable_suite
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
