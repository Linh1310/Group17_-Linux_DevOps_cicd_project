#!/usr/bin/env bash
# telegram.sh - Hàm gửi thông báo Telegram (được source bởi deploy.sh)
# Cần biến: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID

# Gửi tin nhắn dạng HTML. Không bao giờ làm script chính bị lỗi nếu Telegram lỗi.
tg_send() {
    local text="$1"

    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
        echo "[telegram] Chưa cấu hình token/chat id, bỏ qua thông báo" >&2
        return 0
    fi

    # Giới hạn của Telegram là 4096 ký tự
    text="${text:0:4000}"

    curl -fsS -m 15 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d parse_mode=HTML \
        -d disable_web_page_preview=true \
        --data-urlencode text="$text" >/dev/null \
        || echo "[telegram] Gửi tin nhắn thất bại" >&2

    return 0
}

# Escape ký tự đặc biệt để chèn log vào tin nhắn HTML
tg_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}
