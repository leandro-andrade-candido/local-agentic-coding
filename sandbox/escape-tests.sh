#!/usr/bin/env bash
# Escape tests for agent-box (E7).
#
# Usage: sandbox/escape-tests.sh
#
# On the host, the script:
#   1. creates a throwaway workdir and log dir, plus a canary OUTSIDE the mounts;
#   2. starts a fake HTTP server on 127.0.0.1 in place of llama-server (tests the
#      forwarder with SSE, concurrent connections, keep-alive and a large body,
#      without depending on the model) and a TCP listener on the docker0 bridge IP;
#   3. runs the battery INSIDE a container (run-in-box.sh ... -- escape-tests.sh --inside),
#      with a base skills profile and a folder of fake personal skills (read-only);
#   4. checks, on the host side, what the container must not have been able to touch;
#   5. if the real llama-server answers at LLM_BASE_URL, does GET /health from inside;
#   6. checks that the eval timeout takes the container down.
# Exit: 0 if everything passed; 1 if any test failed.
set -uo pipefail

pass=0 fail=0
ok() { printf 'PASS   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL   %s%s\n' "$1" "${2:+  [$2]}"; fail=$((fail + 1)); }
info() { printf 'INFO   %s\n' "$*"; }
short() { tr '\n' ' ' <<<"$1" | cut -c1-200; }
expect_ok() {
    local d="$1" out; shift
    if out="$("$@" 2>&1)"; then ok "$d"; else bad "$d" "$(short "$out")"; fi
}
expect_fail() {
    local d="$1" out; shift
    if out="$("$@" 2>&1)"; then bad "$d" "should have failed: $(short "$out")"; else ok "$d"; fi
}
expect_empty() { # <description> <value>
    if [ -z "$2" ]; then ok "$1"; else bad "$1" "$(short "$2")"; fi
}

# Forwarder client (runs inside the container against the fake server).
FWD_CLIENT='
import hashlib, http.client, json, os, sys, threading, time, urllib.parse
u = urllib.parse.urlsplit(os.environ["LLM_BASE_URL"])
conn = lambda: http.client.HTTPConnection(u.hostname, u.port, timeout=20)
t = sys.argv[1]
if t == "health":
    c = conn(); c.request("GET", "/health"); r = c.getresponse(); b = r.read()
    assert r.status == 200, (r.status, b[:200])
elif t == "keepalive":
    c = conn()
    for _ in range(3):
        c.request("GET", "/health"); r = c.getresponse(); r.read(); assert r.status == 200
elif t == "sse":
    c = conn(); t0 = time.monotonic(); c.request("GET", "/sse"); r = c.getresponse()
    assert r.status == 200, r.status
    times = []
    while True:
        line = r.fp.readline()
        if not line:
            break
        if line.startswith(b"data:"):
            times.append(round(time.monotonic() - t0, 2))
    # 5 events every 0.3 s: they must arrive spread out, not all at the end.
    assert len(times) == 5 and times[0] < 0.8 and times[-1] - times[0] >= 0.9, times
    print(times)
elif t == "concurrent":
    res = []
    def one():
        c = conn(); c.request("GET", "/slow"); r = c.getresponse(); r.read(); res.append(r.status)
    t0 = time.monotonic(); th = [threading.Thread(target=one) for _ in range(4)]
    [x.start() for x in th]; [x.join() for x in th]
    dt = time.monotonic() - t0
    assert res == [200] * 4 and dt < 2.8, (res, dt)
    print(f"{dt:.2f}s")
elif t == "bigbody":
    data = os.urandom(4 * 1024 * 1024)
    c = conn(); c.request("POST", "/echo", body=data)
    got = json.loads(c.getresponse().read())
    assert got == {"len": len(data), "sha256": hashlib.sha256(data).hexdigest()}, got
'

# ===================================================================================
# Inside the container
# ===================================================================================
inside() {
    local W="$ET_WORKDIR" L="$ET_LOGDIR" d f v out
    echo "== inside the container: $(id), mode $ET_MODE"

    if [ "$ET_MODE" = real ]; then
        local auth=()
        [ -z "${LLM_API_KEY:-}" ] || auth=(-H "Authorization: Bearer $LLM_API_KEY")
        expect_ok "real llama-server: GET /health through the forwarder" \
            curl -fsS --max-time 15 "${auth[@]}" "$LLM_BASE_URL/health"
        expect_ok "real llama-server: GET /v1/models through the forwarder" \
            curl -fsS --max-time 15 "${auth[@]}" "$LLM_BASE_URL/v1/models"
        return
    fi

    echo "-- identity and privileges"
    sf() { awk -v k="$1:" '$1 == k {print $2}' /proc/self/status; }
    expect_ok "not root (UID $(id -u))" test "$(id -u)" != 0
    expect_ok "same UID as the owner on the host ($ET_HOST_UID)" test "$(id -u)" = "$ET_HOST_UID"
    expect_ok "no effective capabilities (CapEff=0)" test "$(sf CapEff)" = 0000000000000000
    expect_ok "no permitted capabilities (CapPrm=0)" test "$(sf CapPrm)" = 0000000000000000
    expect_ok "empty bounding set (CapBnd=0)" test "$(sf CapBnd)" = 0000000000000000
    expect_ok "no-new-privileges on" test "$(sf NoNewPrivs)" = 1
    expect_ok "seccomp in filter mode" test "$(sf Seccomp)" = 2
    expect_fail "sudo absent" command -v sudo
    expect_fail "su to root does not work" timeout 5 su -c true root
    expect_empty "no setuid/setgid binary" "$(find / -xdev -type f -perm /6000 2>/dev/null | head -5)"
    expect_fail "cannot create a user namespace (unshare -U)" unshare -U true
    expect_fail "cannot become root in a user namespace (unshare -Ur)" unshare -Ur true

    echo "-- filesystem"
    try_write() { local x="$1/.agent-box-escape-$$"; (: >"$x") 2>/dev/null && rm -f "$x"; }
    for d in "$W" "$L" /tmp /var/tmp "$HOME"; do
        expect_ok "writes to $d" try_write "$d"
    done
    for d in / /etc /usr /usr/local/bin /opt/agents /var /root /run /run/agent-box \
             "$ET_AGENTS_DIR" "$ET_AGENTS_DIR/lib" "$ET_REPO_ROOT" "$ET_HOST_HOME" "$(dirname "$W")"; do
        expect_fail "does not write to $d" try_write "$d"
    done
    expect_fail "does not modify agents/lib/guard.py" sh -c ": >> '$ET_AGENTS_DIR/lib/guard.py'"
    expect_ok "reads agents/ (read-only)" test -r "$ET_AGENTS_DIR/lib/guard.py"
    out="$(python3 -I - "$W" "$L" /tmp /var/tmp "$HOME" <<'PY'
import os, stat, sys
allowed = [p.rstrip("/") for p in sys.argv[1:]] + ["/proc", "/sys", "/dev"]
under = lambda p: any(p == r or p.startswith(r + "/") for r in allowed)
found = []
for root, dirs, files in os.walk("/"):
    dirs[:] = [d for d in dirs if not under(os.path.join(root, d))]
    for p in [root] + [os.path.join(root, f) for f in files]:
        try:
            m = os.lstat(p).st_mode
        except OSError:
            continue
        if (stat.S_ISDIR(m) or stat.S_ISREG(m)) and os.access(p, os.W_OK):
            found.append(p)
    if len(found) >= 10:
        break
print("\n".join(found[:10]))
PY
)"
    expect_empty "nothing writable outside workdir, log dir, /tmp, /var/tmp and HOME" "$out"

    for f in .ssh .gnupg .gitconfig .git-credentials .config/gh .claude .claude.json .codex \
             .docker .aws .npmrc .netrc .bashrc .bash_history; do
        expect_fail "does not see host ~/$f" test -e "$ET_HOST_HOME/$f"
    done
    expect_empty "no file from the host HOME other than agents/ (and this script)" \
        "$(find "$ET_HOST_HOME" -not -type d -not -path "$ET_AGENTS_DIR/*" -not -path "$ET_SELF" 2>/dev/null | head -5)"
    expect_fail "does not see the canary outside the mounts" test -e "$ET_CANARY"
    expect_fail "does not see eval/ (hidden tests and solutions)" test -e "$ET_REPO_ROOT/eval"
    expect_fail "does not see the rest of the repository" test -e "$ET_REPO_ROOT/DIAGNOSIS-AND-PLAN.md"
    for f in /mnt/c /mnt/wsl /mnt/wslg /tmp/.X11-unix /run/user /dev/dxg /init \
             /var/run/docker.sock /run/docker.sock; do
        expect_fail "$f absent" test -e "$f"
    done
    expect_empty "no GPU (/dev/nvidia*)" "$(ls /dev/nvidia* 2>/dev/null)"
    v="$(find / \( -path /proc -o -path /sys \) -prune -o -type s -print 2>/dev/null)"
    if [ "$v" = /run/agent-box/llm.sock ]; then ok "the only visible unix socket is the forwarder's"
    else bad "the only visible unix socket is the forwarder's" "$(short "$v")"; fi
    expect_empty "no abstract unix socket (own network namespace)" \
        "$(awk 'NR > 1 && $8 ~ /^@/' /proc/net/unix)"

    echo "-- skills (read-only) and wrapper variables"
    expect_ok "AGENT_BOX=1 (set by the wrapper)" test "${AGENT_BOX:-}" = 1
    expect_ok "AGENT_SKILLS_DIRS=/opt/skills/base:/opt/skills/extra-1 (${AGENT_SKILLS_DIRS:-empty})" \
        test "${AGENT_SKILLS_DIRS:-}" = /opt/skills/base:/opt/skills/extra-1
    local sd
    IFS=: read -r -a sd <<<"${AGENT_SKILLS_DIRS:-}"
    for d in "${sd[@]}"; do
        f="$(find "$d" -name SKILL.md 2>/dev/null | head -n1)"
        expect_ok "reads $d" test -n "$f" -a -r "$f"
        expect_fail "does not write to $d" try_write "$d"
        expect_fail "does not write to $(dirname "${f:-$d/x}")" try_write "$(dirname "${f:-$d/x}")"
        expect_fail "does not modify ${f:-$d/SKILL.md}" sh -c ": >> '${f:-$d/SKILL.md}'"
    done

    echo "-- processes and environment"
    v="$(cat /proc/1/comm)"
    expect_ok "PID 1 is the container init ($v)" test "$v" = docker-init -o "$v" = tini
    v="$(find /proc -maxdepth 1 -name '[0-9]*' | wc -l)"
    expect_ok "sees only the container processes ($v)" test "$v" -lt 40
    expect_empty "no host process visible" \
        "$(cat /proc/[0-9]*/comm 2>/dev/null | grep -xE 'llama-server|dockerd|containerd|systemd|sshd|code|node.exe' | head -3)"
    expect_empty "no sensitive host variable" \
        "$(env | cut -d= -f1 | grep -xE 'GITHUB_TOKEN|GH_TOKEN|SSH_AUTH_SOCK|ANTHROPIC_API_KEY|OPENAI_API_KEY|ET_CANARY_SECRET|DOCKER_HOST|WSL_INTEROP|WSL_DISTRO_NAME|WSLENV|DISPLAY|WAYLAND_DISPLAY|DBUS_SESSION_BUS_ADDRESS|XDG_RUNTIME_DIR|AWS_[A-Z_]+')"

    echo "-- git and credentials"
    for v in docker ssh gh; do expect_fail "no $v command" command -v "$v"; done
    expect_fail "no ~/.git-credentials" test -e "$HOME/.git-credentials"
    expect_empty "no credential.helper" "$(git config --get-all credential.helper 2>/dev/null | grep -v '^$')"
    git -C "$W" remote add origin https://github.com/kayak/pypika.git 2>/dev/null
    git -C "$W" remote add viassh git@github.com:kayak/pypika.git 2>/dev/null
    expect_fail "git push over HTTPS fails" env GIT_TERMINAL_PROMPT=0 timeout 30 git -C "$W" push origin HEAD:refs/heads/escape-test
    expect_fail "git push over SSH fails" env GIT_TERMINAL_PROMPT=0 timeout 30 git -C "$W" push viassh HEAD:refs/heads/escape-test
    expect_fail "git ls-remote fails (no network)" env GIT_TERMINAL_PROMPT=0 timeout 30 git ls-remote https://github.com/kayak/pypika.git

    echo "-- network"
    v="$(ls /sys/class/net | tr '\n' ' ')"
    expect_ok "only the lo interface ($v)" test "$v" = "lo "
    expect_fail "DNS does not resolve example.com" python3 -I -c "import socket; socket.getaddrinfo('example.com', 443)"
    expect_fail "no internet: curl https://example.com" curl -sS --max-time 10 -o /dev/null https://example.com
    expect_fail "no internet by IP: 1.1.1.1:443" python3 -I -c "import socket; socket.create_connection(('1.1.1.1', 443), timeout=5)"
    for v in 127.0.0.1:8080 127.0.0.1:22 $ET_HOST_ADDRS; do
        expect_fail "cannot reach $v" python3 -I -c "import socket, sys; h, p = sys.argv[1].rsplit(':', 1); socket.create_connection((h, int(p)), timeout=3)" "$v"
    done
    expect_fail "cannot create a vsock socket (WSL channel to Windows)" \
        python3 -I -c "import socket; socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)"
    printf 'MZ\x90\x00\x03\x00' >/tmp/escape.exe && chmod +x /tmp/escape.exe
    expect_fail "does not run a Windows binary (WSL interop)" /tmp/escape.exe

    echo "-- llama-server forwarder (fake server on the host)"
    expect_ok "GET /health" python3 -I -c "$FWD_CLIENT" health
    expect_ok "3 requests on the same connection (keep-alive)" python3 -I -c "$FWD_CLIENT" keepalive
    if out="$(python3 -I -c "$FWD_CLIENT" sse 2>&1)"; then ok "SSE arrives event by event ($out s)"
    else bad "SSE arrives event by event" "$(short "$out")"; fi
    if out="$(python3 -I -c "$FWD_CLIENT" concurrent 2>&1)"; then ok "4 concurrent 1.5 s connections in $out"
    else bad "4 concurrent connections" "$(short "$out")"; fi
    expect_ok "4 MiB POST round trip" python3 -I -c "$FWD_CLIENT" bigbody

    echo "-- limits"
    expect_ok "memory limited ($ET_MEMORY_BYTES bytes)" test "$(cat /sys/fs/cgroup/memory.max)" = "$ET_MEMORY_BYTES"
    expect_ok "no swap" test "$(cat /sys/fs/cgroup/memory.swap.max 2>/dev/null)" = 0
    expect_ok "processes limited ($ET_PIDS)" test "$(cat /sys/fs/cgroup/pids.max)" = "$ET_PIDS"
    expect_ok "CPU limited ($ET_CPUS)" test "$(cat /sys/fs/cgroup/cpu.max)" = "$((ET_CPUS * 100000)) 100000"

    echo "-- image"
    expect_ok "python3.12 in /usr/bin (the eval .venv points to it)" test -x /usr/bin/python3.12
    for v in qwen-code:qwen pi:pi opencode:opencode claude-local:claude codex-local:codex; do
        f="/opt/agents/${v%%:*}/current/bin/${v#*:}"
        if out="$(HOME="$(mktemp -d)" timeout 60 "$f" --version 2>&1)"; then
            ok "${v%%:*} $(readlink "/opt/agents/${v%%:*}/current"): $(head -n1 <<<"$out")"
        else
            bad "${v%%:*} --version" "$(short "$out")"
        fi
    done
    info "node $(node --version), npm $(npm --version), $(python3 --version), $(uv --version)"
    info "$(git --version), $(rg --version | head -n1), fd $(fd --version | awk '{print $2}'), $(jq --version), TZ=$TZ"
    f=/opt/agents/codex-local/current/bin/codex
    if [ -x "$f" ]; then
        out="$(CODEX_HOME="$(mktemp -d)" timeout 30 "$f" sandbox -- true 2>&1)"
        info "Codex own sandbox (codex sandbox -- true): exit $?: $(short "$out")"
    fi
}

if [ "${1:-}" = --inside ]; then
    inside
    echo "== container: $pass passed, $fail failed"
    [ "$fail" = 0 ]
    exit
fi

# ===================================================================================
# On the host
# ===================================================================================
self="$(readlink -f "$0")"
# shellcheck source=lib.sh
source "$(dirname "$self")/lib.sh"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/agent-box-escape.XXXXXX")"
dummy_pid=""
finish() {
    [ -z "$dummy_pid" ] || kill "$dummy_pid" 2>/dev/null
    rm -rf "$scratch"
}
trap finish EXIT

mkdir -p "$scratch/repo" "$scratch/logs" "$scratch/outside" \
    "$scratch/skills-prefix/profiles/base/demo" "$scratch/skills-extra/personal"
printf -- '---\nname: demo\ndescription: fake skill for the test\n---\n' >"$scratch/skills-prefix/profiles/base/demo/SKILL.md"
printf -- '---\nname: personal\ndescription: fake skill for the test\n---\n' >"$scratch/skills-extra/personal/SKILL.md"
skills_sum() { find "$scratch/skills-prefix" "$scratch/skills-extra" -type f -exec sha256sum {} + | sort; }
skills_before="$(skills_sum)"
canary="$scratch/outside/canary.txt"
echo "canary $(date +%s%N) $RANDOM" >"$canary"
canary_sum="$(sha256sum <"$canary")"
git -C "$scratch/repo" init -q -b main
echo test >"$scratch/repo/README.md"
git -C "$scratch/repo" add README.md
git -C "$scratch/repo" -c user.name=t -c user.email=t@localhost commit -qm init

# Fake server in place of llama-server (127.0.0.1) and a TCP listener on the docker0
# bridge IP (the classic container -> host path, which must be closed).
bridge_ip="$(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
python3 -I - "$scratch" "${bridge_ip:-}" <<'PY' &
import hashlib, json, os, socket, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a):
        pass
    def reply(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path == "/health":
            self.reply(200, b'{"status":"ok","dummy":true}')
        elif self.path == "/slow":
            time.sleep(1.5)
            self.reply(200, b'{"slow":true}')
        elif self.path == "/sse":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            for i in range(5):
                self.wfile.write(f"data: {i}\n\n".encode())
                self.wfile.flush()
                time.sleep(0.3)
            self.close_connection = True
        else:
            self.reply(404, b"{}")
    def do_POST(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.reply(200, json.dumps({"len": len(data), "sha256": hashlib.sha256(data).hexdigest()}).encode())

scratch, bridge = sys.argv[1], sys.argv[2]
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
ports = [str(srv.server_address[1])]
if bridge:
    ls = socket.create_server((bridge, 0))
    ports.append(str(ls.getsockname()[1]))
    def accept():
        while True:
            c, _ = ls.accept()
            c.close()
    threading.Thread(target=accept, daemon=True).start()
with open(os.path.join(scratch, "ports.tmp"), "w") as f:
    f.write(" ".join(ports) + "\n")
os.rename(os.path.join(scratch, "ports.tmp"), os.path.join(scratch, "ports"))
srv.serve_forever()
PY
dummy_pid=$!
for _ in $(seq 50); do [ -s "$scratch/ports" ] && break; sleep 0.1; done
read -r dummy_port bridge_port <"$scratch/ports" || { echo "fake server did not start" >&2; exit 1; }

host_addrs=""
for ip in $(hostname -I 2>/dev/null); do
    case "$ip" in *:*) ;; *) host_addrs+=" $ip:$dummy_port $ip:9931 $ip:8080" ;; esac
done
[ -z "$bridge_ip" ] || host_addrs+=" $bridge_ip:${bridge_port:-9931} $bridge_ip:9931"
ns="$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null)"
[ -z "$ns" ] || host_addrs+=" $ns:53"

mem_bytes=$((3 * 1024 * 1024 * 1024))
before="$(docker ps -aq --filter "label=$BOX_LABEL" | wc -l)"

echo "== agent-box: escape tests (scratch $scratch, fake server :$dummy_port)"
GITHUB_TOKEN=canary ANTHROPIC_API_KEY=canary OPENAI_API_KEY=canary \
ET_CANARY_SECRET=canary SSH_AUTH_SOCK="$scratch/ssh-agent.sock" \
AGENT_BOX=0 AGENT_SKILLS_DIRS=/home SKILLS_PREFIX="$scratch/skills-prefix" BOX_SKILLS_DIRS='' \
LLM_BASE_URL="http://127.0.0.1:$dummy_port" BOX_MEMORY=3g BOX_PIDS=512 BOX_CPUS=2 \
"$SANDBOX_DIR/run-in-box.sh" \
    --rw "$scratch/repo" --rw "$scratch/logs" --ro "$self" --cwd "$scratch/repo" \
    --skills-dir "$scratch/skills-extra" \
    --env "ET_MODE=dummy" --env "ET_WORKDIR=$scratch/repo" --env "ET_LOGDIR=$scratch/logs" \
    --env "ET_HOST_HOME=$HOME" --env "ET_HOST_UID=$(id -u)" --env "ET_REPO_ROOT=$REPO_ROOT" \
    --env "ET_AGENTS_DIR=$AGENTS_DIR" --env "ET_SELF=$self" --env "ET_CANARY=$canary" --env "ET_HOST_ADDRS=$host_addrs" \
    --env "ET_MEMORY_BYTES=$mem_bytes" --env "ET_PIDS=512" --env "ET_CPUS=2" \
    -- bash "$self" --inside
inside_rc=$?

echo "-- on the host, after the container"
if [ "$(sha256sum <"$canary")" = "$canary_sum" ]; then ok "canary intact"; else bad "canary intact"; fi
expect_ok "nothing new outside the mounts" test "$(ls -A "$scratch/outside")" = canary.txt
expect_ok "skills intact" test "$(skills_sum)" = "$skills_before"
expect_empty "everything the container wrote belongs to the host user" \
    "$(find "$scratch/repo" "$scratch/logs" ! -uid "$(id -u)" 2>/dev/null | head -3)"
expect_ok "container removed" test "$(docker ps -aq --filter "label=$BOX_LABEL" | wc -l)" = "$before"
expect_empty "wrapper temporary state removed" \
    "$(find "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}" -maxdepth 1 -name 'agent-box.*' -newer "$canary" 2>/dev/null)"

real="${LLM_BASE_URL:-http://127.0.0.1:9931}"
auth=()
[ -z "${LLM_API_KEY:-}" ] || auth=(-H "Authorization: Bearer $LLM_API_KEY")
if curl -fsS --max-time 3 -o /dev/null "${auth[@]}" "${real%/}/health" 2>/dev/null; then
    echo "-- real llama-server at $real"
    LLM_BASE_URL="$real" "$SANDBOX_DIR/run-in-box.sh" --no-skills --rw "$scratch/repo" --ro "$self" \
        --env ET_MODE=real --env "ET_WORKDIR=$scratch/repo" --env "ET_LOGDIR=$scratch/logs" \
        -- bash "$self" --inside
    [ $? = 0 ] || inside_rc=1
else
    info "real llama-server did not answer at $real/health; test with the real server skipped"
fi

echo "-- item 7 (docs/verifications/E7.md): host does not follow agent symlinks"
# R1: output processing on the host (boxio + result.py), the way eval/run.sh does it
# after the agent, against an $out/agent-logs with planted symlinks pointing at
# host files. Proves arbitrary read and overwrite are BLOCKED.
reg="$scratch/item7"; mkdir -p "$reg"
vitima_r="$reg/victim-read.txt"; printf 'SECRET_HOST_READ\n' >"$vitima_r"
vitima_w="$reg/victim-write.sh"; printf 'original-bashrc-content\n' >"$vitima_w"
vitima_w_sum="$(sha256sum <"$vitima_w")"
out="$reg/out"; work="$reg/work"; mkdir -p "$out" "$work/agent-logs"
# (a) read: agent-metrics.json as a symlink -> host file (directly in agent-logs,
#     which the agent controls) and, redundantly, inside $out.
ln -s "$vitima_r" "$work/agent-logs/agent-metrics.json"
# (b) write: result.json and meta.json as symlinks -> host file (what a compromised
#     box_post/box_check would plant in $out).
ln -s "$vitima_w" "$out/result.json"
ln -s "$vitima_w" "$out/meta.json"
ln -s "$vitima_r" "$out/agent-logs"   # directory symlink, for the dir-symlink case
printf '{"checks":[],"status":"pass","pass":true}\n' >"$scratch/checks-src.json"
LIB="$REPO_ROOT/eval/lib"
# exactly the run.sh steps: log copy, symlink sweep, meta, result.
python3 -I "$LIB/boxio.py" copy-logs "$work/agent-logs" "$out/agent-logs" 2>/dev/null || true
python3 -I "$LIB/boxio.py" sanitize "$out" >/dev/null 2>&1 || true
cp "$scratch/checks-src.json" "$out/checks.json"
EVAL_LIB="$LIB" python3 -I - "$out/meta.json" <<'PY'
import os, sys; sys.path.insert(0, os.environ["EVAL_LIB"]); import boxio
boxio.write_json_atomic(sys.argv[1], {"run_id":"r","harness":"h","task_id":"S","setup_ok":True})
PY
python3 -I "$LIB/result.py" "$out" >/dev/null 2>&1 || true
expect_ok "write victim intact (no overwrite via symlink)" test "$(sha256sum <"$vitima_w")" = "$vitima_w_sum"
expect_ok "result.json is a regular file, not a symlink" sh -c '[ -f "'"$out"'/result.json" ] && [ ! -L "'"$out"'/result.json" ]'
expect_ok "meta.json is a regular file, not a symlink" sh -c '[ -f "'"$out"'/meta.json" ] && [ ! -L "'"$out"'/meta.json" ]'
if grep -q SECRET_HOST_READ "$out/result.json" 2>/dev/null; then
    bad "host content did NOT leak into result.json"
else ok "host content did NOT leak into result.json"; fi
expect_empty "no symlink left in \$out" "$(find "$out" -type l 2>/dev/null | head -3)"
expect_ok "read victim intact" test "$(cat "$vitima_r")" = SECRET_HOST_READ

# R2: the diff capture (box_post) runs with the workdir read-only and WITHOUT $out
# mounted; neither the fsmonitor/filter in the agent's .git/config nor any code reaches the host.
echo "-- item 7: diff capture (box_post) contained, with a malicious .git/config"
mrepo="$scratch/malrepo"; mkdir -p "$mrepo"
git -C "$mrepo" init -q -b main
printf 'hook() { : ; }\n' >"$mrepo/a.txt"
git -C "$mrepo" add a.txt
git -C "$mrepo" -c user.name=t -c user.email=t@localhost commit -qm base
base_ref="$(git -C "$mrepo" rev-parse HEAD)"
canary_box="$reg/CANARY-OF-THE-BOX"   # host path; not mounted in box_post
evil="$mrepo/.git/evil.sh"
cat >"$evil" <<EOF
#!/bin/sh
echo PWNED > "$canary_box"
true
EOF
chmod +x "$evil"
# Vector from item 6/7: fsmonitor runs on git add/status. The capture turns it off
# with -c core.fsmonitor=false (command-line precedence); and even if it ran, the
# workdir is read-only and $out is not mounted, so it would not reach the host.
git -C "$mrepo" config core.fsmonitor "$evil"
git -C "$mrepo" config core.hooksPath "$mrepo/.git/hooks-evil"
printf 'agent change\n' >>"$mrepo/a.txt"
post_tar="$reg/diff.tar"
LLM_BASE_URL="http://127.0.0.1:1" "$SANDBOX_DIR/run-in-box.sh" --no-llm --no-skills --ro "$mrepo" -- bash -c '
    set -e; wd="$1"; ref="$2"; base="$3"
    t="$(mktemp -d)"; trap "rm -rf \"$t\"" EXIT
    export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_INDEX_FILE="$t/index" GIT_OBJECT_DIRECTORY="$t/objects" GIT_ALTERNATE_OBJECT_DIRECTORIES="$wd/.git/objects"
    mkdir -p "$t/objects"
    gf="-c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.fileMode=false -c core.autocrlf=false -c core.attributesFile=/dev/null -c core.pager=cat"
    git -C "$wd" $gf add -A >/dev/null 2>&1 || true
    git -C "$wd" $gf diff --cached --binary --no-ext-diff --no-textconv "$ref" >"$t/agent.patch" 2>/dev/null || :
    git -C "$wd" $gf diff --cached --numstat --no-ext-diff "$ref" >"$t/numstat.txt" 2>/dev/null || :
    git -C "$wd" $gf rev-list --count "$base..HEAD" >"$t/commits.txt" 2>/dev/null || echo 0 >"$t/commits.txt"
    tar -C "$t" -cf - agent.patch numstat.txt commits.txt' \
    _ "$mrepo" "$base_ref" "$base_ref" >"$post_tar" 2>/dev/null || true
expect_fail "agent fsmonitor/filter did NOT write to the host" test -e "$canary_box"
ns="$(python3 -I "$LIB/boxio.py" extract-diff "$post_tar" "$reg" | tail -n +2)"
expect_ok "the diff was still captured despite the hostile .git/config" sh -c 'grep -q "agent change" "'"$reg"'/agent.patch"'

# R3: scoreboard integrity. box_check runs agent code (the hidden tests import its
# code), but $out is NOT mounted: the agent cannot forge the host's checks.json; the
# verdict comes from the grader (separate process, mounted read-only) via stdout.
echo "-- item 7: box_check cannot forge the verdict or modify the grader"
bc="$reg/boxcheck"; mkdir -p "$bc/wd" "$bc/out"
canary_bc="$bc/CANARY-BOXCHECK"
out_host="$bc/out"
"$SANDBOX_DIR/run-in-box.sh" --no-llm --no-skills --rw "$bc/wd" --ro "$REPO_ROOT/eval/lib" -- bash -c '
    set -u
    oh="$1"; grader="$2"; canary="$3"
    # (a) agent code tries to forge the host checks.json, plant a symlink and leave:
    mkdir -p "$oh" 2>/dev/null && echo FORGED_PASS >"$oh/checks.json" 2>/dev/null || true
    ln -s /etc/passwd "$oh/result.json" 2>/dev/null || true
    echo PWNED >"$canary" 2>/dev/null || true
    # (b) tries to modify the grader (mounted read-only) before it runs:
    echo "AGENT_WUZ_HERE=1" >>"$grader/check.py" 2>/dev/null || true
    # the grader (separate process) emits the REAL verdict in a tmpfs, via stdout:
    od="$(mktemp -d)"
    printf "%s\n" "{\"task_id\":\"X\",\"status\":\"fail\",\"pass\":false,\"checks\":[]}" >"$od/checks.json"
    : >"$od/check.log"; : >"$od/check.stdout"; : >"$od/check.stderr"; echo 1 >"$od/check.rc"
    tar -C "$od" -cf - checks.json check.log check.stdout check.stderr check.rc' \
    _ "$out_host" "$REPO_ROOT/eval/lib" "$canary_bc" 9>&- >"$bc/checks.tar" 2>/dev/null || true
python3 -I "$LIB/boxio.py" extract-checks "$bc/checks.tar" "$out_host" >/dev/null 2>&1 || true
expect_fail "box_check did not write the canary on the host" test -e "$canary_bc"
expect_ok "grader (check.py) intact (mounted read-only)" sh -c '! grep -q AGENT_WUZ_HERE "'"$REPO_ROOT"'/eval/lib/check.py"'
if grep -q FORGED_PASS "$out_host/checks.json" 2>/dev/null; then
    bad "checks.json forged by the agent was NOT persisted"
else ok "checks.json forged by the agent was NOT persisted"; fi
expect_ok "persisted verdict is the grader's (fail)" \
    sh -c 'python3 -I -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get(\"status\")==\"fail\" else 1)" "'"$out_host"'/checks.json"'
expect_ok "host result.json did not become a symlink" sh -c '[ ! -L "'"$out_host"'/result.json" ]'

echo "-- eval timeout takes the container down"
t0=$SECONDS
timeout -k 5 3 "$SANDBOX_DIR/run-in-box.sh" --no-llm --no-skills -- sleep 120 >/dev/null 2>&1
rc=$?
expect_ok "timeout returns 124 (exit $rc, $((SECONDS - t0)) s)" test "$rc" = 124
for _ in $(seq 20); do
    [ "$(docker ps -aq --filter "label=$BOX_LABEL" | wc -l)" = "$before" ] && break
    sleep 0.5
done
expect_ok "no container left after the timeout" \
    test "$(docker ps -aq --filter "label=$BOX_LABEL" | wc -l)" = "$before"

echo "== host: $pass passed, $fail failed; container: $([ "$inside_rc" = 0 ] && echo ok || echo FAILED)"
[ "$fail" = 0 ] && [ "$inside_rc" = 0 ]
