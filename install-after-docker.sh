#!/bin/bash
set -euo pipefail

# Yêu cầu root
if [[ $EUID -ne 0 ]]; then
  echo "Script này cần chạy với quyền root"
  exit 1
fi

# Kiểm tra docker/compose đã có sẵn
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker chưa có. Hãy cài theo Cách 1 (get.docker.com) rồi chạy lại."
  exit 1
fi
COMPOSE_BIN="docker compose"
if ! docker compose version >/dev/null 2>&1; then
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_BIN="docker-compose"
  else
    echo "Không tìm thấy docker compose. Cài docker-compose-plugin hoặc docker-compose v1 rồi chạy lại."
    exit 1
  fi
fi

# Hỏi domain
read -rp "Nhập domain/subdomain cho n8n (vd: n8n.example.com): " DOMAIN
DOMAIN=${DOMAIN,,}

# Cài gói phụ trợ cho check domain
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl dnsutils >/dev/null

# Check domain → IP (IPv4)
check_domain() {
  local domain=$1
  local server_ip
  server_ip=$(curl -s4 https://api.ipify.org || true)
  if [[ -z "$server_ip" ]]; then
    echo "Không lấy được IP public IPv4."
    return 1
  fi
  local domain_ips
  domain_ips=$(dig +short A "$domain" | sed '/^$/d' || true)
  if [[ -z "$domain_ips" ]]; then
    echo "Domain $domain chưa có bản ghi A (IPv4)."
    return 1
  fi
  if echo "$domain_ips" | grep -qx "$server_ip"; then
    return 0
  else
    echo "A records của $domain:"
    echo "$domain_ips"
    echo "IP máy này: $server_ip"
    return 1
  fi
}

if check_domain "$DOMAIN"; then
  echo "✅ $DOMAIN đã trỏ đúng IP máy này."
else
  echo "❌ $DOMAIN chưa trỏ đúng IP. Hãy trỏ bản ghi A về: $(curl -s4 https://api.ipify.org)"
  exit 1
fi

# Chuẩn bị thư mục
N8N_DIR="/home/n8n"
mkdir -p "${N8N_DIR}/files"

# Tạo encryption key 1 lần
if [[ ! -f "${N8N_DIR}/.encryption_key" ]]; then
  openssl rand -hex 24 > "${N8N_DIR}/.encryption_key"
fi
N8N_ENC_KEY=$(cat "${N8N_DIR}/.encryption_key")

# Ghi .env (CHÚ Ý: expand biến)
cat > "${N8N_DIR}/.env" <<EOF
N8N_HOST=${DOMAIN}
N8N_PORT=5678
N8N_PROTOCOL=https
N8N_PUBLIC_URL=https://${DOMAIN}/
N8N_DEFAULT_BINARY_DATA_MODE=filesystem
N8N_ENCRYPTION_KEY=${N8N_ENC_KEY}
GENERIC_TIMEZONE=Europe/Berlin
EOF

# Ghi docker-compose.yml
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

# Ghi Caddyfile (expand biến)
cat > "${N8N_DIR}/Caddyfile" <<EOF
${DOMAIN} {
    encode gzip
    reverse_proxy http://n8n:5678
    log
}
EOF

# Quyền
chown -R 1000:1000 "${N8N_DIR}/files"
chmod -R 755 "${N8N_DIR}"

# Mở firewall (nếu dùng ufw)
if command -v ufw >/dev/null 2>&1; then
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
fi

# Khởi động
cd "${N8N_DIR}"
${COMPOSE_BIN} pull
${COMPOSE_BIN} up -d

echo "Đợi dịch vụ khởi động…"
sleep 10
${COMPOSE_BIN} ps

echo ""
echo "✅ Truy cập: https://${DOMAIN}"
echo "ℹ️  Nếu HTTPS chưa lên ngay, chờ Caddy phát hành/renew cert một chút."
