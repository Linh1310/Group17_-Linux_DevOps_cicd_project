#!/usr/bin/env bash
# =============================================================================
# deploy.sh - Triển khai tự động container lên server Production
#
# Quy trình:
#   1. Pull image mới          4. Health check
#   2. Dừng container cũ       5. Thành công -> dọn dẹp / Thất bại -> ROLLBACK
#   3. Chạy container mới      6. Thông báo kết quả qua Telegram
#
# Cách dùng:
#   ./deploy.sh              # deploy tag mặc định (IMAGE_TAG trong .env)
#   ./deploy.sh v1.2.0       # deploy tag chỉ định
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

[[ -f "$ENV_FILE" ]] || { echo "Không tìm thấy $ENV_FILE (copy từ .env.example)" >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a
source "$SCRIPT_DIR/telegram.sh"

# ---------- Cấu hình (có thể ghi đè trong .env) ----------
IMAGE="${IMAGE:?Thiếu IMAGE trong .env}"
TAG="${1:-${IMAGE_TAG:-latest}}"
CONTAINER_NAME="${CONTAINER_NAME:-myapp}"
APP_PORT="${APP_PORT:-8000}"                 # cổng trên host (127.0.0.1)
CONTAINER_PORT="${CONTAINER_PORT:-8000}"     # cổng app lắng nghe trong container
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:${APP_PORT}/}"
HEALTH_RETRIES="${HEALTH_RETRIES:-15}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-2}"
APP_ENV_FILE="${APP_ENV_FILE:-}"             # file env riêng cho app (tùy chọn)
LOCK_FILE="${LOCK_FILE:-/tmp/${CONTAINER_NAME}-deploy.lock}"

FULL_IMAGE="${IMAGE}:${TAG}"
OLD_NAME="${CONTAINER_NAME}_old"
HOST="$(hostname)"
START_TS=$(date +%s)
HAD_OLD=false
FINISHED=false

log() { echo "[$(date '+%F %T')] $*"; }
elapsed() { echo "$(( $(date +%s) - START_TS ))s"; }

# ---------- Chống chạy deploy song song ----------
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "Đang có một lần deploy khác chạy, thoát."
    tg_send "⚠️ <b>Deploy bị bỏ qua</b>
Server: <code>${HOST}</code>
Lý do: đang có một lần deploy khác chạy."
    exit 1
fi

# ---------- Rollback ----------
rollback() {
    local reason="$1" logs=""

    if docker inspect "$CONTAINER_NAME" &>/dev/null; then
        logs="$(docker logs --tail 15 "$CONTAINER_NAME" 2>&1 | tg_escape | tail -c 1500 || true)"
        docker rm -f "$CONTAINER_NAME" &>/dev/null || true
    fi

    local rb_status="Không có phiên bản cũ để khôi phục"
    if $HAD_OLD; then
        log "Khôi phục container cũ..."
        docker rename "$OLD_NAME" "$CONTAINER_NAME" &>/dev/null \
            && docker start "$CONTAINER_NAME" &>/dev/null \
            && rb_status="Đã rollback về phiên bản cũ" \
            || rb_status="ROLLBACK THẤT BẠI, cần can thiệp thủ công!"
    fi

    tg_send "❌ <b>DEPLOY THẤT BẠI</b>
Server: <code>${HOST}</code>
Image: <code>${FULL_IMAGE}</code>
Lý do: ${reason}
Kết quả: ${rb_status}
Thời gian: $(elapsed)
<pre>${logs}</pre>"
    log "THẤT BẠI: $reason ($rb_status)"
}

fail() {
    FINISHED=true
    rollback "$1"
    exit 1
}

# Bắt mọi lỗi bất ngờ (lệnh nào đó thoát khác 0)
on_error() {
    local line="$1"
    $FINISHED && return
    FINISHED=true
    rollback "Lỗi không mong đợi tại dòng ${line} của deploy.sh"
    exit 1
}
trap 'on_error $LINENO' ERR

# =============================================================================
log "Bắt đầu deploy ${FULL_IMAGE}"
tg_send "🚀 <b>Bắt đầu deploy</b>
Server: <code>${HOST}</code>
Image: <code>${FULL_IMAGE}</code>"

# 1. Pull image
log "Pull image..."
if ! docker pull "$FULL_IMAGE"; then
    fail "Không pull được image (sai tên/tag, chưa docker login, hoặc mất mạng)"
fi

# 2. Dừng container cũ (đổi tên để giữ lại cho rollback)
docker rm -f "$OLD_NAME" &>/dev/null || true
if docker inspect "$CONTAINER_NAME" &>/dev/null; then
    log "Dừng container cũ..."
    docker stop "$CONTAINER_NAME" >/dev/null
    docker rename "$CONTAINER_NAME" "$OLD_NAME"
    HAD_OLD=true
fi

# 3. Chạy container mới - bind 127.0.0.1 để không bypass UFW
log "Chạy container mới..."
RUN_ARGS=(-d --name "$CONTAINER_NAME" --restart unless-stopped
          -p "127.0.0.1:${APP_PORT}:${CONTAINER_PORT}")
[[ -n "$APP_ENV_FILE" ]] && RUN_ARGS+=(--env-file "$APP_ENV_FILE")

if ! docker run "${RUN_ARGS[@]}" "$FULL_IMAGE" >/dev/null; then
    fail "docker run thất bại (trùng cổng hoặc cấu hình sai)"
fi

# 4. Health check
log "Health check tại ${HEALTH_URL}..."
HEALTHY=false
for ((i = 1; i <= HEALTH_RETRIES; i++)); do
    if ! docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q true; then
        fail "Container bị dừng ngay sau khi khởi động (crash)"
    fi
    if curl -fsS -m 5 -o /dev/null "$HEALTH_URL"; then
        HEALTHY=true
        break
    fi
    log "  Lần ${i}/${HEALTH_RETRIES}: chưa sẵn sàng, đợi ${HEALTH_INTERVAL}s..."
    sleep "$HEALTH_INTERVAL"
done
$HEALTHY || fail "Health check thất bại sau $((HEALTH_RETRIES * HEALTH_INTERVAL))s"

# 5. Thành công -> dọn dẹp
FINISHED=true
docker rm -f "$OLD_NAME" &>/dev/null || true
docker image prune -f >/dev/null 2>&1 || true

tg_send "✅ <b>DEPLOY THÀNH CÔNG</b>
Server: <code>${HOST}</code>
Image: <code>${FULL_IMAGE}</code>
Thời gian: $(elapsed)
URL: ${HEALTH_URL}"
log "Deploy thành công trong $(elapsed)"
