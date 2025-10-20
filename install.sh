#!/usr/bin/env bash
set -euo pipefail

# ==========================
#   Cấu hình chung
# ==========================
N8N_DIR="/home/n8n"
N8N_IMAGE="n8nio/n8n:latest"
CADDY_IMAGE="caddy:2"
TZ_DEFAULT="Europe/Berlin"

# ==========================
#   Tiện ích in thông báo
# ==========================
log()   { echo -e "\033[1;36m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*"; }

# ==========================
#   Yêu cầu quyền root
# ==========================
if [[ $EUID -ne 0 ]]; then
  error "Script này cần chạy với quyền root."
  exit 1
fi

# ==========================
#   Hỏi domain/subdomain
# ==========================
read -rp "Nhập domain hoặc subdomain cho n8n (vd: n8n.example.com): " DOMAIN
DOMAIN=${DOMAIN,,}
if [[ -z "${DOMAIN}" ]]; then
  error "Domain rỗng."
  exit 1
fi

# ==========================
#   Gói nền
# ==========================
export DEBIAN_FRONTEND=noninteractive
log "Cài gói nền..."
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release dnsutils coreutils

# ==========================
#   Cài/repair Docker + Compose
# ==========================
ensure_docker_and_compose() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker đã có: $(docker --version 2>/dev/null || true)"
  else
    log "Thêm repo Docker (keyring) và cài đặt..."
    # Dọn key/repo cũ để tránh xung đột
    rm -f /etc/apt/sources.list.d/docker.list \
          /etc/apt/trusted.gpg.d/docker.gpg \
          /usr/share/keyrings/docker-archive-keyring.gpg \
          /etc/apt/keyrings/docker.gpg || true

    install -m 0755 -d /etc/apt/keyrings
    if curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; then
      chmod a+r /etc/apt/keyrings/docker.gpg
      ARCH=$(dpkg --print-architecture)
      CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
      echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get update -y || true
      if ! apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin; then
        warn "Cài qua repo thất bại, chuyển sang convenience script."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        apt-get install -y docker-compose-plugin || true
      fi
    else
      warn "Không lấy được GPG key Docker. Dùng convenience script."
      curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
      sh /tmp/get-docker.sh
      apt-get install -y docker-compose-plugin || true
    fi
  fi

  # Khởi động Docker daemon (ưu tiên systemd)
  if ! docker version >/dev/null 2>&1; then
    if command -v systemctl >/dev/null 2>&1; then
      log "Bật dịch vụ docker (systemd)..."
      systemctl enable --now docker || true
      sleep 2
    fi
  fi

  # Fallback khi không có systemd
  if ! docker version >/dev/null 2>&1; then
    warn "Có vẻ không có systemd. Khởi chạy dockerd nền..."
    mkdir -p /var/run
    nohup dockerd --host=unix:///var/run/docker.sock >/var/log/dockerd.nohup 2>&1 &
    sleep 3
    if ! docker version >/dev/null 2>&1; then
      error "Docker daemon chưa chạy. Xem log: /var/log/dockerd.nohup"
      exit 1
    fi
  fi

  # Chọn Compose v2 nếu có, fallback v1
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_BIN="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    warn "Sử dụng docker-compose v1 (fallback)."
    COMPOSE_BIN="docker-compose"
  else
    warn "Cài thêm docker-compose-plugin..."
    apt-get install -y docker-compose-plugin || true
    if docker compose version >/dev/null 2>&1; then
      COMPOSE_BIN="docker compose"
    else
      error "Không tìm thấy docker compose."
      exit 1
    fi
  fi
  export COMPOSE_BIN
  log "Sử dụng COMPOSE_BIN='${COMPOSE_BIN}'."
}

ensure_docker_and_compose

# ==========================
#   Check domain → IP
# ==========================
check_domain_ipv4() {
  local domain=$1
  local server_ip domain_ips
  server_ip=$(curl -s4 https://api.ipify.org || true)

  if [[ -z "${server_ip}" ]]; then
    error "Không lấy được IP public IPv4 của server."
    return 1
  fi

  domain_ips=$(dig +short A "${domain}" | sed '/^$/d' || true)
  if [[ -z "${domain_ips}" ]]; then
    error "Domain ${domain} chưa có bản ghi A (IPv4)."
    return 1
  fi

  if echo "${domain_ips}" | grep -qx "${server_ip}"; then
    log "Domain ${domain} đã trỏ đúng IP (${server_ip})."
    return 0
  else
    warn "A records của ${domain}:"
    echo "${domain_ips}"
    warn "Nhưng IP máy này: ${server_ip}"
    return 1
  fi
}

if ! check_domain_ipv4 "${DOMAIN}"; then
  error "Hãy trỏ bản ghi A của ${DOMAIN} về IP: $(curl -s4 https://api.ipify.org)"
  exit 1
fi

# ==========================
#   Chuẩn bị thư mục/cấu hình
# ==========================
log "Tạo thư mục và file cấu hình n8n + Caddy..."
mkdir -p "${N8N_DIR}/files"

# Tạo encryption key một lần
if [[ ! -f "${N8N_DIR}/.encryption_key" ]]; then
  openssl rand -hex 24 > "${N8N_DIR}/.encryption_key"
fi
N8N_ENC_KEY=$(cat "${N8N_DIR}/.encryption_key")

# .env (expand biến!)
cat > "${N8N_DIR}/.env" <<EOF
# n8n base config
N8N_HOST=${DOMAIN}
N8N_PORT=5678
N8N_PROTOCOL=https
N8N_PUBLIC_URL=https://${DOMAIN}/
N8N_DEFAULT_BINARY_DATA_MODE=filesystem
N8N_ENCRYPTION_KEY=${N8N_ENC_KEY}
GENERIC_TIMEZONE=${TZ_DEFAULT}
EOF

# docker-compose.yml (không expand biến ở đây)
cat > "${N8N_DIR}/docker-compose.yml" <<'EOF'
version: "3.8"
services:
  n8n:
    image: n8nio/n8n:latest
    restart: always
    env_file:
      - .env
    ports:
      - "5678:5678"
    volumes:
      - ./files:/home/node/.n8n
    networks:
      - n8n_network

  caddy:
    image: caddy:2
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - n8n
    networks:
      - n8n_network

networks:
  n8n_network:
    driver: bridge

volumes:
  caddy_data:
  caddy_config:
EOF

# Caddyfile (expand biến!)
cat > "${N8N_DIR}/Caddyfile" <<EOF
${DOMAIN} {
    encode gzip
    reverse_proxy http://n8n:5678
    log
}
EOF

# Quyền (n8n chạy uid 1000 trong container)
chown -R 1000:1000 "${N8N_DIR}/files"
chmod -R 755 "${N8N_DIR}"

# Mở firewall nếu có ufw
if command -v ufw >/dev/null 2>&1; then
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
fi

# ==========================
#   Khởi chạy stack
# ==========================
log "Khởi chạy n8n + Caddy..."
cd "${N8N_DIR}"
${COMPOSE_BIN} pull
${COMPOSE_BIN} up -d

log "Đợi dịch vụ khởi động..."
sleep 10
${COMPOSE_BIN} ps

# Thử in log ngắn nếu chưa running
if ! ${COMPOSE_BIN} ps | grep -E 'n8n\s+.*(running|Up)' >/dev/null 2>&1; then
  warn "n8n chưa running. Log gần nhất:"
  ${COMPOSE_BIN} logs --tail=200 n8n || true
fi
if ! ${COMPOSE_BIN} ps | grep -E 'caddy\s+.*(running|Up)' >/dev/null 2>&1; then
  warn "Caddy chưa running. Log gần nhất:"
  ${COMPOSE_BIN} logs --tail=200 caddy || true
fi

echo ""
echo "╔═════════════════════════════════════════════════════════════╗"
echo "║  ✅ n8n đã được cài đặt (hoặc đang khởi động).             ║"
echo "║  🌐 Truy cập: https://${DOMAIN}                             ║"
echo "║  ℹ️  Nếu HTTPS chưa lên ngay, chờ Caddy phát cert vài phút.║"
echo "╚═════════════════════════════════════════════════════════════╝"
echo ""
