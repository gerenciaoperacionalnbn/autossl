# autossl

Script Bash que instala um certificado **Let's Encrypt** e configura **HTTPS** em um servidor Linux com **Apache**. Pensado para o operador rodar uma única vez por domínio, com perguntas guiadas e rollback automático em caso de falha.

## Pré-requisito (responsabilidade do operador)

Antes de rodar o script:

1. O domínio (registro **A** no DNS) precisa apontar para o **IP público** do servidor onde o script vai rodar. Aguarde a propagação (`dig A seudominio.com.br` deve retornar o IP correto).
2. Portas **80** e **443** acessíveis pela Internet (firewall, NAT, security group em cloud).

## Uso rápido (interativo)

No servidor onde você quer ativar o HTTPS:

```bash
curl -fsSL https://raw.githubusercontent.com/gerenciaoperacionalnbn/autossl/main/autossl.sh -o /tmp/autossl.sh
sudo bash /tmp/autossl.sh
```

O script vai perguntar:
- domínio principal (e opcionalmente domínios adicionais, ex: `www.…`)
- e-mail de contato para o Let's Encrypt (recebe avisos de expiração)
- se a raiz `/` deve redirecionar para um subdiretório (`/zabbix/`, `/grafana/`, …) — útil quando a aplicação já mora num subpath
- DocumentRoot customizado (se a aplicação serve direto na raiz)
- se quer ativar HSTS
- se quer abrir 80/443 no UFW (se houver firewall ativo bloqueando)

E faz tudo: instala `certbot`, cria o VirtualHost, habilita, recarrega o Apache, emite o cert, força HTTP→HTTPS, valida com `curl`, e mostra o timer de renovação automática.

## Uso não-interativo (CI / automação)

```bash
sudo bash /tmp/autossl.sh \
    -d app.example.com.br \
    -d www.app.example.com.br \
    --email admin@example.com.br \
    --redirect-root /zabbix/ \
    --hsts --open-firewall --yes
```

## Flags

| Flag | O que faz |
|---|---|
| `-d, --domain DOM`     | domínio (pode repetir; o primeiro é o principal, os demais viram `ServerAlias` e entram no SAN do cert) |
| `--email EMAIL`        | e-mail da conta Let's Encrypt |
| `--redirect-root PATH` | `/` → `PATH` (ex: `/zabbix/`). Vazio = não redireciona |
| `--document-root DIR`  | `DocumentRoot` do VHost (ex: `/var/www/app`) |
| `--staging`            | usa staging do Let's Encrypt (cert não confiável, ideal para teste) |
| `--no-http-redirect`   | NÃO força redirect HTTP → HTTPS (default: força) |
| `--hsts`               | adiciona HSTS no VHost SSL após emitir o cert |
| `--open-firewall`      | abre 80/443/tcp no UFW se UFW estiver ativo |
| `--install-apache`     | instala `apache2` se ausente (sem perguntar) |
| `-y, --yes`            | não pede nenhuma confirmação |
| `-h, --help`           | ajuda completa |

## O que o script faz por dentro

1. **Preflight** — verifica root, distro (Debian/Ubuntu), Apache ativo, certbot, conectividade.
2. **Validação DNS** — resolve cada domínio e compara com o IP público da máquina; avisa antes de seguir se não bate.
3. **VirtualHost duplicado** — procura por `ServerName` igual em outros sites ativos e pede confirmação antes de seguir.
4. **VirtualHost HTTP** — escreve `/etc/apache2/sites-available/<domínio>.conf`, `a2ensite`, `apache2ctl configtest`, `systemctl reload apache2`.
5. **Certbot** — `certbot --apache -d ... --redirect --keep-until-expiring`. Idempotente: re-rodar com o mesmo domínio reaproveita o certificado existente.
6. **HSTS opcional** — injeta `Strict-Transport-Security` e `X-Content-Type-Options` no VHost SSL gerado pelo certbot, habilita `mod_headers`.
7. **Validação final** — `curl -sI` em HTTP, HTTPS e (se houver redirect-root) no path final.
8. **Rollback automático** — em qualquer falha, reverte na ordem inversa: restaura backup do conf, `a2dissite`, `certbot delete`.

Log de cada execução fica em `/var/log/setup_apache_letsencrypt.log`.

## Renovação

O pacote `certbot` no Debian/Ubuntu já vem com um timer systemd que renova automaticamente (`systemctl list-timers | grep certbot`). O script só mostra o status no final — não precisa fazer mais nada.

Para forçar uma renovação manual: `sudo certbot renew`.

## Para remover

```bash
sudo certbot delete --cert-name <dominio>
sudo a2dissite <dominio>
sudo rm /etc/apache2/sites-available/<dominio>.conf
sudo systemctl reload apache2
```

## Licença

MIT — veja [`LICENSE`](LICENSE).
