#!/bin/bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# 1) Yêu cầu root
# ──────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "Script này cần chạy với quyền root"
  exit 1
fi

# ──────────────────────────────────────────────────────────────
# 2) Hỏi domain
# ──────────────────────────────────────────────────────────────
read -rp "Nhập domain hoặc subdomain của bạn (ví dụ: n8n.yourdomain.com): " DOMAIN
DOMAIN=${DOMAIN,,} # về lowercase

# ──────────────────────────────────────────────────────────────
# 3) Cài các gói cần thiết (curl, dig, lsb-release, gnupg…)
# ──────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release dnsutils

# ──────────────────────────────────────────────────────────────
# 4) Kiểm tra domain → IP (IPv4)
#    - Lấy IP public IPv4 của server
#    - So với A records của DOMAIN
# ──────────────────────────────────────────────────────────────
check_domain() {
  local domain=$1
  local server_ip
  server_ip=$(curl -s4 https://api.ipify.org || true)

  if [[ -z "${server_ip}" ]]; then
    echo "Không lấy được IP public của server (IPv4). Kiểm tra mạng?"
    return 1
  fi

  # Lấy danh sách IPv4 A records (bỏ qua CNAME bằng cách hỏi trực tiếp bản ghi A)
  local domain_ips
  domain_ips=$(dig +short A "${domain}" | sed '/^$/d' || true)

  if [[ -z "${domain_ips}" ]]; then
    echo "Domain ${domain} hiện chưa có bản ghi A (IPv4)."
    return 1
  fi

  # Kiểm tra có IP nào trùng server_ip không
  if echo "${domain_ips}" | grep -qx "${server_ip}"; then
    return 0
  else
    echo "Cảnh báo: A records của ${domain} là:"
    echo "${domain_ips}"
    echo "Nhưng IP máy này là: ${server_ip}"
    return 1
  fi
}

if check_domain "${DOMAIN}"; then
  echo "✅ Domain ${DOMAIN} đã trỏ đúng tới server này. Tiếp tục cài đặt…"
else
  echo "❌ Domain ${DOMAIN} chưa trỏ tới server này (IPv4)."
  echo "→ Hãy trỏ bản ghi A của ${DOMAIN} về IP: $(curl -s4 https://api.ipify.org)"
  echo "Sau khi cập nhật DNS (đợi DNS propagate), chạy lại script."
  exit 1
fi

# ──────────────────────────────────────────────────────────────
# 5) Cài Docker & Compose (ưu tiên convenience script + plugin v2)
# ──────────────────────────────────────────────────────────────
install_docker_and_compose() {
  if command -v docker >/dev/null 2>&1; then
    echo "Docker đã có sẵn: $(docker --version)"
  else
    echo "Cài Docker qua convenience script…"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh || true
    # Bật dịch vụ nếu có systemd
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable --now docker || true
    fi
  fi

  # Nếu vẫn chưa có docker (repo fail), fallback về docker.io của Ubuntu
  if ! command -v docker >/dev/null 2>&1; then
    echo "Fallback: cài docker.io từ repo Ubuntu…"
    apt-get update
    apt-get install -y docker.io || {
      echo "Không cài được Docker. Kiểm tra mạng hoặc repo."
      exit 1
    }
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable --now docker || true
    fi
  fi

  # Compose v2 plugin
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose plugin đã sẵn sàng."
  else
    echo "Cài docker-compose-plugin…"
    apt-get update
    apt-get install -y docker-compose-plugin || true
  fi

  # Fallback cuối: nếu vẫn không có compose plugin, thử docker-compose v1
  if ! docker compose version >/dev/null 2>&1; then
    if command -v docker-compose >/dev/null 2>&1; then
      echo "Sẽ dùng docker-compose (v1) làm fallback."
      COMPOSE_BIN="docker-compose"
    else
      apt-get install -y docker-compose || true
      if command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_BIN="docker-compose"
      fi
    fi
  fi

  # Mặc định dùng compose v2 nếu có
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_BIN="docker compose"
  fi

  # Nếu không có cái nào -> báo lỗi
  if [[ -z "${COMPOSE_BIN:-}" ]]; then
    echo "Không tìm thấy docker compose (v2) hoặc docker-compose (v1)."
    exit 1
  fi

  echo "Dùng COMPOSE_BIN='${COMPOSE_BIN}'"
}

install_docker_and_compose


# ──────────────────────────────────────────────────────────────
# 6) Chuẩn bị thư mục & file cấu hình
# ──────────────────────────────────────────────────────────────
N8N_DIR="/home/n8n"
mkdir -p "${N8N_DIR}/files"

# Tạo ENCRYPTION KEY nếu chưa có
if [[ ! -f "${N8N_DIR}/.encryption_key" ]]; then
  openssl rand -hex 24 > "${N8N_DIR}/.encryption_key"
fi
N8N_ENC_KEY=$(cat "${N8N_DIR}/.encryption_key")

# Tạo file .env (expand biến!)
cat > "${N8N_DIR}/.env" <<EOF
# n8n base config
N8N_HOST=${DOMAIN}
N8N_PORT=5678
N8N_PROTOCOL=https
N8N_PUBLIC_URL=https://${DOMAIN}/
N8N_DEFAULT_BINARY_DATA_MODE=filesystem
N8N_ENCRYPTION_KEY=${N8N_ENC_KEY}
GENERIC_TIMEZONE=Europe/Berlin

# Tuỳ chọn: tăng kích thước payload nếu cần
# N8N_PAYLOAD_SIZE_MAX=64
EOF

# Tạo docker-compose.yml
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

# Tạo Caddyfile (expand biến!)
cat > "${N8N_DIR}/Caddyfile" <<EOF
${DOMAIN} {
    encode gzip
    reverse_proxy http://n8n:5678
    log
}
EOF

# Quyền thư mục (n8n chạy với uid 1000 trong container)
chown -R 1000:1000 "${N8N_DIR}/files"
chmod -R 755 "${N8N_DIR}"

# ──────────────────────────────────────────────────────────────
# 7) Khởi động
# ──────────────────────────────────────────────────────────────
cd "${N8N_DIR}"
${COMPOSE} up -d

echo "Đợi container khởi động…"
sleep 10

# Kiểm tra trạng thái bằng compose
echo "Kiểm tra container:"
${COMPOSE} ps

# Thử kiểm tra riêng service n8n có running không
if ${COMPOSE} ps | grep -E 'n8n\s+running' >/dev/null 2>&1; then
  echo "✅ n8n đang chạy."
else
  echo "❌ n8n chưa chạy. Xem log:"
  ${COMPOSE} logs --no-color --tail=200 n8n || true
fi

# Kiểm tra Caddy
if ${COMPOSE} ps | grep -E 'caddy\s+running' >/dev/null 2>&1; then
  echo "✅ Caddy đang chạy."
else
  echo "❌ Caddy chưa chạy. Xem log:"
  ${COMPOSE} logs --no-color --tail=200 caddy || true
fi

echo ""
echo "╔═════════════════════════════════════════════════════════════╗"
echo "║                                                             ║"
echo "║  ✅ n8n đã được cài đặt (hoặc đang khởi động).             ║"
echo "║                                                             ║"
echo "║  🌐 Truy cập: https://${DOMAIN}                             ║"
echo "║                                                             ║"
echo "║  ℹ️  Nếu HTTPS chưa lên ngay, đợi Caddy lấy cert vài phút. ║"
echo "║                                                             ║"
echo "╚═════════════════════════════════════════════════════════════╝"
echo ""
