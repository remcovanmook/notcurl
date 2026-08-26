#!/usr/bin/env bash
#
# test.sh - self-contained test suite for hget and hexec.
#
# Spins up a local HTTP server on a free port, runs every case against it and
# cleans up after itself. Needs python3 for the test server only.
#
#   ./test.sh              # local tests
#   HGET_NET=1 ./test.sh   # plus tests that reach the public internet
#   BASH_UNDER_TEST=/opt/homebrew/bin/bash ./test.sh

set -u
cd "${0%/*}" || exit 1

SH=${BASH_UNDER_TEST:-/bin/bash}
HGET="$SH ./hget"
HEXEC="$SH ./hexec"

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n         %s\n' "$1" "$2"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
has()  { case $3 in *"$2"*) ok "$1" ;; *) bad "$1" "output lacks [$2]: $3" ;; esac; }
hasnt(){ case $3 in *"$2"*) bad "$1" "output should not contain [$2]" ;; *) ok "$1" ;; esac; }

# ---- fixtures ----------------------------------------------------------
DOC=$(mktemp -d "${TMPDIR:-/tmp}/hgettest.XXXXXX") || exit 1
trap 'kill $SRV 2>/dev/null; rm -rf "$DOC"; rm -f "${TMPDIR:-/tmp}"/hexec.*' EXIT INT TERM

mkdir -p "$DOC/sub"
printf 'sub index\n' > "$DOC/sub/index.html"
cat > "$DOC/install.sh" <<'EOF'
#!/usr/bin/env bash
echo "installer ran, args: $*"
EOF
cat > "$DOC/py.sh" <<'EOF'
#!/usr/bin/env python3
import sys
print("python ran, args:", sys.argv[1:])
EOF
cat > "$DOC/fail.sh" <<'EOF'
#!/bin/sh
echo "failing on purpose"
exit 42
EOF
head -c 4096 /dev/urandom > "$DOC/binary.bin"

sha() {
    if   command -v sha256sum >/dev/null 2>&1; then sha256sum   < "$1" | cut -d' ' -f1
    elif command -v shasum    >/dev/null 2>&1; then shasum -a 256 < "$1" | cut -d' ' -f1
    else openssl dgst -sha256 < "$1" | sed 's/.*= *//'
    fi
}
GOOD=$(sha "$DOC/install.sh")
printf '%s  install.sh\n' "$GOOD" > "$DOC/install.sh.sha256"
# Target deliberately last, to prove we match on name and not on position.
{ printf '%s  py.sh\n' "$(sha "$DOC/py.sh")"
  printf '%s  other.tar.gz\n' "$(printf 'a%.0s' $(seq 1 64))"
  printf '%s  install.sh\n' "$GOOD"
} > "$DOC/SHASUMS256.txt"
printf 'deadbeef%s  install.sh\n' "$(printf '0%.0s' $(seq 1 56))" > "$DOC/bad.sha256"

# ---- server ------------------------------------------------------------
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()') || exit 1
( cd "$DOC" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
SRV=$!
B="http://127.0.0.1:$PORT"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    $HGET "$B/install.sh" >/dev/null 2>&1 && break
    sleep 0.3
done

echo "hget/hexec test suite  (shell: $($SH -c 'echo $BASH_VERSION'), port $PORT)"
echo
echo "hget"

out=$($HGET "$B/install.sh" 2>&1);            has "fetches a file"          "installer ran" "$out"
out=$($HGET "127.0.0.1:$PORT/install.sh" 2>&1); has "bare host:port/path works" "installer ran" "$out"
$HGET "$B/install.sh" >"$DOC/a.sh" 2>/dev/null
is "body goes to stdout"  "$GOOD" "$(sha "$DOC/a.sh")"
$HGET "$B/binary.bin" >"$DOC/out.bin" 2>/dev/null
is "body is binary-clean" "$(sha "$DOC/binary.bin")" "$(sha "$DOC/out.bin")"
out=$($HGET "$B/nope" 2>/dev/null); is "errors keep off stdout" "" "$out"
out=$($HGET "$B/sub" 2>&1);                   has "redirects are followed" "sub index" "$out"
# a server that redirects to itself, so the hop counter is the only thing stopping it
LP=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
python3 -c "
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s): s.send_response(302); s.send_header('Location','/loop'); s.end_headers()
    def log_message(*a): pass
http.server.HTTPServer(('127.0.0.1',$LP),H).serve_forever()" & LOOPSRV=$!
sleep 0.5
$HGET "http://127.0.0.1:$LP/loop" >/dev/null 2>&1; is "redirect loop is bounded" "1" "$?"
kill $LOOPSRV 2>/dev/null
$HGET "$B/nope" >/dev/null 2>&1;              is "404 exits 1"          "1" "$?"
$HGET >/dev/null 2>&1;                        is "no args exits 2"      "2" "$?"
$HGET a b >/dev/null 2>&1;                    is "two args exits 2"     "2" "$?"
$HGET "ftp://example.com/" >/dev/null 2>&1;   is "bad scheme exits 1"   "1" "$?"
$HGET "ftp://example.com:21/" >/dev/null 2>&1; is "bad scheme with a port too" "1" "$?"
$HGET "http://" >/dev/null 2>&1;              is "no host exits 1"      "1" "$?"
$HGET "$B/install.sh" 2>/dev/null | head -1 >/dev/null
is "SIGPIPE stays quiet" "" "$($HGET "$B/install.sh" 2>&1 >/dev/null | head -1 | grep -i 'cannot write')"
out=$(env PATH=/nonexistent $SH ./hget https://example.com 2>&1); rc=$?
has "https without openssl says so" "needs openssl" "$out"
is  "https without openssl exits 1" "1" "$rc"
# one-shot server that answers with a blank line where the status line belongs
JP=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
python3 -c "
import socket
s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$JP));s.listen(1);c,_=s.accept();c.recv(4096);c.sendall(b'\\r\\n\\r\\n');c.close()" &
sleep 0.5
$HGET "http://127.0.0.1:$JP/" >/dev/null 2>&1; is "malformed response exits 1" "1" "$?"

echo
echo "hexec"

out=$($HEXEC "$B/install.sh" "$B/install.sh.sha256" -- --prefix=/opt 2>&1)
has "checksum url verifies"        "sha256 verified" "$out"
has "args pass through after --"   "args: --prefix=/opt" "$out"
out=$($HEXEC "$B/install.sh" "$GOOD" 2>&1)
has "bare hash verifies"           "sha256 verified" "$out"
out=$($HEXEC "$B/install.sh" "$B/SHASUMS256.txt" 2>&1)
has "multi-entry file, matches name" "sha256 verified" "$out"
out=$($HEXEC "$B/install.sh" "$B/bad.sha256" 2>&1); rc=$?
has   "mismatch is reported"       "CHECKSUM MISMATCH" "$out"
hasnt "mismatch runs nothing"      "installer ran" "$out"
is    "mismatch exits 1"           "1" "$rc"
out=$($HEXEC "$B/install.sh" 2>&1)
has "no checksum warns"            "WARNING" "$out"
has "no checksum still runs"       "installer ran" "$out"
out=$($HEXEC -n "$B/install.sh" "$GOOD" 2>&1); rc=$?
hasnt "-n does not execute"        "installer ran" "$out"
is    "-n exits 0"                 "0" "$rc"
saved=$(printf '%s\n' "$out" | tail -1)
is    "-n leaves the script"       "$GOOD" "$(sha "$saved" 2>/dev/null)"
rm -f "$saved"
$HEXEC "$B/fail.sh" >/dev/null 2>&1;          is "exit status propagates" "42" "$?"
out=$($HEXEC "$B/py.sh" -- a b 2>&1);         has "honours the shebang"   "python ran, args: ['a', 'b']" "$out"
$HEXEC "$B/nope.sh" >/dev/null 2>&1;          is "missing script exits 1" "1" "$?"
$HEXEC "$B/install.sh" "$B/nope.sha256" >/dev/null 2>&1
is "missing checksum exits 1" "1" "$?"
$HEXEC "$B/install.sh" "not-a-valid-hash!" >/dev/null 2>&1
is "garbage checksum exits 1" "1" "$?"
is "temp files cleaned up" "0" "$(ls "${TMPDIR:-/tmp}"/hexec.* 2>/dev/null | wc -l | tr -d ' ')"

if [ "${HGET_NET:-0}" = "1" ]; then
    echo
    echo "network"
    out=$($HGET https://example.com 2>&1);    has "https works"        "Example Domain" "$out"
    out=$($HGET https://expired.badssl.com/ 2>&1); rc=$?
    is  "expired cert is refused"   "1" "$rc"
    has "and says why, with no -v"  "certificate has expired" "$out"
    out=$($HGET http://github.com 2>&1);      has "http->https redirect" "<!DOCTYPE html>" "$out"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
