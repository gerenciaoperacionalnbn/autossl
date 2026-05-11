# autossl

Script Bash que instala um certificado **Let's Encrypt** e configura **HTTPS** em um servidor Linux com **Apache** ou **Nginx**. Detecta o SO e o webserver, instala o que faltar (com confirmação), e termina com tudo validado.

Funciona em Debian/Ubuntu **e** em RHEL/CentOS/Rocky/Alma/Fedora — o script escolhe o pacote certo (`apt-get` ou `dnf`), o serviço certo (`apache2` vs `httpd`, ou `nginx`) e o plugin certo do certbot, sem você precisar pensar nisso.

## Pré-requisito (responsabilidade do operador)

Antes de rodar:

1. O domínio (registro **A** no DNS) precisa apontar para o **IP público** do servidor. Aguarde a propagação (`dig A seudominio.com.br` deve retornar o IP correto).
2. Portas **80** e **443** acessíveis pela Internet (firewall, NAT, security group em cloud).

Depois disso, o script faz o resto.

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

## Uso não-interativo (CI / automação)

```bash
sudo bash /tmp/autossl.sh \
    --webserver apache \
    -d app.example.com.br \
    -d www.app.example.com.br \
    --email admin@example.com.br \
    --redirect-root /zabbix/ \
    --hsts --open-firewall --yes
```

## Flags

| Flag | O que faz |
|---|---|
| `--webserver apache\|nginx` | força um webserver (default: detecta/pergunta) |
| `-d, --domain DOM`          | domínio (pode repetir; o primeiro é o principal; os demais viram `ServerAlias`/`server_name` extra e entram no SAN do cert) |
| `--email EMAIL`             | e-mail da conta Let's Encrypt |
| `--redirect-root PATH`      | `/` → `PATH` (ex: `/zabbix/`). Vazio = não redireciona |
| `--document-root DIR`       | `DocumentRoot` (Apache) ou `root` (Nginx) do VHost |
| `--staging`                 | usa staging do Let's Encrypt — cert não confiável, ideal pra teste sem queimar rate-limit |
| `--no-http-redirect`        | NÃO força redirect HTTP→HTTPS (default: força) |
| `--hsts`                    | adiciona HSTS no VHost SSL após emitir o cert |
| `--open-firewall`           | abre 80/443/tcp no UFW **ou** http/https no firewalld se ativos |
| `--install-webserver`       | instala o webserver escolhido sem perguntar |
| `-y, --yes`                 | não pede nenhuma confirmação |
| `-h, --help`                | ajuda completa |

## O que o script faz por dentro

1. **Detecta SO** via `/etc/os-release` (família + versão) e mostra status de compatibilidade.
2. **Escolhe o webserver** (Apache ou Nginx). Detecta o que já está instalado; se nada, pergunta.
3. **Instala o webserver** se ausente (sob confirmação) — `apt install apache2/nginx` ou `dnf install httpd/nginx`. EPEL é adicionado automaticamente em RHEL family quando preciso.
4. **Detecta firewall** ativo (UFW ou firewalld) e oferece abrir 80/443.
5. **Valida DNS** — resolve cada domínio e compara com o IP público (`api.ipify.org`/`ifconfig.me`).
6. **Detecta VHost duplicado** com mesmo `ServerName`/`server_name` em outros sites ativos.
7. **Escreve VHost**:
   - Apache (Debian) → `/etc/apache2/sites-available/<dom>.conf` + `a2ensite`
   - Apache (RHEL)   → `/etc/httpd/conf.d/<dom>.conf`
   - Nginx (Debian)  → `/etc/nginx/sites-available/<dom>.conf` + symlink
   - Nginx (RHEL)    → `/etc/nginx/conf.d/<dom>.conf`
8. **Roda configtest** (`apache2ctl -t` / `httpd -t` / `nginx -t`) antes de recarregar.
9. **Emite o cert** com `certbot --apache` ou `--nginx`, `--redirect` (HTTP→HTTPS), `--keep-until-expiring` (idempotente).
10. **HSTS opcional** — injeta `Strict-Transport-Security` e `X-Content-Type-Options` no VHost SSL.
11. **Validação final** — `curl -sI` em HTTP, HTTPS e (se houver redirect-root) no path final.
12. **Renovação** — mostra o timer systemd do certbot já configurado pelo pacote.

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
