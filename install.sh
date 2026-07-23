#!/usr/bin/env bash
# install.sh — instala o check MRPE de disco cheio nas APICs (fault F1529).
#
# O que faz (idempotente, pode rodar quantas vezes quiser):
#   1. Instala dependências (curl, jq) — cobre RHEL (dnf) e Ubuntu (apt)
#   2. Copia check_apic_storage.sh para /usr/local/bin
#   3. Cria /etc/check_mk/apic_storage.conf (credenciais + lista de fabrics)
#      se ainda não existir — lê APIC_USER/APIC_PASS do env ou pede a senha.
#      ATENÇÃO: se o conf JÁ existe, o template abaixo é ignorado — edite o
#      conf direto na box.
#   4. Escreve no /etc/check_mk/mrpe.cfg (bloco entre marcadores, sem tocar
#      nas outras linhas) um serviço CAPACITY%20DISCO%20APIC%20<FABRIC> por
#      fabric configurado no conf
#   5. Roda o check uma vez por fabric configurado, pra validar
#
# Depois de editar o conf (adicionar/ajustar IPs), re-rode:  sudo bash install.sh
#
# Uso:
#   sudo bash install.sh
#   sudo APIC_USER=admin APIC_PASS='...' bash install.sh    # não-interativo

set -euo pipefail

BIN_DST=/usr/local/bin/check_apic_storage.sh
CONF=/etc/check_mk/apic_storage.conf
MRPE_MAIN=/etc/check_mk/mrpe.cfg
SVC_PREFIX='CAPACITY%20DISCO%20APIC%20'
SVC_INTERVAL=300
BEGIN_MARK='# BEGIN apic-storage-check'
END_MARK='# END apic-storage-check'
SRC_DIR=$(cd "$(dirname "$0")" && pwd)

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "    \033[0;32m[OK]\033[0m $*"; }
err()  { echo -e "    \033[0;31m[ERRO]\033[0m $*" >&2; }
warn() { echo -e "    \033[0;33m[WARN]\033[0m $*" >&2; }

if [ "$(id -u)" != "0" ]; then
    err "rode como root (sudo)"
    exit 1
fi
[ -f "${SRC_DIR}/check_apic_storage.sh" ] || { err "check_apic_storage.sh não está ao lado do install.sh"; exit 1; }

log "Dependências (curl, jq)"
MISSING=""
for dep in curl jq; do
    command -v "$dep" >/dev/null 2>&1 || MISSING="${MISSING} ${dep}"
done
if [ -n "$MISSING" ]; then
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y $MISSING
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y $MISSING
    else
        err "nem dnf nem apt-get encontrados — instale manualmente:${MISSING}"
        exit 1
    fi
fi
ok "curl e jq presentes"

log "Instalando script em ${BIN_DST}"
install -m 0755 "${SRC_DIR}/check_apic_storage.sh" "$BIN_DST"
ok "instalado"

log "Configuração ${CONF}"
if [ -f "$CONF" ]; then
    ok "já existe — mantendo (edite-o e re-rode este install pra regenerar o mrpe)"
else
    APIC_USER="${APIC_USER:-admin}"
    APIC_PASS="${APIC_PASS:-}"
    if [ -z "$APIC_PASS" ]; then
        read -r -s -p "    Senha APIC (user ${APIC_USER}): " APIC_PASS; echo
    fi
    [ -n "$APIC_PASS" ] || { err "senha vazia"; exit 1; }
    mkdir -p "$(dirname "$CONF")"
    cat > "$CONF" <<EOF
# apic_storage.conf — config do check_apic_storage.sh (MRPE)
# Formato shell: é feito "source" deste arquivo pelo check.
# Um FABRIC_<NOME>=https://<ip-da-apic> por fabric; troque os CHANGE_ME.
# Fabrics com CHANGE_ME são ignorados na geração do mrpe.

APIC_USER='${APIC_USER}'
APIC_PASS='${APIC_PASS}'
CURL_TIMEOUT=15

FABRIC_TESP2='https://CHANGE_ME'
FABRIC_TESP3='https://CHANGE_ME'
FABRIC_TESP4='https://CHANGE_ME'
FABRIC_TESP5='https://CHANGE_ME'
FABRIC_TESP6='https://10.114.35.100'
FABRIC_TESP7='https://CHANGE_ME'
FABRIC_TECE01='https://CHANGE_ME'
FABRIC_TBSP02='https://CHANGE_ME'
# Adicione aqui os demais fabrics (são 11 no total).
EOF
    chmod 600 "$CONF"
    ok "criado (chmod 600) — edite os IPs das APICs e re-rode o install"
fi

log "Atualizando ${MRPE_MAIN}"
# shellcheck disable=SC1090
source "$CONF"
touch "$MRPE_MAIN"

# Agentes antigos não suportam "(interval=N)" no mrpe.cfg — a linha é ignorada.
# Só usa cache se o binário do agente tiver a função run_cached.
AGENT_BIN=$(command -v check_mk_agent || echo /usr/bin/check_mk_agent)
if grep -q 'run_cached\|cached(' "$AGENT_BIN" 2>/dev/null; then
    SVC_OPTS=" (interval=${SVC_INTERVAL})"
    ok "agente suporta cache — usando (interval=${SVC_INTERVAL})"
else
    SVC_OPTS=""
    warn "agente sem suporte a interval/cache — check vai rodar a cada poll (síncrono)"
fi

# Limpa restos de instalação antiga (esquema mrpe.cfg.d + include), se houver
sed -i '\#^include *= */etc/check_mk/mrpe\.cfg\.d/apic-storage\.cfg#d' "$MRPE_MAIN"
rm -f /etc/check_mk/mrpe.cfg.d/apic-storage.cfg

# Remove o bloco anterior (entre marcadores) e reescreve com o conf atual
TMP=$(mktemp)
awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    index($0, b) == 1 { skip = 1; next }
    index($0, e) == 1 { skip = 0; next }
    !skip { print }
' "$MRPE_MAIN" > "$TMP"

# Bloco vai no TOPO do arquivo: scripts MRPE que usam ssh sem -n engolem o
# stdin do loop do agente (= o resto do mrpe.cfg), e linhas abaixo deles
# nunca executam. No topo estamos imunes.
N_SVC=0
{
    echo "${BEGIN_MARK} (gerado pelo install.sh — re-rode o install após editar ${CONF})"
    for var in $(compgen -A variable | grep '^FABRIC_' | sort); do
        fabric="${var#FABRIC_}"
        url="${!var}"
        case "$url" in
            *CHANGE_ME*|"") continue ;;
        esac
        echo "${SVC_PREFIX}${fabric}${SVC_OPTS} ${BIN_DST} ${fabric}"
        N_SVC=$((N_SVC + 1))
    done
    echo "$END_MARK"
    cat "$TMP"
} > "${TMP}.new"
N_SVC=$(grep -c "^${SVC_PREFIX}" "${TMP}.new" || true)
cat "${TMP}.new" > "$MRPE_MAIN"
rm -f "$TMP" "${TMP}.new"

if [ "$N_SVC" -eq 0 ]; then
    warn "nenhum fabric com IP definido ainda — bloco gerado vazio. Edite ${CONF} e re-rode."
else
    ok "${N_SVC} serviço(s) no bloco apic-storage-check do ${MRPE_MAIN}"
fi

log "Teste dos fabrics configurados"
for var in $(compgen -A variable | grep '^FABRIC_' | sort); do
    fabric="${var#FABRIC_}"
    case "${!var}" in *CHANGE_ME*|"") continue ;; esac
    printf '    %-22s ' "$fabric:"
    "$BIN_DST" "$fabric" || true
done

log "Pronto"
echo "    Serviços aparecem no Check_MK como \"CAPACITY DISCO APIC <FABRIC>\" após o"
echo "    próximo service discovery do host deste agente."
