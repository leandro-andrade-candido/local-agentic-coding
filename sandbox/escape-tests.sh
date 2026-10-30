#!/usr/bin/env bash
# Testes de fuga do agent-box (E7).
#
# Uso: sandbox/escape-tests.sh
#
# No host, o script:
#   1. cria um workdir e um log-dir descartáveis e um canário FORA das montagens;
#   2. sobe um servidor HTTP falso em 127.0.0.1 no lugar do llama-server (testa o
#      encaminhador com SSE, conexões simultâneas, keep-alive e corpo grande, sem
#      depender do modelo) e um ouvinte TCP no IP da ponte docker0;
#   3. roda a bateria DENTRO de um container (run-in-box.sh ... -- escape-tests.sh --inside),
#      com um perfil base de skills e uma pasta de skills pessoais falsos (só leitura);
#   4. confere do lado do host o que o container não podia tocar;
#   5. se o llama-server real responder em LLM_BASE_URL, faz GET /health por dentro;
#   6. confere que o timeout do eval derruba o container.
# Saída: 0 se tudo passou; 1 se algum teste falhou.
set -uo pipefail

pass=0 fail=0
ok() { printf 'PASSA  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FALHA  %s%s\n' "$1" "${2:+  [$2]}"; fail=$((fail + 1)); }
info() { printf 'INFO   %s\n' "$*"; }
short() { tr '\n' ' ' <<<"$1" | cut -c1-200; }
expect_ok() {
    local d="$1" out; shift
    if out="$("$@" 2>&1)"; then ok "$d"; else bad "$d" "$(short "$out")"; fi
}
expect_fail() {
    local d="$1" out; shift
    if out="$("$@" 2>&1)"; then bad "$d" "deveria falhar: $(short "$out")"; else ok "$d"; fi
}
expect_empty() { # <descrição> <valor>
    if [ -z "$2" ]; then ok "$1"; else bad "$1" "$(short "$2")"; fi
}

# Cliente do encaminhador (roda dentro do container contra o servidor falso).
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
    # 5 eventos a cada 0,3 s: precisam chegar espaçados, não todos no fim.
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
# Dentro do container
# ===================================================================================
inside() {
    local W="$ET_WORKDIR" L="$ET_LOGDIR" d f v out
    echo "== dentro do container: $(id), modo $ET_MODE"

    if [ "$ET_MODE" = real ]; then
        local auth=()
        [ -z "${LLM_API_KEY:-}" ] || auth=(-H "Authorization: Bearer $LLM_API_KEY")
        expect_ok "llama-server real: GET /health pelo encaminhador" \
            curl -fsS --max-time 15 "${auth[@]}" "$LLM_BASE_URL/health"
        expect_ok "llama-server real: GET /v1/models pelo encaminhador" \
            curl -fsS --max-time 15 "${auth[@]}" "$LLM_BASE_URL/v1/models"
        return
    fi

    echo "-- identidade e privilégios"
    sf() { awk -v k="$1:" '$1 == k {print $2}' /proc/self/status; }
    expect_ok "não é root (UID $(id -u))" test "$(id -u)" != 0
    expect_ok "mesmo UID do dono no host ($ET_HOST_UID)" test "$(id -u)" = "$ET_HOST_UID"
    expect_ok "sem capabilities efetivas (CapEff=0)" test "$(sf CapEff)" = 0000000000000000
    expect_ok "sem capabilities permitidas (CapPrm=0)" test "$(sf CapPrm)" = 0000000000000000
    expect_ok "conjunto limite vazio (CapBnd=0)" test "$(sf CapBnd)" = 0000000000000000
    expect_ok "no-new-privileges ligado" test "$(sf NoNewPrivs)" = 1
    expect_ok "seccomp em modo filtro" test "$(sf Seccomp)" = 2
    expect_fail "sudo ausente" command -v sudo
    expect_fail "su para root não funciona" timeout 5 su -c true root
    expect_empty "nenhum binário setuid/setgid" "$(find / -xdev -type f -perm /6000 2>/dev/null | head -5)"
    expect_fail "não cria user namespace (unshare -U)" unshare -U true
    expect_fail "não vira root num user namespace (unshare -Ur)" unshare -Ur true

    echo "-- sistema de arquivos"
    try_write() { local x="$1/.agent-box-escape-$$"; (: >"$x") 2>/dev/null && rm -f "$x"; }
    for d in "$W" "$L" /tmp /var/tmp "$HOME"; do
        expect_ok "grava em $d" try_write "$d"
    done
    for d in / /etc /usr /usr/local/bin /opt/agents /var /root /run /run/agent-box \
             "$ET_AGENTS_DIR" "$ET_AGENTS_DIR/lib" "$ET_REPO_ROOT" "$ET_HOST_HOME" "$(dirname "$W")"; do
        expect_fail "não grava em $d" try_write "$d"
    done
    expect_fail "não altera agents/lib/guard.py" sh -c ": >> '$ET_AGENTS_DIR/lib/guard.py'"
    expect_ok "lê agents/ (só leitura)" test -r "$ET_AGENTS_DIR/lib/guard.py"
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
    expect_empty "nada gravável fora de workdir, log-dir, /tmp, /var/tmp e HOME" "$out"

    for f in .ssh .gnupg .gitconfig .git-credentials .config/gh .claude .claude.json .codex \
             .docker .aws .npmrc .netrc .bashrc .bash_history; do
        expect_fail "não vê ~/$f do host" test -e "$ET_HOST_HOME/$f"
    done
    expect_empty "nenhum arquivo da HOME do host além de agents/ (e deste script)" \
        "$(find "$ET_HOST_HOME" -not -type d -not -path "$ET_AGENTS_DIR/*" -not -path "$ET_SELF" 2>/dev/null | head -5)"
    expect_fail "não vê o canário fora das montagens" test -e "$ET_CANARY"
    expect_fail "não vê eval/ (testes ocultos e soluções)" test -e "$ET_REPO_ROOT/eval"
    expect_fail "não vê o resto do repositório" test -e "$ET_REPO_ROOT/DIAGNOSTICO-E-PLANO.md"
    for f in /mnt/c /mnt/wsl /mnt/wslg /tmp/.X11-unix /run/user /dev/dxg /init \
             /var/run/docker.sock /run/docker.sock; do
        expect_fail "$f ausente" test -e "$f"
    done
    expect_empty "sem GPU (/dev/nvidia*)" "$(ls /dev/nvidia* 2>/dev/null)"
    v="$(find / \( -path /proc -o -path /sys \) -prune -o -type s -print 2>/dev/null)"
    if [ "$v" = /run/agent-box/llm.sock ]; then ok "o único socket unix visível é o do encaminhador"
    else bad "o único socket unix visível é o do encaminhador" "$(short "$v")"; fi
    expect_empty "nenhum socket unix abstrato (namespace de rede próprio)" \
        "$(awk 'NR > 1 && $8 ~ /^@/' /proc/net/unix)"

    echo "-- skills (só leitura) e variáveis do wrapper"
    expect_ok "AGENT_BOX=1 (definida pelo wrapper)" test "${AGENT_BOX:-}" = 1
    expect_ok "AGENT_SKILLS_DIRS=/opt/skills/base:/opt/skills/extra-1 (${AGENT_SKILLS_DIRS:-vazia})" \
        test "${AGENT_SKILLS_DIRS:-}" = /opt/skills/base:/opt/skills/extra-1
    local sd
    IFS=: read -r -a sd <<<"${AGENT_SKILLS_DIRS:-}"
    for d in "${sd[@]}"; do
        f="$(find "$d" -name SKILL.md 2>/dev/null | head -n1)"
        expect_ok "lê $d" test -n "$f" -a -r "$f"
        expect_fail "não grava em $d" try_write "$d"
        expect_fail "não grava em $(dirname "${f:-$d/x}")" try_write "$(dirname "${f:-$d/x}")"
        expect_fail "não altera ${f:-$d/SKILL.md}" sh -c ": >> '${f:-$d/SKILL.md}'"
    done

    echo "-- processos e ambiente"
    v="$(cat /proc/1/comm)"
    expect_ok "PID 1 é o init do container ($v)" test "$v" = docker-init -o "$v" = tini
    v="$(find /proc -maxdepth 1 -name '[0-9]*' | wc -l)"
    expect_ok "vê só os processos do container ($v)" test "$v" -lt 40
    expect_empty "nenhum processo do host visível" \
        "$(cat /proc/[0-9]*/comm 2>/dev/null | grep -xE 'llama-server|dockerd|containerd|systemd|sshd|code|node.exe' | head -3)"
    expect_empty "nenhuma variável sensível do host" \
        "$(env | cut -d= -f1 | grep -xE 'GITHUB_TOKEN|GH_TOKEN|SSH_AUTH_SOCK|ANTHROPIC_API_KEY|OPENAI_API_KEY|ET_CANARY_SECRET|DOCKER_HOST|WSL_INTEROP|WSL_DISTRO_NAME|WSLENV|DISPLAY|WAYLAND_DISPLAY|DBUS_SESSION_BUS_ADDRESS|XDG_RUNTIME_DIR|AWS_[A-Z_]+')"

    echo "-- git e credenciais"
    for v in docker ssh gh; do expect_fail "sem o comando $v" command -v "$v"; done
    expect_fail "sem ~/.git-credentials" test -e "$HOME/.git-credentials"
    expect_empty "nenhum credential.helper" "$(git config --get-all credential.helper 2>/dev/null | grep -v '^$')"
    git -C "$W" remote add origin https://github.com/kayak/pypika.git 2>/dev/null
    git -C "$W" remote add viassh git@github.com:kayak/pypika.git 2>/dev/null
    expect_fail "git push por HTTPS falha" env GIT_TERMINAL_PROMPT=0 timeout 30 git -C "$W" push origin HEAD:refs/heads/escape-test
    expect_fail "git push por SSH falha" env GIT_TERMINAL_PROMPT=0 timeout 30 git -C "$W" push viassh HEAD:refs/heads/escape-test
    expect_fail "git ls-remote falha (sem rede)" env GIT_TERMINAL_PROMPT=0 timeout 30 git ls-remote https://github.com/kayak/pypika.git

    echo "-- rede"
    v="$(ls /sys/class/net | tr '\n' ' ')"
    expect_ok "só a interface lo ($v)" test "$v" = "lo "
    expect_fail "DNS não resolve example.com" python3 -I -c "import socket; socket.getaddrinfo('example.com', 443)"
    expect_fail "sem internet: curl https://example.com" curl -sS --max-time 10 -o /dev/null https://example.com
    expect_fail "sem internet por IP: 1.1.1.1:443" python3 -I -c "import socket; socket.create_connection(('1.1.1.1', 443), timeout=5)"
    for v in 127.0.0.1:8080 127.0.0.1:22 $ET_HOST_ADDRS; do
        expect_fail "não alcança $v" python3 -I -c "import socket, sys; h, p = sys.argv[1].rsplit(':', 1); socket.create_connection((h, int(p)), timeout=3)" "$v"
    done
    expect_fail "não cria socket vsock (canal do WSL com o Windows)" \
        python3 -I -c "import socket; socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)"
    printf 'MZ\x90\x00\x03\x00' >/tmp/escape.exe && chmod +x /tmp/escape.exe
    expect_fail "não executa binário do Windows (interop do WSL)" /tmp/escape.exe

    echo "-- encaminhador do llama-server (servidor falso no host)"
    expect_ok "GET /health" python3 -I -c "$FWD_CLIENT" health
    expect_ok "3 requisições na mesma conexão (keep-alive)" python3 -I -c "$FWD_CLIENT" keepalive
    if out="$(python3 -I -c "$FWD_CLIENT" sse 2>&1)"; then ok "SSE chega evento a evento ($out s)"
    else bad "SSE chega evento a evento" "$(short "$out")"; fi
    if out="$(python3 -I -c "$FWD_CLIENT" concurrent 2>&1)"; then ok "4 conexões simultâneas de 1,5 s em $out"
    else bad "4 conexões simultâneas" "$(short "$out")"; fi
    expect_ok "POST de 4 MiB ida e volta" python3 -I -c "$FWD_CLIENT" bigbody

    echo "-- limites"
    expect_ok "memória limitada ($ET_MEMORY_BYTES bytes)" test "$(cat /sys/fs/cgroup/memory.max)" = "$ET_MEMORY_BYTES"
    expect_ok "sem swap" test "$(cat /sys/fs/cgroup/memory.swap.max 2>/dev/null)" = 0
    expect_ok "processos limitados ($ET_PIDS)" test "$(cat /sys/fs/cgroup/pids.max)" = "$ET_PIDS"
    expect_ok "CPU limitada ($ET_CPUS)" test "$(cat /sys/fs/cgroup/cpu.max)" = "$((ET_CPUS * 100000)) 100000"

    echo "-- imagem"
    expect_ok "python3.12 em /usr/bin (o .venv do eval aponta para ele)" test -x /usr/bin/python3.12
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
        info "sandbox próprio do Codex (codex sandbox -- true): saída $?: $(short "$out")"
    fi
}

if [ "${1:-}" = --inside ]; then
    inside
    echo "== container: $pass passaram, $fail falharam"
    [ "$fail" = 0 ]
    exit
fi

# ===================================================================================
# No host
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
    "$scratch/skills-prefix/profiles/base/demo" "$scratch/skills-extra/pessoal"
printf -- '---\nname: demo\ndescription: skill falsa do teste\n---\n' >"$scratch/skills-prefix/profiles/base/demo/SKILL.md"
printf -- '---\nname: pessoal\ndescription: skill falsa do teste\n---\n' >"$scratch/skills-extra/pessoal/SKILL.md"
skills_sum() { find "$scratch/skills-prefix" "$scratch/skills-extra" -type f -exec sha256sum {} + | sort; }
skills_before="$(skills_sum)"
canary="$scratch/outside/canary.txt"
echo "canário $(date +%s%N) $RANDOM" >"$canary"
canary_sum="$(sha256sum <"$canary")"
git -C "$scratch/repo" init -q -b main
echo teste >"$scratch/repo/README.md"
git -C "$scratch/repo" add README.md
git -C "$scratch/repo" -c user.name=t -c user.email=t@localhost commit -qm init

# Servidor falso no lugar do llama-server (127.0.0.1) e ouvinte TCP no IP da ponte
# docker0 (o caminho clássico container -> host, que precisa estar fechado).
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
read -r dummy_port bridge_port <"$scratch/ports" || { echo "servidor falso não subiu" >&2; exit 1; }

host_addrs=""
for ip in $(hostname -I 2>/dev/null); do
    case "$ip" in *:*) ;; *) host_addrs+=" $ip:$dummy_port $ip:9931 $ip:8080" ;; esac
done
[ -z "$bridge_ip" ] || host_addrs+=" $bridge_ip:${bridge_port:-9931} $bridge_ip:9931"
ns="$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null)"
[ -z "$ns" ] || host_addrs+=" $ns:53"

mem_bytes=$((3 * 1024 * 1024 * 1024))
before="$(docker ps -aq --filter "label=$BOX_LABEL" | wc -l)"

echo "== agent-box: testes de fuga (scratch $scratch, servidor falso :$dummy_port)"
GITHUB_TOKEN=canario ANTHROPIC_API_KEY=canario OPENAI_API_KEY=canario \
ET_CANARY_SECRET=canario SSH_AUTH_SOCK="$scratch/ssh-agent.sock" \
AGENT_BOX=0 AGENT_SKILLS_DIRS=/home SKILLS_PREFIX="$scratch/skills-prefix" BOX_SKILLS_DIRS= \
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

echo "-- no host, depois do container"
if [ "$(sha256sum <"$canary")" = "$canary_sum" ]; then ok "canário intacto"; else bad "canário intacto"; fi
expect_ok "nada novo fora das montagens" test "$(ls -A "$scratch/outside")" = canary.txt
expect_ok "skills intactas" test "$(skills_sum)" = "$skills_before"
expect_empty "tudo que o container gravou é do usuário do host" \
    "$(find "$scratch/repo" "$scratch/logs" ! -uid "$(id -u)" 2>/dev/null | head -3)"
expect_ok "container removido" test "$(docker ps -aq --filter "label=$BOX_LABEL" | wc -l)" = "$before"
expect_empty "estado temporário do wrapper removido" \
    "$(find "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}" -maxdepth 1 -name 'agent-box.*' -newer "$canary" 2>/dev/null)"

real="${LLM_BASE_URL:-http://127.0.0.1:9931}"
auth=()
[ -z "${LLM_API_KEY:-}" ] || auth=(-H "Authorization: Bearer $LLM_API_KEY")
if curl -fsS --max-time 3 -o /dev/null "${auth[@]}" "${real%/}/health" 2>/dev/null; then
    echo "-- llama-server real em $real"
    LLM_BASE_URL="$real" "$SANDBOX_DIR/run-in-box.sh" --no-skills --rw "$scratch/repo" --ro "$self" \
        --env ET_MODE=real --env "ET_WORKDIR=$scratch/repo" --env "ET_LOGDIR=$scratch/logs" \
        -- bash "$self" --inside
    [ $? = 0 ] || inside_rc=1
else
    info "llama-server real não respondeu em $real/health; teste com o servidor real pulado"
fi

echo "-- item 7 (docs/verificacoes/E7.md): host não segue symlinks do agente"
# R1: processamento de saída no host (boxio + result.py), do jeito que o eval/run.sh
# faz depois do agente, contra um $out/agent-logs com symlinks plantados apontando
# para arquivos do host. Prova leitura e sobrescrita arbitrárias BLOQUEADAS.
reg="$scratch/item7"; mkdir -p "$reg"
vitima_r="$reg/vitima-leitura.txt"; printf 'SEGREDO_HOST_LEITURA\n' >"$vitima_r"
vitima_w="$reg/vitima-escrita.sh"; printf 'conteudo-original-do-bashrc\n' >"$vitima_w"
vitima_w_sum="$(sha256sum <"$vitima_w")"
out="$reg/out"; work="$reg/work"; mkdir -p "$out" "$work/agent-logs"
# (a) leitura: agent-metrics.json como symlink -> arquivo do host (direto na agent-logs,
#     que o agente controla) e, redundante, dentro de $out.
ln -s "$vitima_r" "$work/agent-logs/agent-metrics.json"
# (b) escrita: result.json e meta.json como symlink -> arquivo do host (o que um
#     box_post/box_check comprometido plantaria em $out).
ln -s "$vitima_w" "$out/result.json"
ln -s "$vitima_w" "$out/meta.json"
ln -s "$vitima_r" "$out/agent-logs"   # symlink de diretório, para o caso dir-symlink
printf '{"checks":[],"status":"pass","pass":true}\n' >"$scratch/checks-src.json"
LIB="$REPO_ROOT/eval/lib"
# exatamente os passos do run.sh: copia de logs, varredura de symlinks, meta, result.
python3 -I "$LIB/boxio.py" copy-logs "$work/agent-logs" "$out/agent-logs" 2>/dev/null || true
python3 -I "$LIB/boxio.py" sanitize "$out" >/dev/null 2>&1 || true
cp "$scratch/checks-src.json" "$out/checks.json"
EVAL_LIB="$LIB" python3 -I - "$out/meta.json" <<'PY'
import os, sys; sys.path.insert(0, os.environ["EVAL_LIB"]); import boxio
boxio.write_json_atomic(sys.argv[1], {"run_id":"r","harness":"h","task_id":"S","setup_ok":True})
PY
python3 -I "$LIB/result.py" "$out" >/dev/null 2>&1 || true
expect_ok "vítima de escrita intacta (sem sobrescrita via symlink)" test "$(sha256sum <"$vitima_w")" = "$vitima_w_sum"
expect_ok "result.json é arquivo regular, não symlink" sh -c '[ -f "'"$out"'/result.json" ] && [ ! -L "'"$out"'/result.json" ]'
expect_ok "meta.json é arquivo regular, não symlink" sh -c '[ -f "'"$out"'/meta.json" ] && [ ! -L "'"$out"'/meta.json" ]'
if grep -q SEGREDO_HOST_LEITURA "$out/result.json" 2>/dev/null; then
    bad "conteúdo do host NÃO vazou para result.json"
else ok "conteúdo do host NÃO vazou para result.json"; fi
expect_empty "nenhum symlink restante em \$out" "$(find "$out" -type l 2>/dev/null | head -3)"
expect_ok "vítima de leitura intacta" test "$(cat "$vitima_r")" = SEGREDO_HOST_LEITURA

# R2: a captura do diff (box_post) roda com o workdir só leitura e SEM $out montado;
# nem o fsmonitor/filtro do .git/config do agente nem qualquer código alcança o host.
echo "-- item 7: captura do diff (box_post) contida, com .git/config malicioso"
mrepo="$scratch/malrepo"; mkdir -p "$mrepo"
git -C "$mrepo" init -q -b main
printf 'hook() { : ; }\n' >"$mrepo/a.txt"
git -C "$mrepo" add a.txt
git -C "$mrepo" -c user.name=t -c user.email=t@localhost commit -qm base
base_ref="$(git -C "$mrepo" rev-parse HEAD)"
canary_box="$reg/CANARIO-DO-BOX"   # caminho do host; não montado no box_post
evil="$mrepo/.git/evil.sh"
cat >"$evil" <<EOF
#!/bin/sh
echo PWNED > "$canary_box"
true
EOF
chmod +x "$evil"
# Vetor do item 6/7: fsmonitor roda no git add/status. A captura o desliga com
# -c core.fsmonitor=false (precedência da linha de comando); e mesmo se rodasse,
# o workdir é só leitura e $out não é montado, então não alcançaria o host.
git -C "$mrepo" config core.fsmonitor "$evil"
git -C "$mrepo" config core.hooksPath "$mrepo/.git/hooks-evil"
printf 'mudanca do agente\n' >>"$mrepo/a.txt"
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
expect_fail "fsmonitor/filtro do agente NÃO escreveu no host" test -e "$canary_box"
ns="$(python3 -I "$LIB/boxio.py" extract-diff "$post_tar" "$reg" | tail -n +2)"
expect_ok "o diff ainda foi capturado apesar do .git/config hostil" sh -c 'grep -q "mudanca do agente" "'"$reg"'/agent.patch"'

echo "-- timeout do eval derruba o container"
t0=$SECONDS
timeout -k 5 3 "$SANDBOX_DIR/run-in-box.sh" --no-llm --no-skills -- sleep 120 >/dev/null 2>&1
rc=$?
expect_ok "timeout devolve 124 (saída $rc, $((SECONDS - t0)) s)" test "$rc" = 124
for _ in $(seq 20); do
    [ "$(docker ps -aq --filter "label=$BOX_LABEL" | wc -l)" = "$before" ] && break
    sleep 0.5
done
expect_ok "nenhum container sobrando depois do timeout" \
    test "$(docker ps -aq --filter "label=$BOX_LABEL" | wc -l)" = "$before"

echo "== host: $pass passaram, $fail falharam; container: $([ "$inside_rc" = 0 ] && echo ok || echo FALHOU)"
[ "$fail" = 0 ] && [ "$inside_rc" = 0 ]
