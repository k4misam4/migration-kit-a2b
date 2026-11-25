#!/usr/bin/env bash
# ============================================================================
#  02-restore.sh — instala no servidor B (novo) o pacote do 01-collect.sh
#
#  Executar como root no servidor B.
#
#  Uso:
#     sudo ./02-restore.sh bundle-XXXX.tar.gz.enc            # pacote completo
#     sudo ./02-restore.sh --data-only bundle-data.tar.gz.enc # antes do switch
#
#  O que faz:
#     - desencripta e extrai o pacote
#     - instala docker / nginx+certbot / git se faltarem (apt)
#     - restaura /etc/nginx e /etc/letsencrypt (com backup do que existir)
#     - clona os projectos do GitHub para /opt quando não existe local
#     - coloca os .env com permissão 600 no sitio certo
#     - recria os volumes docker e descompacta os dados
#     - carrega imagens built localmente (docker load)
#     - sobe os stacks com docker compose up -d
#     - valida nginx -t e arranca o nginx
# ============================================================================
set -Eeuo pipefail

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[0;32m✔\033[0m %s\n' "$*"; }
info() { printf '   \033[0;36m·\033[0m %s\n' "$*"; }
warn() { printf '   \033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERRO:\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "Falha na linha $LINENO. Conteúdo extraído em $WORK"' ERR

DATA_ONLY=0
if [[ "${1:-}" == "--data-only" ]]; then DATA_ONLY=1; shift; fi
BUNDLE="${1:-}"

[[ $EUID -eq 0 ]] || die "Corre como root:  sudo ./02-restore.sh"
[[ -n "$BUNDLE" && -f "$BUNDLE" ]] || \
  die "Uso: sudo ./02-restore.sh [--data-only] <bundle.tar.gz.enc>"

WORK="$(mktemp -d /tmp/migracao-restore.XXXXXX)"

# ----------------------------------------------------------------------------
log "1/9 · Desencriptar e extrair"
printf 'Senha do pacote: '; read -rs P; echo
PASSF="$(mktemp /tmp/.migpass.XXXXXX)"; chmod 600 "$PASSF"; printf '%s' "$P" > "$PASSF"
unset P
if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 300000 \
       -in "$BUNDLE" -out "$WORK/bundle.tar.gz" -pass file:"$PASSF" 2>"$WORK/enc.err"; then
  shred -u "$PASSF" 2>/dev/null || rm -f "$PASSF"
  die "senha errada? $(tail -1 "$WORK/enc.err" 2>/dev/null)"
fi
shred -u "$PASSF" 2>/dev/null || rm -f "$PASSF"
tar -xzf "$WORK/bundle.tar.gz" -C "$WORK"
rm -f "$WORK/bundle.tar.gz"
[[ -f "$WORK/manifest.txt" ]] || die "pacote inválido (sem manifest.txt)"

# ----------------------------------------------------------------------------
apti() {
  if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>/dev/null || true
    apt-get install -y -qq "$@" 2>/dev/null || warn "apt falhou: $*"
  else
    warn "sem apt-get — instala manualmente: $*"
  fi
}

# ----------------------------------------------------------------------------
if [[ $DATA_ONLY -eq 0 ]]; then
  log "2/9 · Dependências (docker, nginx, certbot, git)"
  if ! command -v docker >/dev/null; then
    warn "docker ausente — instalar via get.docker.com"
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
  fi
  docker compose version >/dev/null 2>&1 \
    || warn "docker compose plugin indisponível — corre: apt install docker-compose-plugin"
  command -v nginx >/dev/null || apti nginx python3-certbot-nginx
  command -v git   >/dev/null || apti git
  ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') · nginx $(nginx -v 2>&1 || echo '?') · git $(git --version 2>/dev/null || echo '?')"
else
  log "2/9 · (omitido: --data-only)"
  info "assumido que a infraestrutura já está montada; só dados agora"
fi

# ----------------------------------------------------------------------------
log "3/9 · Projectos (clonar o que falta em /opt)"
mapfile -t PLINES < <(grep -v '^$' "$WORK/projects.txt" 2>/dev/null || true)
for line in "${PLINES[@]:-}"; do
  [[ -n "$line" ]] || continue
  src="${line%%|*}"; src="${src%/}"
  url="${line#*|}"; [[ "$url" == "$line" ]] && url=""
  name="$(basename "$src")"; target="/opt/$name"
  if [[ -d "$target/.git" ]]; then
    if [[ -n "$url" ]] && ! git -C "$target" remote get-url origin >/dev/null 2>&1; then
      git -C "$target" remote add origin "$url" || true
    fi
    info "$name — já existe (git pull op.)"
    git -C "$target" pull --ff-only --quiet 2>/dev/null || \
      info "$name — branch local divergente, não fiz pull (verificar manualmente)"
  elif [[ -n "$url" ]]; then
    if git clone --quiet "$url" "$target"; then ok "$name → clonado"
    else warn "$name — clone falhou ($url)"; fi
  else
    warn "$name — sem git e sem remote: cria /opt/$name manualmente"
  fi
done

# ----------------------------------------------------------------------------
log "4/9 · Ficheiros .env por projecto"
shopt -s nullglob
ENVS=("$WORK"/envs/*.tar.gz)
shopt -u nullglob
for f in "${ENVS[@]:-}"; do
  [[ -f "$f" ]] || { warn "nenhum .env no pacote"; break; }
  name="$(basename "$f" .tar.gz)"
  target="/opt/$name"; mkdir -p "$target"
  tar -xzf "$f" --numeric-owner -C "$target"
  find "$target" -maxdepth 3 \( -name '.env*' -o -name '*.env' \) -exec chmod 600 {} \;
  ok "$name → $target"
done

# ----------------------------------------------------------------------------
if [[ $DATA_ONLY -eq 0 ]]; then
  log "5/9 · Nginx e certificados"
  if [[ -f "$WORK/nginx.tar.gz" ]]; then
    if [[ -d /etc/nginx ]]; then
      BK="/etc/nginx.pre-migracao-$(date +%Y%m%d-%H%M)"
      mv /etc/nginx "$BK"; warn "nginx anterior guardado em $BK"
    fi
    tar -xzf "$WORK/nginx.tar.gz" -C /
    mkdir -p /var/log/nginx
    ok "/etc/nginx instalado"
  else
    warn "pacote sem nginx.tar.gz — instala configs manualmente"
  fi

  if [[ -f "$WORK/letsencrypt.tar.gz" ]]; then
    if [[ -d /etc/letsencrypt ]]; then
      BK="/etc/letsencrypt.pre-migracao-$(date +%Y%m%d-%H%M)"
      mv /etc/letsencrypt "$BK"; warn "letsencrypt anterior em $BK"
    fi
    tar -xzf "$WORK/letsencrypt.tar.gz" -C /
    find /etc/letsencrypt -type f \( -name 'privkey*.pem' -o -name '*.key' \) \
      -exec chmod 600 {} \; 2>/dev/null || true
    ok "/etc/letsencrypt instalado (mesmos certs, renewal incl.)"
  else
    warn "pacote sem letsencrypt.tar.gz — correr certbot certs no B"
  fi

  mkdir -p /etc/letsencrypt/renewal-hooks-deploy
  cat > /etc/letsencrypt/renewal-hooks-deploy/00-reload-nginx.sh <<'HOOK'
#!/bin/sh
[ -x /usr/sbin/nginx ] && nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
HOOK
  chmod +x /etc/letsencrypt/renewal-hooks-deploy/00-reload-nginx.sh
  ok "hook pós-renewal (reload nginx)"

  if ! systemctl list-timers 2>/dev/null | grep -qi certbot \
     && ! ls /etc/cron.d/certbot* >/dev/null 2>&1; then
    warn "sem certbot.timer — criar /etc/cron.d/certbot"
    {
      echo 'SHELL=/bin/sh'
      echo '3 */12 * * * root certbot -q renew'
    } > /etc/cron.d/certbot
    chmod 644 /etc/cron.d/certbot
  fi

  if ! nginx -t 2>"$WORK/nginxt.err"; then
    cat "$WORK/nginxt.err"
    die "nginx -t falhou (backup disponível em /etc/nginx.pre-migracao-*)"
  fi
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx
  ok "nginx a correr"

  shopt -s nullglob
  CRONS=("$WORK"/cron/*.cron)
  shopt -u nullglob
  for c in "${CRONS[@]:-}"; do
    [[ -f "$c" ]] || break
    u="$(basename "$c" .cron)"
    printf 'Instalar crontab de %s? [y/N] ' "$u"; read -r a
    if [[ "$a" == "y" || "$a" == "Y" ]]; then
      crontab -u "$u" "$c" && ok "crontab $u"
    else
      info "não instalado — ficheiro: $c"
    fi
  done

  if [[ -f "$WORK/systemd/custom-units.tar.gz" ]]; then
    printf 'Reinstalar units systemd customizadas? [Y/n] '; read -r a
    if [[ ! "$a" =~ ^[nN] ]]; then
      tar -xzf "$WORK/systemd/custom-units.tar.gz" -C /
      systemctl daemon-reload
      ok "units instaladas — habilita as necessárias: systemctl enable --now <unit>"
    fi
  fi
else
  log "5/9 · (omitido: --data-only)"
fi

# ----------------------------------------------------------------------------
log "6/9 · Imagens locais (docker load)"
shopt -s nullglob
IMGS=("$WORK"/images/*.tar)
shopt -u nullglob
for f in "${IMGS[@]:-}"; do
  docker load -i "$f" && ok "load $(basename "$f")"
done
[[ ${#IMGS[@]:-0} -eq 0 ]] && info "nenhuma imagem local no pacote"

# ----------------------------------------------------------------------------
log "7/9 · Volumes docker"
shopt -s nullglob
VFILES=("$WORK"/volumes/*.tar.gz)
shopt -u nullglob
for f in "${VFILES[@]:-}"; do
  v="$(basename "$f" .tar.gz)"
  docker volume inspect "$v" >/dev/null 2>&1 || docker volume create "$v" >/dev/null
  mkdir -p "/var/lib/docker/volumes/$v/_data"
  tar -xzf "$f" --numeric-owner -C "/var/lib/docker/volumes/$v"
  ok "$v"
done
[[ ${#VFILES[@]:-0} -eq 0 ]] && warn "nenhum volume no pacote"

# ----------------------------------------------------------------------------
log "8/9 · docker compose up"
for d in /opt/*/; do
  d="${d%/}"
  [[ -f "$d/docker-compose.yml" || -f "$d/docker-compose.yaml" \
  || -f "$d/compose.yml"       || -f "$d/compose.yaml" ]] || continue
  n="$(basename "$d")"
  echo "  → $n"
  if ( cd "$d" && docker compose up -d 2>"$WORK/cu.err" ); then
    ok "$n"
  else
    cat "$WORK/cu.err"
    if ( cd "$d" && docker compose up -d --build 2>>"$WORK/cu.err" ); then
      ok "$n (com --build)"
    else
      warn "$n NÃO subiu — ver $WORK/cu.err e: docker compose -f logs"
    fi
  fi
done

# ----------------------------------------------------------------------------
log "9/9 · Validação final"
if [[ $DATA_ONLY -eq 0 ]]; then
  systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
fi
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

echo
log "Próximos passos"
echo " 1. Testar domínios no B sem mudar DNS — na tua máquina (não no B):"
echo "      sudo nano /etc/hosts        #  IP_DO_B   dominio.com www.dominio.com"
echo "      curl -I https://dominio.com"
echo " 2. Firewall no B:  ufw allow 'Nginx Full' && ufw allow OpenSSH"
echo " 3. Depois de apontar o DNS, no B:  sudo certbot renew --dry-run"
echo " 4. Guardar o servidor A intacto alguns dias como fallback."
