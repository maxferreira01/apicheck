#!/usr/bin/env bash
# check_apic_storage.sh — Check_MK MRPE: partições cheias nas APICs (fault ACI F1529)
#
# Consulta a APIC do fabric e lista os faults F1529 (equipment-full). É o mesmo
# fault que a Cisco aponta para o bug CSCwe09535 (5.2 lota /dev/vg_ifc0/boot),
# e também pega os fabrics com outros filesystems comprometidos (TESP6/TESP7).
#
#   critical/major -> CRIT (2)   minor/warning -> WARN (1)   nenhum -> OK (0)
#
# Uso:    check_apic_storage.sh <FABRIC>        ex.: check_apic_storage.sh TESP2
# Config: /etc/check_mk/apic_storage.conf  (APIC_USER, APIC_PASS, FABRIC_<NOME>=https://ip)

set -uo pipefail

CONF="${APIC_STORAGE_CONF:-/etc/check_mk/apic_storage.conf}"
FABRIC="${1:-}"

unknown() { echo "UNKNOWN - $*"; exit 3; }

[ -n "$FABRIC" ] || unknown "uso: $0 <FABRIC>"
[ -r "$CONF" ]   || unknown "config ${CONF} inexistente ou ilegível"
# shellcheck disable=SC1090
source "$CONF"

url_var="FABRIC_${FABRIC}"
URL="${!url_var:-}"
[ -n "$URL" ] || unknown "fabric ${FABRIC} não definido em ${CONF} (esperado ${url_var}=https://...)"
case "$URL" in *CHANGE_ME*) unknown "URL do fabric ${FABRIC} ainda é placeholder em ${CONF}" ;; esac
URL="${URL%/}"
TIMEOUT="${CURL_TIMEOUT:-15}"

command -v jq >/dev/null 2>&1 || unknown "jq não instalado"

payload=$(jq -n --arg u "${APIC_USER:-}" --arg p "${APIC_PASS:-}" \
    '{aaaUser:{attributes:{name:$u,pwd:$p}}}')
login=$(curl -sk -m "$TIMEOUT" -H 'Content-Type: application/json' \
    -d "$payload" "$URL/api/aaaLogin.json") \
    || unknown "APIC ${FABRIC} inacessível (${URL})"
token=$(jq -r '.imdata[0].aaaLogin.attributes.token // empty' <<<"$login" 2>/dev/null)
if [ -z "$token" ]; then
    err=$(jq -r '.imdata[0].error.attributes.text // "resposta inesperada"' <<<"$login" 2>/dev/null)
    unknown "login falhou na APIC ${FABRIC}: ${err}"
fi

faults=$(curl -sk -m "$TIMEOUT" -b "APIC-cookie=${token}" \
    "$URL/api/node/class/faultInst.json?query-target-filter=eq(faultInst.code,\"F1529\")") \
    || unknown "falha consultando faults na APIC ${FABRIC}"
nodes=$(curl -sk -m "$TIMEOUT" -b "APIC-cookie=${token}" \
    "$URL/api/node/class/topSystem.json") || nodes='{}'

declare -A NODE_NAME
while IFS=$'\t' read -r id name; do
    [ -n "$id" ] && NODE_NAME["$id"]="$name"
done < <(jq -r '.imdata[]?.topSystem.attributes | [.id, .name] | @tsv' <<<"$nodes" 2>/dev/null)

crit=0 warn=0 total=0 max_pct=0
details=""
while IFS=$'\t' read -r sev dn descr; do
    [ -n "$sev" ] || continue
    total=$((total + 1))
    case "$sev" in
        critical|major) crit=$((crit + 1)) ;;
        *)              warn=$((warn + 1)) ;;
    esac
    node=""
    [[ $dn =~ node-([0-9]+) ]] && node="${BASH_REMATCH[1]}"
    name="${NODE_NAME[$node]:-node-${node:-?}}"
    if [[ $descr =~ ([0-9]{1,3})% ]] && [ "${BASH_REMATCH[1]}" -gt "$max_pct" ]; then
        max_pct="${BASH_REMATCH[1]}"
    fi
    details+="${details:+; }${name} [${sev}]: ${descr}"
done < <(jq -r '.imdata[]?.faultInst.attributes
                | select(.severity != "cleared")
                | [.severity, .dn, .descr] | @tsv' <<<"$faults" 2>/dev/null)

perf="faults=${total};;;0 max_usage=${max_pct}%;;;0;100"
details="${details:0:900}"

if [ "$total" -eq 0 ]; then
    echo "OK - ${FABRIC}: sem fault F1529, filesystems das APICs saudáveis | ${perf}"
    exit 0
fi
if [ "$crit" -gt 0 ]; then
    echo "CRIT - ${FABRIC}: ${total} partição(ões) com F1529 / disco cheio (bug CSCwe09535, reload da APIC necessário): ${details} | ${perf}"
    exit 2
fi
echo "WARN - ${FABRIC}: ${total} fault(s) F1529: ${details} | ${perf}"
exit 1
