#!/usr/bin/env bash
# =============================================================================
# setup.sh - Tự động cấu hình server Production Ubuntu
# Phạm vi: user + phân quyền, SSH hardening, UFW, Fail2ban, Docker, Nginx proxy
#
# Cách dùng:
#   sudo ./setup.sh
#   sudo DOMAIN=example.com SSH_PUBKEY="ssh-ed25519 AAAA... me@pc" ./setup.sh
#
# Biến môi trường (đều tùy chọn):
#   DEPLOY_USER         user triển khai            (mặc định: deploy)
#   APP_PORT            cổng container trên host   (mặc định: 8000)
#   APP_DIR             thư mục triển khai         (mặc định: /opt/app)
#   DOMAIN              domain hoặc IP server      (mặc định: _  = nhận mọi host)
#   SSH_PUBKEY          public key của user deploy (nếu có -> tắt đăng nhập mật khẩu)
#   HOSTNAME_NEW        hostname                   (mặc định: prod-server)
#   RUN_TEST_CONTAINER  yes/no - chạy container nginx:alpine để test (mặc định: yes)
# =============================================================================
set -euo pipefail

# ---------- Cấu hình ----------
DEPLOY_USER="${DEPLOY_USER:-deploy}"
APP_PORT="${APP_PORT:-8000}"
APP_DIR="${APP_DIR:-/opt/app}"
DOMAIN="${DOMAIN:-_}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
HOSTNAME_NEW="${HOSTNAME_NEW:-prod-server}"
RUN_TEST_CONTAINER="${RUN_TEST_CONTAINER:-yes}"
SITE_NAME="myapp"

# ---------- Hàm tiện ích ----------
log()  { echo -e "\n\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
die()  { echo -e "\033[1;31m[x] $*\033[0m" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Hãy chạy script bằng sudo: sudo ./setup.sh"
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || warn "Script được viết cho Ubuntu, hệ điều hành hiện tại: ${ID:-unknown}"

export DEBIAN_FRONTEND=noninteractive

# =============================================================================
# 1. Cập nhật hệ thống và cài gói cơ bản
# =============================================================================
log "1. Cập nhật hệ thống và cài gói cơ bản"
apt-get update -y
apt-get upgrade -y
apt-get install -y curl wget git vim htop net-tools ufw fail2ban nginx ca-certificates

hostnamectl set-hostname "$HOSTNAME_NEW"
timedatectl set-timezone Asia/Ho_Chi_Minh

# =============================================================================
# 2. Tạo user triển khai + phân quyền
# =============================================================================
log "2. Tạo user '$DEPLOY_USER' và phân quyền"
if id "$DEPLOY_USER" &>/dev/null; then
    warn "User $DEPLOY_USER đã tồn tại, bỏ qua bước tạo"
else
    adduser --disabled-password --gecos "" "$DEPLOY_USER"
    # Đặt mật khẩu để dùng sudo (chỉ hỏi khi chạy tương tác)
    if [[ -t 0 ]]; then
        echo "Đặt mật khẩu cho user $DEPLOY_USER (dùng cho sudo):"
        passwd "$DEPLOY_USER"
    else
        warn "Chạy không tương tác: hãy tự đặt mật khẩu bằng 'sudo passwd $DEPLOY_USER'"
    fi
fi
usermod -aG sudo "$DEPLOY_USER"

# Nhóm devops dùng chung cho các thành viên
getent group devops >/dev/null || groupadd devops
usermod -aG devops "$DEPLOY_USER"

# Thư mục triển khai: chủ deploy, nhóm devops được đọc/ghi, người ngoài không truy cập
mkdir -p "$APP_DIR"
chown -R "$DEPLOY_USER":devops "$APP_DIR"
chmod 2770 "$APP_DIR"     # setgid: file mới tự thuộc nhóm devops

# =============================================================================
# 3. SSH key + hardening
# =============================================================================
log "3. Cấu hình SSH"
USER_HOME="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
SSH_DIR="$USER_HOME/.ssh"
mkdir -p "$SSH_DIR"
touch "$SSH_DIR/authorized_keys"

if [[ -n "$SSH_PUBKEY" ]]; then
    grep -qxF "$SSH_PUBKEY" "$SSH_DIR/authorized_keys" || echo "$SSH_PUBKEY" >> "$SSH_DIR/authorized_keys"
fi
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$DEPLOY_USER":"$DEPLOY_USER" "$SSH_DIR"

# Đặt tên 00- để được đọc trước các file khác (vd 50-cloud-init.conf),
# vì sshd lấy giá trị đầu tiên gặp được.
HARDEN_FILE="/etc/ssh/sshd_config.d/00-hardening.conf"
mkdir -p /etc/ssh/sshd_config.d

if [[ -s "$SSH_DIR/authorized_keys" ]]; then
    cat > "$HARDEN_FILE" <<EOF
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
EOF
    log "Đã tắt đăng nhập root và đăng nhập bằng mật khẩu"
else
    cat > "$HARDEN_FILE" <<EOF
PermitRootLogin no
PubkeyAuthentication yes
EOF
    warn "Chưa có SSH key nên GIỮ đăng nhập bằng mật khẩu để tránh tự khóa mình."
    warn "Sau khi thêm key, chạy lại script với SSH_PUBKEY=... để tắt mật khẩu."
fi

sshd -t || die "Cấu hình SSH lỗi, kiểm tra $HARDEN_FILE"
systemctl restart ssh
warn "QUAN TRỌNG: mở thêm 1 cửa sổ SSH mới để test trước khi đóng phiên hiện tại!"

# =============================================================================
# 4. UFW Firewall
# =============================================================================
log "4. Cấu hình UFW (chỉ mở 22, 80, 443)"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw status verbose

# =============================================================================
# 5. Fail2ban
# =============================================================================
log "5. Cấu hình Fail2ban"
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# =============================================================================
# 6. Docker
# =============================================================================
log "6. Cài Docker"
if command -v docker &>/dev/null; then
    warn "Docker đã được cài, bỏ qua"
else
    curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker
usermod -aG docker "$DEPLOY_USER"

if [[ "$RUN_TEST_CONTAINER" == "yes" ]]; then
    log "Chạy container test (nginx:alpine) tại 127.0.0.1:$APP_PORT"
    docker rm -f test-app &>/dev/null || true
    # Bind vào 127.0.0.1 để Docker KHÔNG bypass UFW
    docker run -d --name test-app --restart unless-stopped \
        -p 127.0.0.1:"$APP_PORT":80 nginx:alpine
    sleep 3
fi

# =============================================================================
# 7. Nginx Reverse Proxy
# =============================================================================
log "7. Cấu hình Nginx reverse proxy -> 127.0.0.1:$APP_PORT"
cat > "/etc/nginx/sites-available/$SITE_NAME" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    # Ẩn phiên bản Nginx
    server_tokens off;

    client_max_body_size 20m;

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Hỗ trợ WebSocket (không ảnh hưởng nếu app không dùng)
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_connect_timeout 10s;
        proxy_read_timeout 60s;
    }

    access_log /var/log/nginx/${SITE_NAME}_access.log;
    error_log  /var/log/nginx/${SITE_NAME}_error.log;
}
EOF

# Map cho WebSocket (đặt ở cấp http thông qua conf.d)
cat > /etc/nginx/conf.d/connection_upgrade.conf <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF

ln -sf "/etc/nginx/sites-available/$SITE_NAME" "/etc/nginx/sites-enabled/$SITE_NAME"
rm -f /etc/nginx/sites-enabled/default

nginx -t || die "Cấu hình Nginx lỗi"
systemctl enable nginx
systemctl reload nginx

# =============================================================================
# 8. Kiểm tra cuối
# =============================================================================
log "8. Kiểm tra kết quả"
echo "--- Dịch vụ ---"
for s in nginx docker fail2ban ssh; do
    printf "%-10s %s\n" "$s" "$(systemctl is-active $s)"
done

echo -e "\n--- Cổng đang lắng nghe ---"
ss -tulpn | grep -E ":(22|80|443|$APP_PORT)\b" || true

echo -e "\n--- Test qua Nginx (localhost:80) ---"
curl -sI http://127.0.0.1 | head -n 1 || warn "Chưa nhận phản hồi từ app (container đã chạy chưa?)"

cat <<EOF

=============================================================
HOÀN TẤT
  User triển khai : $DEPLOY_USER
  Thư mục app     : $APP_DIR
  Cổng container  : 127.0.0.1:$APP_PORT (không mở ra ngoài)
  Nginx           : http://$DOMAIN  ->  127.0.0.1:$APP_PORT

Việc cần làm tiếp:
  1. Mở cửa sổ SSH mới, test: ssh $DEPLOY_USER@<IP_SERVER>
  2. Đăng xuất/đăng nhập lại để user dùng được lệnh docker không cần sudo
  3. Có domain thật -> bật HTTPS:
       sudo apt install -y certbot python3-certbot-nginx
       sudo certbot --nginx -d <domain>
  4. Khi nhóm có image thật, xóa container test:
       docker rm -f test-app
=============================================================
EOF
