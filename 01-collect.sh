#!/usr/bin/env bash
# ============================================================================
#  01-collect.sh — recolhe e empacota a migração do servidor A (antigo)
#
#  Executar como root no servidor A. Gera no directório actual:
#     migracao-<data>/
#     ├── manifest.txt            inventário legível (fica fora do pacote)
#     ├── staging/…               peças individuais (para inspeccionar)
#     └── bundle-<data>.tar.gz.enc  pacote encriptado → para o servidor B
#
#  Uso:
#     sudo ./01-collect.sh              # pacote COMPLETO (1.ª passagem)
#     sudo ./01-collect.sh --data-only  # só volumes + .env (passagem final)
#
#  O que recolhe:
#     - /etc/nginx          configs de domínios, proxy, mime, conf.d
#     - /etc/letsencrypt    certificados + contas + renewal + hooks
#     - .env                cada projecto em /opt (e compose.override.yml)
#     - volumes docker      dados de BDs/uploads (/var/lib/docker/volumes)
#     - imagens locais      imagens sem registry no repo (builds docker)
#     - cron + systemd      crontabs e units customizadas
# ============================================================================
set -Eeuo pipefail

OPT_DIR="${OPT_DIR:-/opt}"
TS="$(date +%Y%m%d-%H%M)"
OUT_DIR="${OUT_DIR:-$PWD/migracao-$TS}"
DATA_ONLY=0
[[ "${1:-}" == "--data-only" ]] && DATA_ONLY=1

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[0;32m✔\033[0m %s\n' "$*"; }
info() { printf '   \033[0;36m·\033[0m %s\n' "$*"; }
warn() { printf '   \033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERRO:\033[0m %s\n' "$*" >&2; exit 1; }
trap 'die "Falha na linha $LINENO. Estado parcial em $OUT_DIR"' ERR

[[ $EUID -eq 0 ]] || die "Corre como root:  sudo ./01-collect.sh"

ST="$OUT_DIR/staging"
mkdir -p "$ST"/{envs,volumes,images,cron,systemd}

# ----------------------------------------------------------------------------
log "1/9 · Inventário → manifest.txt"
{
  echo "### Gerado: $(date -Is) · host: $(hostname)"
  echo; echo "### SO"; head -3 /etc/os-release 2>/dev/null || true
  echo; echo "### Disco"; df -h / /opt 2>/dev/null || df -h / 2>/dev/null || true
  echo; echo "### Docker server"; docker version --format '{{.Server.Version}}' 2>/dev/null || true
  echo; echo "### Containers"
  docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
  echo; echo "### Imagens"
  docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}' 2>/dev/null || true
  echo; echo "### Volumes"
  docker volume ls 2>/dev/null || true
  echo; echo "### Redes"
  docker network ls 2>/dev/null || true
  echo; echo "### Nginx"; nginx -v 2>&1 || true
  echo; echo "### Certs (certbot)"
  certbot certificates 2>/dev/null || true
  echo; echo "### Serviços activos"
  systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null || true
  echo; echo "### Portas em escuta"; ss -tlnp 2>/dev/null || true
  echo; echo "### Firewall (ufw)"; ufw status verbose 2>/dev/null || true
  echo; echo "### Timezone"; timedatectl 2>/dev/null | head -4 || date
  echo; echo "### Config nginx resolvida (nginx -T, sem comentários)"
  nginx -T 2>/dev/null | grep -v '^\s*#' | head -1200 || true
} > "$OUT_DIR/manifest.txt"
cp "$OUT_DIR/manifest.txt" "$ST/manifest.txt"
ok "manifest.txt"

# ----------------------------------------------------------------------------
log "2/9 · Projectos → projects.txt"
mapfile -t PROJECTS < <(
  for d in "$OPT_DIR"/*/; do
    d="${d%/}"
    if [[ -f "$d/docker-compose.yml" || -f "$d/docker-compose.yaml" \
       || -f "$d/compose.yml"           || -f "$d/compose.yaml" ]] ; then
      printf '%s\n' "$d"
    fi
  done
)
: > "$ST/projects.txt"
for d in "$OPT_DIR"/*/; do
  d="${d%/}"
  url="" ; [[ -d "$d/.git" ]] && url="$(git -C "$d" remote get-url origin 2>/dev/null || true)"
  printf '%s|%s\n' "$d" "$url" >> "$ST/projects.txt"
done
ok "projectos com compose: ${#PROJECTS[@]} (detalhe em projects.txt)"

# ----------------------------------------------------------------------------
log "3/9 · Ficheiros de ambiente (.env) por projecto"
: > "$ST/untracked.txt"
for d in "${PROJECTS[@]:-}"; do
  [[ -n "$d" ]] || continue
  name="$(basename "$d")"
  mapfile -d '' FILES < <(
    find "$d" -maxdepth 2 \( -name node_modules -o -name .git \) -prune -o \
      -type f \( -name '.env' -o -name '.env.*' -o -name '*.env' \
               -o -name 'docker-compose.override.yml' \
               -o -name 'docker-compose.override.yaml' \
               -o -name 'compose.override.yml'       \
               -o -name 'compose.override.yaml' \) -print0 2>/dev/null
  )
  if [[ ${#FILES[@]} -gt 0 ]]; then
    mapped=(); for f in "${FILES[@]}"; do mapped+=("${f#"$d"/}"); done
    tar -czf "$ST/envs/${name}.tar.gz" --numeric-owner -C "$d" "${mapped[@]}"
    ok "envs/${name}.tar.gz  [$(basename "${mapped[0]}") …]"
  else
    info "sem .env em $name"
  fi
  [[ -d "$d/.git" ]] && \
    git -C "$d" status --porcelain --untracked-files=all 2>/dev/null \
      | grep '^??' | head -40 >> "$ST/untracked.txt" || true
done
if [[ -s "$ST/untracked.txt" ]]; then
  info "ficheiros não versionados listados em untracked.txt — confere se falta algo!"
fi

# ----------------------------------------------------------------------------
if [[ $DATA_ONLY -eq 0 ]]; then
  log "4/9 · Nginx e certificados"
  if [[ -d /etc/nginx ]]; then
    tar -czf "$ST/nginx.tar.gz" --numeric-owner -C / etc/nginx
    ok "nginx.tar.gz (sites/shared/mime tudo incluído)"
  else
    warn "não existe /etc/nginx — este servidor corre nginx?"
  fi
  if [[ -d /etc/letsencrypt ]]; then
    tar -czf "$ST/letsencrypt.tar.gz" --numeric-owner -C / etc/letsencrypt
    ok "letsencrypt.tar.gz (chaves mantidas com permissões)"
  else
    warn "não existe /etc/letsencrypt"
  fi

  log "5/9 · Cron e systemd customizados"
  if crontab -l > "$ST/cron/root.cron" 2>/dev/null; then
    ok "crontab root"
  else
    rm -f "$ST/cron/root.cron" ; info "root sem crontab"
  fi
  for u in /var/spool/cron/crontabs/*; do
    [[ -f "$u" ]] || continue
    bn="$(basename "$u")"; [[ "$bn" == "root" ]] && continue
    cp "$u" "$ST/cron/${bn}.cron"; ok "crontab $bn"
  done
  units=()
  while IFS= read -r -d '' f; do
    [[ -f "$f" && ! -L "$f" ]] && units+=("$f")
  done < <(find /etc/systemd/system -maxdepth 2 \
             \( -name '*.service' -o -name '*.timer' \) -print0 2>/dev/null)
  if [[ ${#units[@]} -gt 0 ]]; then
    tar -czf "$ST/systemd/custom-units.tar.gz" "${units[@]}"
    ok "systemd: ${#units[@]} unit(s) customizada(s)"
  fi
else
  log "4/9 · (omitido: --data-only não leva nginx/certs/cron)"
  log "5/9 · (omitido)"
fi

# ----------------------------------------------------------------------------
log "6/9 · Volumes docker"
TOTAL=0
mapfile -t VOLUMES < <(docker volume ls -q 2>/dev/null || true)
for v in "${VOLUMES[@]:-}"; do
  [[ -z "$v" ]] && continue
  p="/var/lib/docker/volumes/$v/_data"
  if [[ -d "$p" ]]; then
    sz="$(du -sb "$p" 2>/dev/null | cut -f1)"; TOTAL=$((TOTAL + sz))
    tar -czf "$ST/volumes/${v}.tar.gz" --numeric-owner \
      -C "/var/lib/docker/volumes/$v" _data
    ok "$v  ($(numfmt --to=iec "$sz" 2>/dev/null || echo "${sz}b"))"
  else
    info "$v vazio"
  fi
done
[[ ${#VOLUMES[@]} -eq 0 ]] && warn "nenhum volume docker"
info "volumes total: $(numfmt --to=iec "$TOTAL" 2>/dev/null || echo "${TOTAL}b")"

# ----------------------------------------------------------------------------
log "7/9 · Imagens docker"
: > "$ST/images/pull-list.txt"
mapfile -t USED < <(docker ps -a --format '{{.Image}}' 2>/dev/null | sort -u)
for i in "${USED[@]:-}"; do
  [[ -z "$i" || "$i" == "<none>" || "$i" == sha256:* ]] && continue
  case "$i" in
    */* ) printf '%s\n' "$i" >> "$ST/images/pull-list.txt" ;;
    * )
      docker save "$i" -o "$ST/images/$(printf '%s' "$i" | tr '/:' '__').tar"
      ok "save local: $i"
      ;;
  esac
done
if [[ -s "$ST/images/pull-list.txt" ]]; then
  info "restantes (assumidos pulláveis do registry): ver images/pull-list.txt"
fi
for d in "${PROJECTS[@]:-}"; do
  [[ -n "$d" ]] || continue
  if grep -qsE '^[[:space:]]*build:' "$d"/docker-compose*.y*ml "$d"/compose*.y*ml 2>/dev/null; then
    warn "$(basename "$d") faz build — confirma que a imagem correspondente foi gravada acima"
  fi
done

# ----------------------------------------------------------------------------
log "8/9 · Empacotar"
BARGE="$OUT_DIR/bundle.tar.gz"
TARLIST=( envs volumes images manifest.txt projects.txt untracked.txt )
if [[ $DATA_ONLY -eq 0 ]]; then
  [[ -f "$ST/nginx.tar.gz"        ]] && TARLIST+=( nginx.tar.gz )
  [[ -f "$ST/letsencrypt.tar.gz" ]] && TARLIST+=( letsencrypt.tar.gz )
  if cpfiles="$(ls "$ST/cron" 2>/dev/null)" && [[ -n "$cpfiles" ]]; then
    TARLIST+=( cron )
  fi
  [[ -f "$ST/systemd/custom-units.tar.gz" ]] && TARLIST+=( systemd )
fi
tar -czf "$BARGE" -C "$ST" "${TARLIST[@]}"

log "9/9 · Encriptar (AES-256, pbkdf2)"
while true; do
  printf 'Senha do pacote: '; read -rs P1; echo
  printf 'Confirmar  : '; read -rs P2; echo
  [[ -n "$P1" && "$P1" == "$P2" ]] && break
  warn "senhas diferentes ou vazias — tenta outra vez"
done
PASSF="$(mktemp /tmp/.migpass.XXXXXX)"; chmod 600 "$PASSF"; printf '%s' "$P1" > "$PASSF"
BUNDLE="$OUT_DIR/bundle-$TS.tar.gz.enc"
openssl enc -aes-256-cbc -salt -pbkdf2 -iter 300000 \
  -in "$BARGE" -out "$BUNDLE" -pass file:"$PASSF"
shred -u "$PASSF" 2>/dev/null || rm -f "$PASSF"
rm -f "$BARGE"
unset P1 P2

ok "bundle criado: $BUNDLE  ($(numfmt --to=iec "$(stat -c%s "$BUNDLE")" 2>/dev/null || echo '?'))"
info "manifest legível: $OUT_DIR/manifest.txt"

# ----------------------------------------------------------------------------
echo
log "Passos seguintes"
if [[ $DATA_ONLY -eq 1 ]]; then
  echo " 1. Copiar para B e sincronizar os dados (no B):"
  echo "      scp $BUNDLE root@SERVIDOR_B:/root/"
  echo "      sudo ./02-restore.sh --data-only $(basename "$BUNDLE")"
  echo " 2. Valida tudo no B, aponta os DNS e só depois deprecia o A."
else
  echo " 1. Copiar para B e restaurar:"
  echo "      scp $BUNDLE root@SERVIDOR_B:/root/"
  echo "      scp 02-restore.sh   root@SERVIDOR_B:/root/"
  echo "      sudo ./02-restore.sh $(basename "$BUNDLE")"
  echo " 2. Testar via /etc/hosts ou subdomínio de testes."
  echo " 3. Última passagem (migração a frio): sudo ./01-collect.sh --data-only"
fi
