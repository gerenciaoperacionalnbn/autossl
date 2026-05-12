# autossl

Script Bash que instala um certificado **Let's Encrypt** (ou ZeroSSL) e configura **HTTPS** em um servidor Linux com **Apache** ou **Nginx**. Detecta o SO, o webserver, e o cenário de DNS — escolhe automaticamente entre HTTP-01 e DNS-01 conforme o caso.

Funciona em Debian/Ubuntu **e** em RHEL/CentOS/Rocky/Alma/Fedora. Cobre dois cenários:

- **Domínio público** (acesso pela Internet) → `certbot` + HTTP-01
- **Domínio aponta pra IP privado** (intranet/NAT/VPN) → `acme.sh` + DNS-01 via API do cPanel do provedor DNS (cria/remove o TXT `_acme-challenge` sozinho — sem clicar e-mail, sem editar DNS manual)

## Pré-requisito

Antes de rodar:

1. O domínio (registro **A** no DNS) precisa apontar pra um IP (público OU privado, conforme o caso).
2. Se o caso é HTTP-01: portas **80** e **443** acessíveis pela Internet.
3. Se o caso é DNS-01 cPanel: credenciais cPanel do provedor DNS (`CPANEL_USERNAME`, `CPANEL_APITOKEN`, `CPANEL_HOSTNAME`). Pode passar por env var ou deixar o script perguntar (token via `read -s`, sem echo).

Depois disso, o script decide e faz o resto.

## Compatibilidade

| Distribuição | Status | Notas |
|---|---|---|
| Debian 11 / 12 | ✅ testado | apt |
| Ubuntu 20.04 / 22.04 / 24.04 | ✅ testado | apt |
| CentOS Stream 8 / 9 | ✅ testado | dnf, certbot via EPEL |
| Rocky / AlmaLinux 8 / 9 | ✅ testado | dnf, certbot via EPEL |
| RHEL 8 / 9 | ✅ testado | dnf, certbot via EPEL |
| Fedora (recente) | ✅ testado | dnf |
| CentOS 7 | ⚠️ parcial | EOL — pode funcionar, sem garantia |
| Outras | ❓ untested | script tenta detectar; pergunta antes de seguir |

Webservers: **Apache** (`apache2` no Debian/Ubuntu, `httpd` no RHEL family) e **Nginx**.

## Uso rápido (interativo)

No servidor onde você quer ativar o HTTPS:

```bash
curl -fsSL https://raw.githubusercontent.com/gerenciaoperacionalnbn/autossl/main/autossl.sh -o /tmp/autossl.sh
sudo bash /tmp/autossl.sh
```

O script vai:
1. Identificar o SO e dizer se é compatível.
2. Detectar Apache/Nginx — se nenhum estiver instalado, perguntar qual instalar.
3. Pedir domínio (e domínios adicionais, ex: `www.…`), e-mail, redirect raiz, DocumentRoot, HSTS.
4. Validar DNS contra o IP público desta máquina.
5. Avisar de VirtualHost duplicado e de firewall fechado (UFW/firewalld) com opção de abrir.
6. Mostrar resumo final, pedir confirmação, e executar tudo.

Em qualquer falha → **rollback automático** (backup do conf restaurado, site desabilitado, cert deletado).

## Uso não-interativo — HTTP-01 (DNS público)

```bash
sudo bash /tmp/autossl.sh \
    --webserver apache \
    -d app.example.com.br \
    -d www.app.example.com.br \
    --email admin@example.com.br \
    --redirect-root /zabbix/ \
    --hsts --open-firewall --yes
```

## Uso não-interativo — DNS-01 cPanel (intranet, IP privado)

```bash
export CPANEL_USERNAME='...'
export CPANEL_APITOKEN='...'
export CPANEL_HOSTNAME='https://canopus.prodns.com.br:2083'

sudo -E bash /tmp/autossl.sh \
    --method acme-sh-cpanel \
    -d intra.example.com.br \
    --email admin@example.com.br \
    --document-root /var/www/intra --yes
```

> Use `sudo -E` para o sudo preservar as env vars `CPANEL_*`.

## Flags

| Flag | O que faz |
|---|---|
| `--method M`                | `auto` (default) \| `certbot-http01` \| `acme-sh-cpanel`. Em `auto`, o script decide pelo DNS: se o domínio só resolve pra IP privado → `acme-sh-cpanel`; senão → `certbot-http01` |
| `--ca CA`                   | `letsencrypt` (default) \| `zerossl`. ZeroSSL em conta nova frequentemente devolve `retry_after=86400`; o script faz fallback automático pra LE nesse caso |
| `--webserver apache\|nginx` | força um webserver (default: detecta/pergunta) |
| `-d, --domain DOM`          | domínio (pode repetir; o primeiro é o principal; os demais viram `ServerAlias`/`server_name` extra e entram no SAN do cert) |
| `--email EMAIL`             | e-mail da conta da CA |
| `--redirect-root PATH`      | `/` → `PATH` (ex: `/zabbix/`). Vazio = não redireciona |
| `--document-root DIR`       | `DocumentRoot` (Apache) ou `root` (Nginx) do VHost |
| `--staging`                 | usa staging do Let's Encrypt — só vale com `--method certbot-http01` |
| `--no-http-redirect`        | NÃO força redirect HTTP→HTTPS (default: força) |
| `--hsts`                    | adiciona HSTS no VHost SSL após emitir o cert |
| `--open-firewall`           | abre 80/443/tcp no UFW **ou** http/https no firewalld se ativos |
| `--install-webserver`       | instala o webserver escolhido sem perguntar |
| `--certbot-method M`        | `auto` (default) \| `pkg` \| `snap` \| `keep`. Em SO antigos como CentOS 7 a fallback automática é `snap` (o script detecta e oferece) |
| `-y, --yes`                 | não pede nenhuma confirmação |
| `-h, --help`                | ajuda completa |

## Credenciais cPanel (modo `acme-sh-cpanel`)

Necessárias só nesse modo. Três jeitos seguros de fornecer (o script tenta nessa ordem):

1. **Env vars** antes do `sudo`:
   ```bash
   export CPANEL_USERNAME='...'
   export CPANEL_APITOKEN='...'
   export CPANEL_HOSTNAME='https://provedor.cpanel:2083'
   sudo -E bash autossl.sh --method acme-sh-cpanel ...
   ```
2. **Já salvas** em `/root/.acme.sh/account.conf` (segunda emissão na mesma máquina). Script detecta `SAVED_cPanel_Username=` e nem pergunta.
3. **Prompt interativo**. Username e Hostname aparecem na tela; o **token NÃO** (usa `read -s`, sem echo, fora do scrollback).

⚠️ **NÃO existe flag `--cpanel-token`.** Foi de propósito: flags vazariam no histórico do shell. Use uma das três rotas acima.

## O que o script faz por dentro

1. **Detecta SO** via `/etc/os-release` (família + versão) e mostra status de compatibilidade.
2. **Escolhe o webserver** (Apache ou Nginx). Detecta o que já está instalado; se nada, pergunta.
3. **Instala o webserver** se ausente (sob confirmação) — `apt install apache2/nginx` ou `dnf install httpd/nginx`. EPEL é adicionado automaticamente em RHEL family quando preciso.
4. **Detecta firewall** ativo (UFW ou firewalld) e oferece abrir 80/443 (só relevante pra HTTP-01).
5. **Valida DNS** — resolve cada domínio, classifica (IP público correto, IP público errado, IP privado) e mostra mensagem específica pra cada caso.
6. **Decide o método** (em `--method auto`): IP privado → `acme-sh-cpanel`; senão → `certbot-http01`.
7. **Instala a ferramenta certa** — `certbot` (com fallback pra snap em SO antigo) OU `acme.sh` + deps.
8. **Detecta VHost duplicado** com mesmo `ServerName`/`server_name` em outros sites ativos.
9. **Escreve VHost** (path varia por SO e webserver — ver `/etc/apache2/sites-available/`, `/etc/httpd/conf.d/`, `/etc/nginx/sites-available/`, `/etc/nginx/conf.d/`).
10. **Roda configtest** (`apache2ctl -t` / `httpd -t` / `nginx -t`) antes de recarregar.
11. **Emite o cert**:
    - **HTTP-01**: `certbot --apache/--nginx --redirect --keep-until-expiring`
    - **DNS-01 cPanel**: `acme.sh --issue --dns dns_cpanel`, depois `--install-cert` com `--reloadcmd "systemctl reload <ws>"` (deixa renovação configurada). VHost SSL escrito manualmente.
12. **HSTS opcional** — injeta `Strict-Transport-Security` e `X-Content-Type-Options`.
13. **Validação final** — `curl -sI` em HTTP, HTTPS e (se houver redirect-root) no path final.
14. **Renovação automática** — `certbot.timer` (systemd) OU `acme.sh --cron` (crontab). Mostra o status no final.

Log de cada execução: `/var/log/autossl.log`.

## Renovação

O pacote `certbot` já vem com um timer systemd que renova automaticamente:

```bash
systemctl list-timers | grep certbot
sudo certbot renew --dry-run    # testa sem aplicar
```

## Para remover

```bash
sudo certbot delete --cert-name <dominio>
sudo rm /etc/<webserver>/<vhost-path>.conf
sudo systemctl reload <apache2|httpd|nginx>
```

(O script imprime o comando exato no final da execução.)

## Licença

MIT — veja [`LICENSE`](LICENSE).
