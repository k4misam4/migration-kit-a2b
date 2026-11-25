# migration-kit-a2b

Kit de migração de servidor para stacks **nginx + certbot + docker-compose**.

Move um servidor inteiro para outro sem perder nada do que vive só na máquina:
configurações de proxy por domínio, certificados Let's Encrypt (e as contas de
renovação), variáveis de ambiente, dados dos volumes docker, imagens built
localmente, crontabs e units systemd.

## Como funciona

1. `01-collect.sh` (servidor antigo): inventaria o estado real do servidor,
   recolhe as peças soltas e gera um `bundle.tar.gz.enc` encriptado com
   AES-256 + pbkdf2, acompanhado de um `manifest.txt` legível para revisão.
2. `02-restore.sh` (servidor novo): desencripta, instala dependências em falta,
   restaura configs e certificados com backup do que existir, clona os
   projectos do GitHub, repõe os volumes e sobe os stacks com validação
   `nginx -t`.

Desenhado para migração em duas passagens: uma preparação a quente sem parar o
servidor antigo e uma sincronização final de dados a frio, antes de virar o DNS.

## Segurança

- Pacote encriptado: `.env` e chaves privadas nunca viajam em claro.
- Permissões preservadas (`--numeric-owner`) e `.env` restaurados com `chmod 600`.
- Configs anteriores do nginx/letsencrypt guardadas em `*.pre-migracao-*`.

## Estrutura

```
migration-kit-a2b/
├── 01-collect.sh   ← SERVIDOR A (inventaria, empacota, encripta)
├── 02-restore.sh   ← SERVIDOR B (instala e valida)
├── .gitignore      ← protege bundles e segredos
├── LICENSE
└── README.md
```

---

## Plano (2 passagens — sem perder dados)

### DIA -1 — preparação (A nunca para)

1. **Baixar o TTL** dos DNS dos domínios para `300` (5 min). Só disto hoje.
2. No servidor A:
   ```bash
   sudo ./01-collect.sh
   ```
   - gera `migracao-*/bundle-*.tar.gz.enc` + `manifest.txt`
   - lê o `manifest.txt` e confirma containers/domínios/certs
3. Transferir para B:
   ```bash
   scp migracao-*/bundle-*.tar.gz.enc root@IP_B:/root/
   scp 02-restore.sh root@IP_B:/root/
   ```
4. No servidor B:
   ```bash
   sudo ./02-restore.sh bundle-*.tar.gz.enc
   ```
   - instala docker/nginx/certbot/git se faltarem
   - põe configs, certs, `.env`, volumes e sobe os stacks
5. **Testar sem tocar no DNS** — na TUA máquina:
   ```
   /etc/hosts:   IP_DO_B  dominio.com www.dominio.com
   ```
   Depois: `curl -I https://dominio.com` … todos os domínios.

### DIA 0 — viragem (downtime ≈ saltar os rsync's)

1. No A, parar os serviços (garante BD consistente):
   ```bash
   for d in /opt/*/; do (cd "$d" && docker compose down); done
   ```
2. No A, última recolha — **só dados e `.env`** (rápida):
   ```bash
   sudo ./01-collect.sh --data-only
   ```
3. Transferir e no B:
   ```bash
   sudo ./02-restore.sh --data-only bundle-data-*.tar.gz.enc
   ```
4. **Apontar os DNS** para o IP de B (TTL já está em 300s).
5. Esperar propagar; no B confirmar renovações:
   ```bash
   sudo certbot renew --dry-run
   ```
6. Manter A intacto (desligado) uns dias como fallback.

---

## O que o pacote contém

| Peça                  | Referente a                                    |
|-----------------------|------------------------------------------------|
| `nginx.tar.gz`        | `/etc/nginx` completo (sites, mime, conf.d)    |
| `letsencrypt.tar.gz`  | `/etc/letsencrypt` — certs + **contas** + renewal + hooks |
| `envs/<proj>.tar.gz`  | `.env`, `*.env`, `compose.override.yml` por projecto |
| `volumes/<vol>.tar.gz`| dados de cada volume docker                    |
| `images/*.tar`        | imagens **built localmente** (sem registry)    |
| `cron/`, `systemd/`   | crontabs e units customizadas                  |
| `projects.txt`        | `/opt/<proj>` + `git remote` de cada projecto  |
| `manifest.txt`        | inventário do A na hora da recolha             |

## Avisos onde primates costumam morder

- **Imagens pulláveis** — imagens com `/` no repositório (ex.: `redis:7`,
  `ghcr.io/…`) assumem-se pulláveis no B e ficam listadas em
  `images/pull-list.txt`. Se alguma for privada, prepara `docker login` no B.
- **Builds locais** — projectos com `build:` no compose produzem imagens
  `<projecto>-<serviço>`; o collect grava-as. Se o compose usar `image:` com
  nome diferente do gerado, confere no `docker images` do manifest.
- **Nomes das pastas** — os vols do compose têm prefixo do nome da pasta em
  `/opt`. **Mantém os mesmos nomes de pastas** no B, senão os volumes não
  emparelham.
- **Redes externas** — se algum compose declara `external: true`, cria-a no B:
  `docker network create <nome>`.
- **Binds a caminhos fora de `/opt`** (ex.: `/var/www/uploads`) — o collect
  não os leva. Copia à parte rsync.
- **Firewall do B** — cloud security groups + `ufw allow 'Nginx Full'`.
- **E-mail/DNS dos certbot** — o renewal lê `/etc/letsencrypt/renewal/*`; o
  `--dry-run` confirma tudo depois do DNS virar.

## Testes antes de confiar

Esta é ferramenta para a tua própria migração: **testa primeiro num servidor
de testes** (ou noutro directório), não no A em produção. O `02-restore.sh`
corrige/substitui `/etc/nginx` e `/etc/letsencrypt` — faz backup no host B
antes de qualquer coisa aí.
