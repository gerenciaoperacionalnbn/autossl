#!/usr/bin/env bash
# =============================================================================
# autossl.sh
# -----------------------------------------------------------------------------
# Configura HTTPS via Let's Encrypt em um servidor Linux, em cima de Apache
# OU Nginx, com suporte para as duas famílias de distros mais comuns.
#
# Pré-requisito (responsabilidade do operador, NÃO deste script):
#   1. O domínio (registro A no DNS) tem que apontar para o IP público
#      desta máquina. Aguarde a propagação antes de rodar.
#   2. Portas 80 e 443 acessíveis pela Internet (firewall/NAT/cloud SG).
#
# Sistemas operacionais suportados:
#   ┌─────────────────────────────────────────┬──────────┬──────────────────┐
#   │ Distribuição                            │ Status   │ Gerenciador      │
#   ├─────────────────────────────────────────┼──────────┼──────────────────┤
#   │ Debian 11 / 12                          │ ok       │ apt              │
#   │ Ubuntu 20.04 / 22.04 / 24.04            │ ok       │ apt              │
#   │ CentOS 7                                │ parcial* │ yum              │
#   │ CentOS Stream 8 / 9                     │ ok       │ dnf              │
#   │ Rocky / AlmaLinux 8 / 9                 │ ok       │ dnf              │
#   │ RHEL 8 / 9                              │ ok       │ dnf              │
#   │ Fedora (recente)                        │ ok       │ dnf              │
#   │ Outras                                  │ untested │ (tenta detectar) │
#   └─────────────────────────────────────────┴──────────┴──────────────────┘
#   * CentOS 7: EOL desde jun/2024; certbot via EPEL costuma funcionar mas
#     não recebe mais atualizações de segurança.
#
# Servidores web suportados:
#   - Apache (apache2 no Debian/Ubuntu, httpd no RHEL family)
#   - Nginx
#
# Uso (interativo — recomendado):
#     sudo bash autossl.sh
#
# Uso não-interativo (CI / automação):
#     sudo bash autossl.sh \
#         --webserver apache \
#         -d app.example.com.br \
#         -d www.app.example.com.br \
#         --email admin@example.com.br \
#         --redirect-root /zabbix/ \
#         --hsts --open-firewall --yes
#
# Flags:
#   --webserver apache|nginx  força um webserver (default: detecta/pergunta)
#   -d, --domain DOM          domínio (pode repetir; 1º é o principal)
#   --email EMAIL             e-mail para conta Let's Encrypt
#   --redirect-root PATH      "/" → PATH (ex: /zabbix/). Vazio = não redireciona
#   --document-root DIR       DocumentRoot do VHost (ex: /var/www/app)
#   --staging                 usa staging Let's Encrypt (cert não confiável)
#   --no-http-redirect        NÃO força HTTP→HTTPS (default: força)
#   --hsts                    adiciona HSTS após emitir o cert
#   --open-firewall           abre 80/443 (ufw OU firewalld) se ativo
#   --install-webserver       instala o webserver escolhido sem perguntar
#   -y, --yes                 não pede nenhuma confirmação
#   -h, --help                esta ajuda
#
# Licença: MIT
# =============================================================================

set -euo pipefail

# ---------- cores + log -------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
    C_CYN=$'\033[0;36m'; C_BLD=$'\033[1m';   C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YLW=""; C_CYN=""; C_BLD=""; C_RST=""
fi
LOG_FILE="/var/log/autossl.log"
log()  {
    echo -e "$@"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $(echo -e "$@" | sed 's/\x1b\[[0-9;]*m//g')" \
         >> "$LOG_FILE" 2>/dev/null || true
}
info() { log "${C_CYN}[info]${C_RST}  $*"; }
ok()   { log "${C_GRN}[ ok ]${C_RST}  $*"; }
warn() { log "${C_YLW}[warn]${C_RST}  $*"; }
err()  { log "${C_RED}[erro]${C_RST}  $*"; }
die()  { err "$*"; exit 1; }
hr()   { log "------------------------------------------------------------"; }

usage() { sed -n '2,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---------- defaults / flags --------------------------------------------------
WEBSERVER=""
DOMAINS=()
EMAIL=""
REDIRECT_ROOT=""
DOCUMENT_ROOT=""
HTTP_REDIRECT="yes"
USE_STAGING="no"
ENABLE_HSTS="no"
OPEN_FIREWALL="no"
INSTALL_WS_AUTO="no"
ASSUME_YES="no"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --webserver)         WEBSERVER="$2"; shift 2 ;;
        -d|--domain)         DOMAINS+=("$2"); shift 2 ;;
        --email)             EMAIL="$2"; shift 2 ;;
        --redirect-root)     REDIRECT_ROOT="$2"; shift 2 ;;
        --document-root)     DOCUMENT_ROOT="$2"; shift 2 ;;
        --staging)           USE_STAGING="yes"; shift ;;
        --no-http-redirect)  HTTP_REDIRECT="no"; shift ;;
        --hsts)              ENABLE_HSTS="yes"; shift ;;
        --open-firewall)     OPEN_FIREWALL="yes"; shift ;;
        --install-webserver) INSTALL_WS_AUTO="yes"; shift ;;
        -y|--yes)            ASSUME_YES="yes"; shift ;;
        -h|--help)           usage 0 ;;
        *) die "flag desconhecida: $1 (use -h para ajuda)" ;;
    esac
done

prompt() {
    local label="$1" default="${2:-}" hint="" reply=""
    [[ -n "$default" ]] && hint=" [${default}]"
    read -r -p "  ${label}${hint}: " reply </dev/tty || true
    echo "${reply:-$default}"
}
confirm() {
    [[ "$ASSUME_YES" == "yes" ]] && return 0
    local reply=""
    read -r -p "  $1 [s/N]: " reply </dev/tty || true
    [[ "${reply,,}" == "s" || "${reply,,}" == "sim" || "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}
menu() {
    local label="$1" opts="$2" reply=""
    local IFS='|'; local arr=($opts); IFS=' '
    echo "  $label" >&2
    local i
    for i in "${!arr[@]}"; do echo "    $((i+1))) ${arr[$i]}" >&2; done
    while true; do
        read -r -p "  escolha [1-${#arr[@]}]: " reply </dev/tty || true
        if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#arr[@]} )); then
            echo "${arr[$((reply-1))]}"
            return 0
        fi
    done
}

# ---------- preflight ---------------------------------------------------------
echo
log "${C_BLD}autossl — configurador HTTPS automático (Apache/Nginx + Let's Encrypt)${C_RST}"
hr
info "Log desta execução: $LOG_FILE"
[[ $EUID -eq 0 ]] || die "rode como root (sudo bash $0)"

# ---------- detecção de SO ----------------------------------------------------
OS_FAMILY=""    # debian | rhel
OS_PRETTY=""
OS_ID=""
OS_VERSION_ID=""
PKG_MGR=""
COMPAT="unknown"

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    OS_PRETTY="${PRETTY_NAME:-${NAME:-desconhecido}}"
    OS_ID="${ID:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
    case " ${ID:-} ${ID_LIKE:-} " in
        *" debian "*|*" ubuntu "*) OS_FAMILY="debian" ;;
        *" rhel "*|*" centos "*|*" fedora "*|*" rocky "*|*" almalinux "*|*" ol "*)
            OS_FAMILY="rhel" ;;
    esac
fi
if [[ -z "$OS_FAMILY" ]]; then
    if   command -v apt-get >/dev/null 2>&1; then OS_FAMILY="debian"
    elif command -v dnf     >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then OS_FAMILY="rhel"
    fi
fi
[[ -n "$OS_FAMILY" ]] || die "não consegui identificar a família do SO. Suportados: Debian/Ubuntu e RHEL/CentOS/Rocky/Alma/Fedora."

if [[ "$OS_FAMILY" == "debian" ]]; then
    PKG_MGR="apt-get"
else
    if command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf"; else PKG_MGR="yum"; fi
fi

case "${OS_ID}_${OS_VERSION_ID%%.*}" in
    debian_11|debian_12|ubuntu_20|ubuntu_22|ubuntu_24)    COMPAT="ok" ;;
    centos_8|centos_9|rocky_8|rocky_9|almalinux_8|almalinux_9|rhel_8|rhel_9) COMPAT="ok" ;;
    fedora_*) COMPAT="ok" ;;
    centos_7) COMPAT="partial" ;;
    *)        COMPAT="untested" ;;
esac

info "Sistema operacional: ${C_BLD}${OS_PRETTY}${C_RST}"
info "Família/gerenciador: ${OS_FAMILY} / ${PKG_MGR}"
case "$COMPAT" in
    ok)        ok   "Compatibilidade: TESTADO" ;;
    partial)   warn "Compatibilidade: PARCIAL — pode haver problemas (pacotes antigos / EOL)" ;;
    untested)  warn "Compatibilidade: NÃO TESTADO neste SO — proceda com cautela" ;;
    *)         warn "Compatibilidade: desconhecida" ;;
esac
if [[ "$COMPAT" == "partial" || "$COMPAT" == "untested" ]]; then
    confirm "Continuar mesmo assim?" || die "abortado pelo usuário"
fi

# ---------- helpers de webserver ---------------------------------------------
pkg_install() {
    if [[ "$OS_FAMILY" == "debian" ]]; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
    else
        if ! rpm -q epel-release >/dev/null 2>&1; then
            $PKG_MGR install -y epel-release 2>/dev/null || true
        fi
        $PKG_MGR install -y "$@"
    fi
}

pick_webserver() {
    local has_apache="no" has_nginx="no"
    if   command -v apache2 >/dev/null 2>&1; then has_apache="yes"
    elif command -v httpd   >/dev/null 2>&1; then has_apache="yes"
    fi
    command -v nginx >/dev/null 2>&1 && has_nginx="yes"

    if [[ -z "$WEBSERVER" ]]; then
        if   [[ "$has_apache" == "yes" && "$has_nginx" == "no"  ]]; then WEBSERVER="apache"; info "Webserver detectado: Apache"
        elif [[ "$has_apache" == "no"  && "$has_nginx" == "yes" ]]; then WEBSERVER="nginx";  info "Webserver detectado: Nginx"
        elif [[ "$has_apache" == "yes" && "$has_nginx" == "yes" ]]; then
            warn "Apache e Nginx instalados — qual usar?"
            WEBSERVER="$(menu 'Webserver alvo:' 'apache|nginx')"
        else
            info "Nenhum webserver instalado."
            WEBSERVER="$(menu 'Qual webserver instalar?' 'apache|nginx')"
        fi
    fi
    [[ "$WEBSERVER" == "apache" || "$WEBSERVER" == "nginx" ]] || die "webserver inválido: $WEBSERVER (use apache ou nginx)"

    if [[ "$WEBSERVER" == "apache" ]]; then
        WS_NAME="apache"; WS_CB_FLAG="--apache"; WS_CB_PKG="python3-certbot-apache"
        if [[ "$OS_FAMILY" == "debian" ]]; then
            WS_PKG="apache2"; WS_SERVICE="apache2"
        else
            WS_PKG="httpd";   WS_SERVICE="httpd"
        fi
    else
        WS_NAME="nginx"; WS_CB_FLAG="--nginx"; WS_CB_PKG="python3-certbot-nginx"
        WS_PKG="nginx";  WS_SERVICE="nginx"
    fi
}

install_webserver_if_needed() {
    if command -v "$WS_SERVICE" >/dev/null 2>&1 \
       || systemctl list-unit-files "${WS_SERVICE}.service" >/dev/null 2>&1; then
        return 0
    fi
    warn "${WS_PKG} não está instalado."
    if [[ "$INSTALL_WS_AUTO" == "yes" ]] || confirm "Instalar ${WS_PKG} agora?"; then
        info "Instalando ${WS_PKG}..."
        pkg_install "$WS_PKG"
        systemctl enable --now "$WS_SERVICE"
        ok "${WS_PKG} instalado e ativo."
    else
        die "abortado — instale ${WS_PKG} manualmente e rode de novo."
    fi
}

ensure_webserver_running() {
    systemctl is-active --quiet "$WS_SERVICE" && return 0
    warn "${WS_SERVICE} não está ativo — tentando iniciar..."
    systemctl start "$WS_SERVICE" || die "falha ao iniciar ${WS_SERVICE} (veja 'systemctl status ${WS_SERVICE}')"
}

# ---------- firewall ----------------------------------------------------------
FIREWALL_KIND="none"
detect_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        FIREWALL_KIND="ufw"
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        FIREWALL_KIND="firewalld"
    fi
}
firewall_is_blocking_web() {
    case "$FIREWALL_KIND" in
        ufw)
            ! ufw status 2>/dev/null | grep -qE "^(80|443)/tcp[[:space:]]+ALLOW" ;;
        firewalld)
            local zone; zone="$(firewall-cmd --get-default-zone 2>/dev/null)"
            local svcs; svcs="$(firewall-cmd --zone="$zone" --list-services 2>/dev/null)"
            ! echo "$svcs" | grep -qw http || ! echo "$svcs" | grep -qw https ;;
        *)  return 1 ;;
    esac
}
firewall_open_web() {
    case "$FIREWALL_KIND" in
        ufw)
            ufw allow 80/tcp  || true
            ufw allow 443/tcp || true
            ok "UFW: 80/443 liberados." ;;
        firewalld)
            firewall-cmd --permanent --add-service=http  || true
            firewall-cmd --permanent --add-service=https || true
            firewall-cmd --reload
            ok "firewalld: http/https liberados." ;;
    esac
}

# ---------- por-webserver: paths + writers ------------------------------------
apache_vhost_path() {
    if [[ "$OS_FAMILY" == "debian" ]]; then
        echo "/etc/apache2/sites-available/${1}.conf"
    else
        echo "/etc/httpd/conf.d/${1}.conf"
    fi
}
nginx_vhost_path() {
    if [[ -d /etc/nginx/sites-available ]]; then
        echo "/etc/nginx/sites-available/${1}.conf"
    else
        echo "/etc/nginx/conf.d/${1}.conf"
    fi
}
apache_write_vhost() {
    local primary="${DOMAINS[0]}"
    {
        echo "<VirtualHost *:80>"
        echo "    ServerName ${primary}"
        for d in "${DOMAINS[@]:1}"; do echo "    ServerAlias ${d}"; done
        [[ -n "$DOCUMENT_ROOT" ]] && echo "    DocumentRoot ${DOCUMENT_ROOT}"
        [[ -n "$REDIRECT_ROOT" ]] && echo "    RedirectMatch ^/\$ ${REDIRECT_ROOT}"
        if [[ -n "$DOCUMENT_ROOT" ]]; then
            echo "    <Directory ${DOCUMENT_ROOT}>"
            echo "        Options FollowSymLinks"
            echo "        AllowOverride All"
            echo "        Require all granted"
            echo "    </Directory>"
        fi
        if [[ "$OS_FAMILY" == "debian" ]]; then
            echo "    ErrorLog  \${APACHE_LOG_DIR}/${primary}_error.log"
            echo "    CustomLog \${APACHE_LOG_DIR}/${primary}_access.log combined"
        else
            echo "    ErrorLog  /var/log/httpd/${primary}_error.log"
            echo "    CustomLog /var/log/httpd/${primary}_access.log combined"
        fi
        echo "</VirtualHost>"
    } > "$WS_VHOST_FILE"
}
nginx_write_vhost() {
    local primary="${DOMAINS[0]}"
    {
        echo "server {"
        echo "    listen 80;"
        echo "    listen [::]:80;"
        echo "    server_name ${DOMAINS[*]};"
        [[ -n "$DOCUMENT_ROOT" ]] && echo "    root ${DOCUMENT_ROOT};"
        if [[ -n "$REDIRECT_ROOT" ]]; then
            echo "    location = / { return 301 ${REDIRECT_ROOT}; }"
        fi
        if [[ -n "$DOCUMENT_ROOT" ]]; then
            echo "    location / { try_files \$uri \$uri/ =404; }"
        fi
        echo "    access_log /var/log/nginx/${primary}_access.log;"
        echo "    error_log  /var/log/nginx/${primary}_error.log;"
        echo "}"
    } > "$WS_VHOST_FILE"
    if [[ "$WS_VHOST_FILE" == /etc/nginx/sites-available/* ]]; then
        ln -sfn "$WS_VHOST_FILE" "/etc/nginx/sites-enabled/${primary}.conf"
    fi
}
apache_enable_site() {
    if [[ "$OS_FAMILY" == "debian" ]]; then
        local primary="${DOMAINS[0]}"
        [[ -L "/etc/apache2/sites-enabled/${primary}.conf" ]] || a2ensite "${primary}" >/dev/null
    fi
}
nginx_enable_site() { :; }
ws_configtest() {
    if [[ "$WS_NAME" == "apache" ]]; then
        if [[ "$OS_FAMILY" == "debian" ]]; then apache2ctl configtest 2>&1 | sed 's/^/    /'
        else                                     httpd     -t           2>&1 | sed 's/^/    /'
        fi
    else
        nginx -t 2>&1 | sed 's/^/    /'
    fi
}
ws_reload() { systemctl reload "$WS_SERVICE"; }

apache_apply_hsts() {
    local primary="${DOMAINS[0]}"
    local ssl_conf=""
    if [[ "$OS_FAMILY" == "debian" ]]; then
        ssl_conf="/etc/apache2/sites-available/${primary}-le-ssl.conf"
    else
        ssl_conf="$WS_VHOST_FILE"
    fi
    [[ -f "$ssl_conf" ]] || { warn "conf SSL não encontrado em ${ssl_conf} — HSTS não aplicado"; return; }
    grep -q "Strict-Transport-Security" "$ssl_conf" && { ok "HSTS já presente."; return; }
    if [[ "$OS_FAMILY" == "debian" ]]; then a2enmod headers >/dev/null 2>&1 || true; fi
    sed -i "/ServerName ${primary//./\\.}/a \    Header always set Strict-Transport-Security \"max-age=31536000; includeSubDomains\"\n    Header always set X-Content-Type-Options \"nosniff\"" "$ssl_conf"
    ws_configtest; ws_reload
    ok "HSTS ativado em ${ssl_conf}."
}
nginx_apply_hsts() {
    [[ -f "$WS_VHOST_FILE" ]] || { warn "vhost não encontrado — HSTS não aplicado"; return; }
    grep -q "Strict-Transport-Security" "$WS_VHOST_FILE" && { ok "HSTS já presente."; return; }
    if grep -qE 'listen[[:space:]]+443' "$WS_VHOST_FILE"; then
        sed -i '/listen[[:space:]]\+443/a \    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;\n    add_header X-Content-Type-Options "nosniff" always;' "$WS_VHOST_FILE"
        ws_configtest; ws_reload
        ok "HSTS ativado em ${WS_VHOST_FILE}."
    else
        warn "não achei bloco 'listen 443' — certbot não rodou? HSTS não aplicado."
    fi
}
ws_apply_hsts() {
    if [[ "$WS_NAME" == "apache" ]]; then apache_apply_hsts
    else                                   nginx_apply_hsts
    fi
}

# =============================================================================
# FLUXO PRINCIPAL
# =============================================================================

pick_webserver
install_webserver_if_needed
ensure_webserver_running
detect_firewall

# ---------- coleta interativa -------------------------------------------------
if [[ ${#DOMAINS[@]} -eq 0 ]]; then
    echo
    info "Informe o domínio (FQDN, sem https://). Ex: app.example.com.br"
    primary="$(prompt 'Domínio principal')"
    [[ -n "$primary" ]] || die "domínio é obrigatório"
    DOMAINS+=("$primary")
    while confirm "Adicionar outro domínio/alias ao mesmo certificado (ex: www.${primary})?"; do
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
    info "O que carregar quando alguém abrir https://${DOMAINS[0]}/ ?"
    info "  - Vazio (Enter) = serve o que o webserver já serve hoje em /"
    info "  - Path /xxx/    = redireciona /  →  /xxx/  (ex: /zabbix/, /grafana/)"
    sug=""
    if [[ -f /etc/apache2/conf-enabled/zabbix.conf ]] || [[ -f /etc/httpd/conf.d/zabbix.conf ]]; then
        sug="/zabbix/"
        info "${C_YLW}detectei zabbix.conf — sugerindo /zabbix/${C_RST}"
    fi
    REDIRECT_ROOT="$(prompt 'Redirect raiz para' "$sug")"
fi
if [[ -n "$REDIRECT_ROOT" ]]; then
    [[ "$REDIRECT_ROOT" =~ ^/ ]] || REDIRECT_ROOT="/$REDIRECT_ROOT"
    [[ "$REDIRECT_ROOT" =~ /$ ]] || REDIRECT_ROOT="$REDIRECT_ROOT/"
fi

if [[ -z "$DOCUMENT_ROOT" ]] && [[ -z "$REDIRECT_ROOT" ]] && [[ "$ASSUME_YES" != "yes" ]]; then
    echo
    info "DocumentRoot do VHost (deixe vazio para usar o default). Ex: /var/www/app"
    DOCUMENT_ROOT="$(prompt 'DocumentRoot' '')"
fi
[[ -n "$DOCUMENT_ROOT" && ! -d "$DOCUMENT_ROOT" ]] && warn "DocumentRoot ${DOCUMENT_ROOT} não existe ainda."

if [[ "$ENABLE_HSTS" == "no" ]] && [[ "$ASSUME_YES" != "yes" ]]; then
    echo
    confirm "Ativar HSTS (Strict-Transport-Security) no HTTPS?" && ENABLE_HSTS="yes"
fi

# ---------- DNS ---------------------------------------------------------------
echo
info "Validando DNS..."
PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
            || curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null \
            || true)"
info "  IP público desta máquina: ${PUBLIC_IP:-desconhecido}"
DNS_PROBLEMS=0
for d in "${DOMAINS[@]}"; do
    ips="$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
    if [[ -z "$ips" ]]; then
        err "  ${d}: DNS NÃO resolve (verifique o registro A)"
        DNS_PROBLEMS=$((DNS_PROBLEMS+1)); continue
    fi
    if [[ -n "$PUBLIC_IP" ]] && ! echo "$ips" | grep -qw "$PUBLIC_IP"; then
        warn "  ${d} -> ${ips} (não bate com IP público ${PUBLIC_IP})"
        DNS_PROBLEMS=$((DNS_PROBLEMS+1))
    else
        ok   "  ${d} -> ${ips}"
    fi
done
if [[ $DNS_PROBLEMS -gt 0 ]]; then
    warn "${DNS_PROBLEMS} domínio(s) com problema de DNS — certbot pode falhar."
    confirm "Continuar?" || die "abortado"
fi

# ---------- vhost path / duplicado -------------------------------------------
PRIMARY="${DOMAINS[0]}"
if [[ "$WS_NAME" == "apache" ]]; then WS_VHOST_FILE="$(apache_vhost_path "$PRIMARY")"
else                                  WS_VHOST_FILE="$(nginx_vhost_path  "$PRIMARY")"
fi

DUP_SEARCH_DIRS=()
[[ -d /etc/apache2/sites-enabled ]] && DUP_SEARCH_DIRS+=(/etc/apache2/sites-enabled)
[[ -d /etc/httpd/conf.d         ]] && DUP_SEARCH_DIRS+=(/etc/httpd/conf.d)
[[ -d /etc/nginx/sites-enabled  ]] && DUP_SEARCH_DIRS+=(/etc/nginx/sites-enabled)
[[ -d /etc/nginx/conf.d         ]] && DUP_SEARCH_DIRS+=(/etc/nginx/conf.d)
if [[ ${#DUP_SEARCH_DIRS[@]} -gt 0 ]]; then
    DUP="$(grep -rlE "(server_name|ServerName)[[:space:]]+${PRIMARY//./\\.}\b" "${DUP_SEARCH_DIRS[@]}" 2>/dev/null \
           | grep -v -F "$WS_VHOST_FILE" || true)"
    if [[ -n "$DUP" ]]; then
        warn "Já existe(m) vhost(s) com ${PRIMARY}:"
        echo "$DUP" | sed 's/^/    /'
        confirm "Continuar mesmo assim?" || die "abortado — desabilite o conflitante e rode de novo"
    fi
fi

# ---------- firewall ----------------------------------------------------------
if [[ "$FIREWALL_KIND" != "none" ]] && firewall_is_blocking_web; then
    warn "Firewall (${FIREWALL_KIND}) parece NÃO permitir 80/443."
    if [[ "$OPEN_FIREWALL" == "yes" ]] || confirm "Abrir 80/443 no ${FIREWALL_KIND} agora?"; then
        firewall_open_web
    fi
fi

# ---------- resumo + confirma ------------------------------------------------
echo
hr
log "${C_BLD}Resumo:${C_RST}"
log "  SO              : ${OS_PRETTY} (${OS_FAMILY})"
log "  Webserver       : ${WS_NAME} (serviço: ${WS_SERVICE})"
log "  Domínios        : ${DOMAINS[*]}"
log "  E-mail LE       : $EMAIL"
log "  Redirect raiz   : ${REDIRECT_ROOT:-(nenhum)}"
log "  DocumentRoot    : ${DOCUMENT_ROOT:-(default)}"
log "  HTTP->HTTPS     : $HTTP_REDIRECT"
log "  HSTS            : $ENABLE_HSTS"
log "  Staging         : $USE_STAGING"
log "  Firewall        : $FIREWALL_KIND"
log "  Vhost           : $WS_VHOST_FILE"
log "  IP público      : ${PUBLIC_IP:-?}"
hr
confirm "Prosseguir?" || die "abortado"

# ---------- rollback infra ---------------------------------------------------
BACKUP_TAG="$(date +%Y%m%d-%H%M%S)"
ROLLBACK_CMDS=()
add_rollback() { ROLLBACK_CMDS+=("$1"); }
do_rollback()  {
    warn "Executando rollback..."
    for (( i=${#ROLLBACK_CMDS[@]}-1; i>=0; i-- )); do
        bash -c "${ROLLBACK_CMDS[$i]}" || true
    done
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then err "falha (exit $rc) — revertendo"; do_rollback; fi' EXIT

# ---------- [1/6] certbot -----------------------------------------------------
echo
info "[1/6] Instalando certbot + plugin ${WS_NAME}"
if command -v certbot >/dev/null 2>&1; then
    ok "  certbot já instalado: $(certbot --version 2>&1)"
else
    pkg_install certbot "$WS_CB_PKG"
    ok "  certbot instalado: $(certbot --version 2>&1)"
fi

# ---------- [2/6] VHost -------------------------------------------------------
echo
info "[2/6] Escrevendo VHost ${WS_VHOST_FILE}"
mkdir -p "$(dirname "$WS_VHOST_FILE")"
if [[ -f "$WS_VHOST_FILE" ]]; then
    backup="${WS_VHOST_FILE}.bak.${BACKUP_TAG}"
    cp -a "$WS_VHOST_FILE" "$backup"
    info "  já existia — backup em ${backup}"
    add_rollback "mv -f '$backup' '$WS_VHOST_FILE'"
else
    add_rollback "rm -f '$WS_VHOST_FILE'"
fi
if [[ "$WS_NAME" == "apache" ]]; then apache_write_vhost
else                                  nginx_write_vhost
fi
ws_configtest

# ---------- [3/6] enable + reload --------------------------------------------
echo
info "[3/6] Habilitando site e recarregando ${WS_SERVICE}"
if [[ "$WS_NAME" == "apache" ]]; then apache_enable_site
else                                  nginx_enable_site
fi
add_rollback "if [[ '$WS_NAME' == apache && '$OS_FAMILY' == debian ]]; then a2dissite '$PRIMARY' >/dev/null 2>&1 || true; fi; \
              if [[ '$WS_NAME' == nginx ]]; then rm -f '/etc/nginx/sites-enabled/${PRIMARY}.conf'; fi; \
              systemctl reload $WS_SERVICE || true"
ws_reload
ok "  ${WS_SERVICE} recarregado."

# ---------- [4/6] certbot run -------------------------------------------------
echo
info "[4/6] Solicitando certificado Let's Encrypt (HTTP-01 / plugin ${WS_NAME})"
CERTBOT_ARGS=("$WS_CB_FLAG" -m "$EMAIL" --non-interactive --agree-tos --keep-until-expiring)
for d in "${DOMAINS[@]}"; do CERTBOT_ARGS+=(-d "$d"); done
[[ "$HTTP_REDIRECT" == "yes" ]] && CERTBOT_ARGS+=(--redirect) || CERTBOT_ARGS+=(--no-redirect)
[[ "$USE_STAGING"   == "yes" ]] && CERTBOT_ARGS+=(--staging)
certbot "${CERTBOT_ARGS[@]}"
add_rollback "certbot delete --cert-name '${PRIMARY}' --non-interactive >/dev/null 2>&1 || true"

# ---------- [5/6] HSTS --------------------------------------------------------
echo
if [[ "$ENABLE_HSTS" == "yes" ]]; then
    info "[5/6] Aplicando HSTS"
    ws_apply_hsts
else
    info "[5/6] HSTS: pulado (não solicitado)"
fi

# ---------- [6/6] validação ---------------------------------------------------
echo
info "[6/6] Validando endpoints"
hr
for d in "${DOMAINS[@]}"; do
    echo "  http://${d}/ :"
    curl -sI --max-time 10 "http://${d}/"  | head -3 | sed 's/^/      /' || warn "  curl HTTP falhou em ${d}"
    echo "  https://${d}/ :"
    curl -sI --max-time 10 "https://${d}/" | head -3 | sed 's/^/      /' || warn "  curl HTTPS falhou em ${d}"
done
if [[ -n "$REDIRECT_ROOT" ]]; then
    echo "  https://${PRIMARY}${REDIRECT_ROOT} :"
    curl -sI --max-time 10 "https://${PRIMARY}${REDIRECT_ROOT}" | head -3 | sed 's/^/      /' || true
fi
hr

echo
info "Renovação automática:"
systemctl list-timers --no-pager 2>/dev/null | grep -E "certbot|snap\.certbot" | sed 's/^/    /' \
    || warn "  não achei timer de certbot — verifique 'systemctl list-timers' / 'crontab -l' manualmente"

echo
info "Lista de certificados emitidos:"
certbot certificates 2>/dev/null | sed 's/^/    /' || true

trap - EXIT
echo
ok "${C_BLD}Concluído com sucesso.${C_RST}"
echo
echo "  Revogar cert:        sudo certbot delete --cert-name ${PRIMARY}"
echo "  Desabilitar site:    sudo rm ${WS_VHOST_FILE} && sudo systemctl reload ${WS_SERVICE}"
[[ "$OS_FAMILY" == debian && "$WS_NAME" == apache ]] && \
    echo "                       (ou: sudo a2dissite ${PRIMARY} && sudo systemctl reload apache2)"
echo "  Renovar manualmente: sudo certbot renew"
echo "  Log execução:        ${LOG_FILE}"
