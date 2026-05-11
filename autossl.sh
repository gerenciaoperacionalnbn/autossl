#!/usr/bin/env bash
# =============================================================================
# setup_apache_letsencrypt.sh
# -----------------------------------------------------------------------------
# Configura HTTPS via Let's Encrypt em um servidor Linux com Apache.
#
# Pré-requisito (responsabilidade do operador, NÃO deste script):
#   1. O domínio (registro A no DNS) tem que apontar para o IP público
#      desta máquina. Aguarde a propagação antes de rodar.
#   2. Portas 80 e 443 acessíveis pela Internet (firewall/NAT/cloud SG).
#
# O que o script faz sozinho:
#   - Detecta distribuição (Debian/Ubuntu).
#   - Instala Apache se não houver (sob confirmação).
#   - Instala certbot + plugin Apache.
#   - Confere se o DNS resolve para o IP desta máquina.
#   - Detecta VirtualHost duplicado e pede confirmação para sobrescrever.
#   - Cria VirtualHost em /etc/apache2/sites-available/<dominio>.conf.
#   - Opcional: redireciona "/" para um subdiretório (ex: /zabbix/, /grafana/).
#   - Opcional: aplica DocumentRoot customizado (servir app na raiz do site).
#   - Opcional: abre UFW para 80/443.
#   - Opcional: ativa "Apache hardening" (HSTS, X-Content-Type-Options).
#   - Emite o certificado via certbot --apache, com --redirect (HTTP→HTTPS).
#   - Suporta múltiplos domínios (-d <dom> repetido), útil para www.
#   - Suporta --staging para testar sem queimar rate-limit do Let's Encrypt.
#   - Rollback automático em qualquer falha: backup dos confs, a2dissite,
#     certbot delete.
#   - Loga toda execução em /var/log/setup_apache_letsencrypt.log.
#   - Mostra status do timer de renovação automática no final.
#
# Uso (interativo — recomendado para a maioria dos casos):
#     sudo bash setup_apache_letsencrypt.sh
#
# Uso não-interativo (CI / automação):
#     sudo bash setup_apache_letsencrypt.sh \
#         -d app.example.com.br \
#         -d www.app.example.com.br \
#         --email admin@example.com.br \
#         --redirect-root /zabbix/ \
#         --hsts --open-firewall --yes
#
# Flags:
#   -d, --domain DOM         domínio (pode repetir; o primeiro é o principal)
#   --email EMAIL            e-mail para conta Let's Encrypt
#   --redirect-root PATH     "/" → PATH (ex: /zabbix/). Vazio = não redireciona.
#   --document-root DIR      DocumentRoot do VHost (ex: /var/www/app). Vazio =
#                            usa o default do Apache (/var/www/html).
#   --staging                usa staging do Let's Encrypt (cert não confiável,
#                            ideal para testar)
#   --no-http-redirect       NÃO força HTTP→HTTPS (default: força)
#   --hsts                   adiciona HSTS no VHost SSL após emitir o cert
#   --open-firewall          abre UFW 80/443/tcp se UFW estiver ativo
#   --install-apache         instala apache2 se não houver (sem perguntar)
#   -y, --yes                não pede nenhuma confirmação
#   -h, --help               esta ajuda
#
# Licença: MIT — script público, livre para uso/modificação.
# =============================================================================

set -euo pipefail

# ---------- cores e helpers ---------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
    C_CYN=$'\033[0;36m'; C_BLD=$'\033[1m';   C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YLW=""; C_CYN=""; C_BLD=""; C_RST=""
fi

LOG_FILE="/var/log/setup_apache_letsencrypt.log"
log() {  # log "msg" — escreve em stdout e no log
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "$@"
    echo "[${ts}] $(echo -e "$@" | sed 's/\x1b\[[0-9;]*m//g')" >> "$LOG_FILE" 2>/dev/null || true
}
info() { log "${C_CYN}[info]${C_RST}  $*"; }
ok()   { log "${C_GRN}[ ok ]${C_RST}  $*"; }
warn() { log "${C_YLW}[warn]${C_RST}  $*"; }
err()  { log "${C_RED}[erro]${C_RST}  $*"; }
die()  { err "$*"; exit 1; }
hr()   { log "------------------------------------------------------------"; }

usage() { sed -n '2,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---------- defaults e flags --------------------------------------------------
DOMAINS=()
EMAIL=""
REDIRECT_ROOT=""
DOCUMENT_ROOT=""
HTTP_REDIRECT="yes"
USE_STAGING="no"
ENABLE_HSTS="no"
OPEN_FIREWALL="no"
INSTALL_APACHE_AUTO="no"
ASSUME_YES="no"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--domain)         DOMAINS+=("$2"); shift 2 ;;
        --email)             EMAIL="$2"; shift 2 ;;
        --redirect-root)     REDIRECT_ROOT="$2"; shift 2 ;;
        --document-root)     DOCUMENT_ROOT="$2"; shift 2 ;;
        --staging)           USE_STAGING="yes"; shift ;;
        --no-http-redirect)  HTTP_REDIRECT="no"; shift ;;
        --hsts)              ENABLE_HSTS="yes"; shift ;;
        --open-firewall)     OPEN_FIREWALL="yes"; shift ;;
        --install-apache)    INSTALL_APACHE_AUTO="yes"; shift ;;
        -y|--yes)            ASSUME_YES="yes"; shift ;;
        -h|--help)           usage 0 ;;
        *) die "flag desconhecida: $1 (use -h para ajuda)" ;;
    esac
done

# ---------- prompts -----------------------------------------------------------
prompt() {  # prompt "label" "default"  -> ecoa valor lido (ou default)
    local label="$1" default="${2:-}"
    local hint="" reply=""
    [[ -n "$default" ]] && hint=" [${default}]"
    read -r -p "  ${label}${hint}: " reply </dev/tty || true
    echo "${reply:-$default}"
}
confirm() {  # confirm "pergunta"  -> exit code 0 se sim
    [[ "$ASSUME_YES" == "yes" ]] && return 0
    local reply=""
    read -r -p "  $1 [s/N]: " reply </dev/tty || true
    [[ "${reply,,}" == "s" || "${reply,,}" == "sim" || "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

# ---------- preflight ---------------------------------------------------------
echo
log "${C_BLD}Setup HTTPS (Apache + Let's Encrypt)${C_RST}"
hr
info "Log desta execução: $LOG_FILE"

[[ $EUID -eq 0 ]] || die "rode como root (sudo bash $0)"
command -v apt-get >/dev/null 2>&1 || die "este script só roda em Debian/Ubuntu (apt-get não encontrado)"

# distro/versão pra info
DISTRO="$(. /etc/os-release && echo "${PRETTY_NAME:-desconhecido}")" || DISTRO="desconhecido"
info "Distribuição: ${DISTRO}"

# Apache instalado?
if ! command -v apache2 >/dev/null 2>&1; then
    warn "apache2 não está instalado."
    if [[ "$INSTALL_APACHE_AUTO" == "yes" ]] || confirm "Instalar apache2 agora?"; then
        info "Instalando apache2..."
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apache2
        systemctl enable --now apache2
        ok "apache2 instalado e ativo."
    else
        die "abortado — instale o Apache (sudo apt install apache2) e configure o site HTTP antes de rodar."
    fi
fi
if ! systemctl is-active --quiet apache2; then
    warn "apache2 não está ativo agora — tentando iniciar..."
    systemctl start apache2 || die "falha ao iniciar apache2; veja 'systemctl status apache2'"
fi

# ---------- coleta interativa -------------------------------------------------
if [[ ${#DOMAINS[@]} -eq 0 ]]; then
    echo
    info "Informe o domínio que deve receber HTTPS (FQDN, sem https://)."
    info "Ex: app.example.com.br"
    primary="$(prompt 'Domínio principal')"
    [[ -n "$primary" ]] || die "domínio é obrigatório"
    DOMAINS+=("$primary")
    while confirm "Adicionar outro domínio/alias para o mesmo certificado (ex: www.${primary})?"; do
        alt="$(prompt 'Domínio adicional')"
        [[ -n "$alt" ]] && DOMAINS+=("$alt")
    done
fi
for d in "${DOMAINS[@]}"; do
    [[ "$d" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "domínio inválido: $d"
done

if [[ -z "$EMAIL" ]]; then
    echo
    info "E-mail de contato Let's Encrypt (recebe avisos de expiração)."
    EMAIL="$(prompt 'E-mail')"
fi
[[ "$EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]] || die "e-mail inválido: $EMAIL"

if [[ -z "$REDIRECT_ROOT" ]] && [[ "$ASSUME_YES" != "yes" ]]; then
    echo
    info "Quando alguém abrir https://${DOMAINS[0]}/ , o que deve carregar?"
    info "  - Vazio (Enter) = serve o que o Apache já serve hoje em /."
    info "  - Path /xxx/   = redireciona / -> /xxx/ (ex: /zabbix/, /grafana/)."
    sug=""
    if [[ -f /etc/apache2/conf-enabled/zabbix.conf ]]; then
        sug="/zabbix/"
        info "${C_YLW}detectei /etc/apache2/conf-enabled/zabbix.conf — sugerindo /zabbix/${C_RST}"
    fi
    REDIRECT_ROOT="$(prompt 'Redirect raiz para' "$sug")"
fi
if [[ -n "$REDIRECT_ROOT" ]]; then
    [[ "$REDIRECT_ROOT" =~ ^/ ]] || REDIRECT_ROOT="/$REDIRECT_ROOT"
    [[ "$REDIRECT_ROOT" =~ /$ ]] || REDIRECT_ROOT="$REDIRECT_ROOT/"
fi

if [[ -z "$DOCUMENT_ROOT" ]] && [[ -z "$REDIRECT_ROOT" ]] && [[ "$ASSUME_YES" != "yes" ]]; then
    echo
    info "DocumentRoot do VirtualHost (deixe vazio para usar o default do Apache)."
    info "Ex: /var/www/meuapp"
    DOCUMENT_ROOT="$(prompt 'DocumentRoot' '')"
fi
if [[ -n "$DOCUMENT_ROOT" ]]; then
    [[ -d "$DOCUMENT_ROOT" ]] || warn "DocumentRoot ${DOCUMENT_ROOT} não existe ainda (Apache pode falhar)."
fi

if [[ "$ENABLE_HSTS" == "no" ]] && [[ "$ASSUME_YES" != "yes" ]]; then
    echo
    if confirm "Ativar HSTS (Strict-Transport-Security) no VHost HTTPS?"; then
        ENABLE_HSTS="yes"
    fi
fi

# ---------- validação DNS -----------------------------------------------------
echo
info "Validando DNS..."
PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
info "  IP público desta máquina: ${PUBLIC_IP:-desconhecido}"
DNS_PROBLEMS=0
for d in "${DOMAINS[@]}"; do
    ips="$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
    if [[ -z "$ips" ]]; then
        err "  ${d}: DNS NÃO resolve (verifique o registro A)."
        DNS_PROBLEMS=$((DNS_PROBLEMS+1))
        continue
    fi
    if [[ -n "$PUBLIC_IP" ]] && ! echo "$ips" | grep -qw "$PUBLIC_IP"; then
        warn "  ${d} -> ${ips} (não bate com o IP público ${PUBLIC_IP})"
        DNS_PROBLEMS=$((DNS_PROBLEMS+1))
    else
        ok "  ${d} -> ${ips}"
    fi
done
if [[ $DNS_PROBLEMS -gt 0 ]]; then
    warn "Há ${DNS_PROBLEMS} domínio(s) com problema de DNS — o certbot vai falhar no challenge HTTP-01."
    confirm "Continuar mesmo assim?" || die "abortado pelo usuário"
fi

# ---------- VirtualHost duplicado? -------------------------------------------
PRIMARY="${DOMAINS[0]}"
SITE_CONF="/etc/apache2/sites-available/${PRIMARY}.conf"
DUP="$(grep -rlE "^\s*ServerName\s+${PRIMARY//./\\.}\b" /etc/apache2/sites-enabled/ 2>/dev/null | grep -v "${PRIMARY}.conf" || true)"
if [[ -n "$DUP" ]]; then
    warn "Já existe(m) VirtualHost(s) ativo(s) com ServerName=${PRIMARY}:"
    echo "$DUP" | sed 's/^/    /'
    confirm "Continuar e deixar Apache decidir qual usar (geralmente o que tiver carregado primeiro)?" \
        || die "abortado — desabilite o(s) site(s) conflitante(s) com 'a2dissite' e rode de novo"
fi

# ---------- firewall ----------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    if ! ufw status | grep -qE "^(80|443)/tcp\s+ALLOW"; then
        warn "UFW está ativo e parece NÃO permitir 80/443/tcp."
        if [[ "$OPEN_FIREWALL" == "yes" ]] || confirm "Abrir 80/443/tcp no UFW agora?"; then
            ufw allow 80/tcp  || true
            ufw allow 443/tcp || true
            ok "UFW: portas 80 e 443 liberadas."
        fi
    fi
fi

# ---------- resumo + confirmação ---------------------------------------------
echo
hr
log "${C_BLD}Resumo:${C_RST}"
log "  Domínios       : ${DOMAINS[*]}"
log "  E-mail LE      : $EMAIL"
log "  Redirect raiz  : ${REDIRECT_ROOT:-(nenhum)}"
log "  DocumentRoot   : ${DOCUMENT_ROOT:-(default Apache)}"
log "  HTTP->HTTPS    : $HTTP_REDIRECT"
log "  HSTS           : $ENABLE_HSTS"
log "  Staging mode   : $USE_STAGING"
log "  IP público     : ${PUBLIC_IP:-?}"
hr
confirm "Prosseguir?" || die "abortado"

# ---------- rollback infra ----------------------------------------------------
BACKUP_TAG="$(date +%Y%m%d-%H%M%S)"
ROLLBACK_CMDS=()
add_rollback() { ROLLBACK_CMDS+=("$1"); }
do_rollback() {
    warn "Executando rollback..."
    for (( i=${#ROLLBACK_CMDS[@]}-1; i>=0; i-- )); do
        bash -c "${ROLLBACK_CMDS[$i]}" || true
    done
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then err "falha (exit $rc) — revertendo"; do_rollback; fi' EXIT

# ---------- etapa 1: certbot --------------------------------------------------
echo
info "[1/6] Instalando certbot + python3-certbot-apache"
if command -v certbot >/dev/null 2>&1; then
    ok "  certbot já instalado: $(certbot --version 2>&1)"
else
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot python3-certbot-apache
    ok "  certbot instalado: $(certbot --version 2>&1)"
fi

# ---------- etapa 2: VirtualHost HTTP ----------------------------------------
echo
info "[2/6] Criando VirtualHost HTTP em ${SITE_CONF}"
if [[ -f "$SITE_CONF" ]]; then
    backup="${SITE_CONF}.bak.${BACKUP_TAG}"
    cp -a "$SITE_CONF" "$backup"
    info "  ${SITE_CONF} já existia — backup em ${backup}"
    add_rollback "mv -f '$backup' '$SITE_CONF'"
else
    add_rollback "rm -f '$SITE_CONF'"
fi

{
    echo "<VirtualHost *:80>"
    echo "    ServerName ${DOMAINS[0]}"
    for d in "${DOMAINS[@]:1}"; do
        echo "    ServerAlias ${d}"
    done
    [[ -n "$DOCUMENT_ROOT" ]] && echo "    DocumentRoot ${DOCUMENT_ROOT}"
    if [[ -n "$REDIRECT_ROOT" ]]; then
        echo "    RedirectMatch ^/\$ ${REDIRECT_ROOT}"
    fi
    if [[ -n "$DOCUMENT_ROOT" ]]; then
        echo "    <Directory ${DOCUMENT_ROOT}>"
        echo "        Options FollowSymLinks"
        echo "        AllowOverride All"
        echo "        Require all granted"
        echo "    </Directory>"
    fi
    echo "    ErrorLog \${APACHE_LOG_DIR}/${PRIMARY}_error.log"
    echo "    CustomLog \${APACHE_LOG_DIR}/${PRIMARY}_access.log combined"
    echo "</VirtualHost>"
} > "$SITE_CONF"

apache2ctl configtest 2>&1 | sed 's/^/    /'

# ---------- etapa 3: a2ensite + reload ---------------------------------------
echo
info "[3/6] Habilitando site e recarregando Apache"
if [[ ! -L "/etc/apache2/sites-enabled/${PRIMARY}.conf" ]]; then
    a2ensite "${PRIMARY}" >/dev/null
    add_rollback "a2dissite '${PRIMARY}' >/dev/null && systemctl reload apache2"
fi
systemctl reload apache2
ok "  Apache recarregado."

# ---------- etapa 4: certbot --------------------------------------------------
echo
info "[4/6] Solicitando certificado Let's Encrypt (HTTP-01 / plugin apache)"
CERTBOT_ARGS=(--apache -m "$EMAIL" --non-interactive --agree-tos --keep-until-expiring)
for d in "${DOMAINS[@]}"; do CERTBOT_ARGS+=(-d "$d"); done
[[ "$HTTP_REDIRECT" == "yes" ]] && CERTBOT_ARGS+=(--redirect) || CERTBOT_ARGS+=(--no-redirect)
[[ "$USE_STAGING"   == "yes" ]] && CERTBOT_ARGS+=(--staging)
certbot "${CERTBOT_ARGS[@]}"
add_rollback "certbot delete --cert-name '${PRIMARY}' --non-interactive >/dev/null 2>&1 || true"

# ---------- etapa 5: HSTS opcional -------------------------------------------
SSL_CONF="/etc/apache2/sites-available/${PRIMARY}-le-ssl.conf"
if [[ "$ENABLE_HSTS" == "yes" ]] && [[ -f "$SSL_CONF" ]]; then
    echo
    info "[5/6] Aplicando HSTS em ${SSL_CONF}"
    if ! grep -q "Strict-Transport-Security" "$SSL_CONF"; then
        backup="${SSL_CONF}.bak.${BACKUP_TAG}"
        cp -a "$SSL_CONF" "$backup"
        add_rollback "mv -f '$backup' '$SSL_CONF' && systemctl reload apache2"
        a2enmod headers >/dev/null 2>&1 || true
        # injeta as 2 linhas logo após ServerName
        sed -i "/ServerName ${PRIMARY//./\\.}/a \    Header always set Strict-Transport-Security \"max-age=31536000; includeSubDomains\"\n    Header always set X-Content-Type-Options \"nosniff\"" "$SSL_CONF"
        apache2ctl configtest
        systemctl reload apache2
        ok "  HSTS ativado."
    else
        ok "  HSTS já presente — nada a fazer."
    fi
else
    echo
    info "[5/6] HSTS: pulado (não solicitado ou conf SSL ainda não existe)"
fi

# ---------- etapa 6: validação ------------------------------------------------
echo
info "[6/6] Validando endpoints"
hr
for d in "${DOMAINS[@]}"; do
    echo "  http://${d}/ :"
    curl -sI --max-time 10 "http://${d}/" | head -3 | sed 's/^/      /' || warn "curl HTTP falhou em ${d}"
    echo "  https://${d}/ :"
    curl -sI --max-time 10 "https://${d}/" | head -3 | sed 's/^/      /' || warn "curl HTTPS falhou em ${d}"
done
if [[ -n "$REDIRECT_ROOT" ]]; then
    echo "  https://${PRIMARY}${REDIRECT_ROOT} :"
    curl -sI --max-time 10 "https://${PRIMARY}${REDIRECT_ROOT}" | head -3 | sed 's/^/      /' || warn "curl path falhou"
fi
hr

# status do timer de renew
echo
info "Renovação automática:"
systemctl list-timers --no-pager 2>/dev/null | grep -E "certbot|snap\.certbot" | sed 's/^/    /' \
    || warn "não encontrei timer de certbot — verifique 'systemctl list-timers' manualmente"

echo
info "Lista de certificados:"
certbot certificates 2>/dev/null | sed 's/^/    /' || true

# desarmar rollback — sucesso
trap - EXIT
echo
ok "${C_BLD}Concluído com sucesso.${C_RST}"
echo
echo "  Para revogar este cert:    sudo certbot delete --cert-name ${PRIMARY}"
echo "  Para desabilitar o site:   sudo a2dissite ${PRIMARY} && sudo systemctl reload apache2"
echo "  Para renovar manualmente:  sudo certbot renew"
echo "  Log desta execução:        ${LOG_FILE}"
