#!/usr/bin/env bash
set -e

get_keys() {
    colorized_echo blue "Получение ключей..."
    if ! output=$(docker exec marzban_marzban_1 xray x25519 2>/dev/null); then
        output=$(docker exec marzban-marzban-1 xray x25519)
    fi
    public_key=$(echo "$output" | grep "Public key:" | cut -d' ' -f3)
    echo "$public_key" > "$DATA_DIR/pubkey.json"
    openssl rand -hex 8 > "$DATA_DIR/shortid.json"
}

create_config() {
    colorized_echo blue "Создание конфигурации..."
    pub_key=$(cat "$DATA_DIR/pubkey.json")
    short_id=$(cat "$DATA_DIR/shortid.json")
    cat > "$DATA_DIR/xray_config.json" << EOF
{
    "log": {
        "loglevel": "warning"
    },
    "routing": {
        "rules": [
            {
                "ip": [
                    "geoip:private"
                ],
                "outboundTag": "BLOCK",
                "type": "field"
            }
        ]
    },
    "inbounds": [
        {
            "tag": "VLESS TCP REALITY",
            "listen": "0.0.0.0",
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "tcpSettings": {},
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "google.com:443",
                    "xver": 0,
                    "serverNames": [
                        "google.com"
                    ],
                    "privateKey": "$pub_key",
                    "shortIds": [
                        "$short_id"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic"
                ]
            }
        },
        {
            "tag": "Shadowsocks TCP",
            "listen": "0.0.0.0",
            "port": 1080,
            "protocol": "shadowsocks",
            "settings": {
                "clients": [],
                "network": "tcp,udp"
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "DIRECT"
        },
        {
            "protocol": "blackhole",
            "tag": "BLOCK"
        }
    ]
}
EOF
}

restart_container() {
    colorized_echo blue "Перезапуск контейнера..."
    if ! docker restart marzban_marzban_1 2>/dev/null; then
        if ! docker restart marzban-marzban-1; then
            colorized_echo red "Ошибка: Не удалось перезапустить контейнер"
            exit 1
        fi
    fi
    colorized_echo green "Контейнер успешно перезапущен"
}

save_marzban_credentials() {
    local json_file="$HOME/marzbandata.json"
    cat << EOF > "$json_file"
{
    "panel_url": "http://127.0.0.1:${HTTP_PORT}/dashboard",
    "api_url": "http://127.0.0.1:${HTTP_PORT}/api",
    "credentials": {
        "username": "admin",
        "password": "${ADMIN_PASS}"
    }
}
EOF
    chmod 600 "$json_file"
    colorized_echo green "Учетные данные Marzban сохранены в файл: $json_file"
}

save_outline_credentials() {
    local json_file="$HOME/outlinedata.json"
    local api_url="$1"
    local cert_sha="$2"
    cat << EOF > "$json_file"
{
    "api_url": "${api_url}",
    "cert_sha": "${cert_sha}"
}
EOF
    chmod 600 "$json_file"
    colorized_echo green "Данные Outline сохранены в файл: $json_file"
}

install_outline() {
    colorized_echo blue "Начинаем установку Outline VPN..."
    local temp_output="/tmp/outline_install_output.txt"
    sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh)" | tee "$temp_output"
    local api_url=$(grep "apiUrl" "$temp_output" | cut -d'"' -f2)
    local cert_sha=$(grep "certSha256" "$temp_output" | cut -d'"' -f2)
    if [ -n "$api_url" ] && [ -n "$cert_sha" ]; then
        save_outline_credentials "$api_url" "$cert_sha"
        colorized_echo green "Outline VPN успешно установлен"
    else
        colorized_echo red "Ошибка: не удалось получить данные установки Outline"
        return 1
    fi
    rm -f "$temp_output"
}

warning_countdown() {
    colorized_echo red "ВНИМАНИЕ! Этот скрипт удалит существующую установку Marzban вместе со всеми данными!"
    colorized_echo yellow "Для отмены нажмите Ctrl+C"
    for i in {5..1}; do
        echo -ne "\rПродолжение через $i секунд..."
        sleep 1
    done
    echo -e "\n"
}

cleanup_existing_installation() {
    colorized_echo yellow "Проверка существующей установки..."
    if [ -f "/usr/local/bin/marzban" ]; then
        colorized_echo yellow "Найден существующий исполняемый файл marzban, удаляем..."
        rm -f /usr/local/bin/marzban
    fi
    if [ -d "$APP_DIR" ]; then
        colorized_echo yellow "Найдена директория $APP_DIR, удаляем..."
        rm -rf "$APP_DIR"
    fi
    if [ -d "$DATA_DIR" ]; then
        colorized_echo yellow "Найдена директория $DATA_DIR, удаляем..."
        rm -rf "$DATA_DIR"
    fi
    if docker compose -f "$COMPOSE_FILE" -p marzban ps &>/dev/null; then
        colorized_echo yellow "Найдены запущенные контейнеры marzban, останавливаем..."
        docker compose -f "$COMPOSE_FILE" -p marzban down
    fi
    colorized_echo green "Очистка завершена"
}

ufw disable
APP_NAME="marzban"
INSTALL_DIR="/opt"
APP_DIR="$INSTALL_DIR/$APP_NAME"
DATA_DIR="/var/lib/$APP_NAME"
HTTP_PORT=$(shuf -i 50000-65535 -n1)
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

MAIL=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)
ADMIN_PASS=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)
DOMAIN=$1
FILES_URL_PREFIX="https://raw.githubusercontent.com/Gozargah/Marzban/master"

colorized_echo() {
    local color=$1
    local text=$2
    case $color in
        "red")
        printf "\e[91m${text}\e[0m\n";;
        "green")
        printf "\e[92m${text}\e[0m\n";;
        "yellow")
        printf "\e[93m${text}\e[0m\n";;
        "blue")
        printf "\e[94m${text}\e[0m\n";;
        "magenta")
        printf "\e[95m${text}\e[0m\n";;
        "cyan")
        printf "\e[96m${text}\e[0m\n";;
        *)
            echo "${text}"
        ;;
    esac
}

warning_countdown

cleanup_existing_installation

FETCH_REPO="Gozargah/Marzban-scripts"
SCRIPT_URL="https://github.com/$FETCH_REPO/raw/master/marzban.sh"
colorized_echo blue "Installing marzban script"
curl -sSL $SCRIPT_URL | install -m 755 /dev/stdin /usr/local/bin/marzban
colorized_echo green "marzban script installed successfully"

colorized_echo blue "Installing Docker"
curl -fsSL https://get.docker.com | sh
colorized_echo green "Docker installed successfully"

mkdir -p "$DATA_DIR"
mkdir -p "$APP_DIR"

colorized_echo blue "Fetching compose file"
curl -sL "$FILES_URL_PREFIX/docker-compose.yml" -o "$APP_DIR/docker-compose.yml"
colorized_echo green "File saved in $APP_DIR/docker-compose.yml"

colorized_echo blue "Fetching .env file"
cat << EOF | tee "$APP_DIR/.env"
UVICORN_HOST = "127.0.0.1"
UVICORN_PORT = ${HTTP_PORT}
SUDO_USERNAME = "admin"
SUDO_PASSWORD = "${ADMIN_PASS}"
XRAY_JSON = "/var/lib/marzban/xray_config.json"
SQLALCHEMY_DATABASE_URL = "sqlite:////var/lib/marzban/db.sqlite3"
XRAY_SUBSCRIPTION_URL_PREFIX = "http://127.0.0.1:${HTTP_PORT}"
EOF

colorized_echo green "File saved in $APP_DIR/.env"

colorized_echo blue "Fetching xray config file"
curl -sL "$FILES_URL_PREFIX/xray_config.json" -o "$DATA_DIR/xray_config.json"
colorized_echo green "File saved in $DATA_DIR/xray_config.json"

docker compose -f "$APP_DIR/docker-compose.yml" -p marzban up -d --remove-orphans

save_marzban_credentials

colorized_echo blue "Начинаем настройку REALITY..."
get_keys
create_config
restart_container
colorized_echo green "Настройка REALITY завершена"

colorized_echo blue "Начинаем установку Outline VPN..."
install_outline

colorized_echo green "Установка завершена!"
echo -e "###############################################"
colorized_echo green "Marzban доступен по адресу: http://127.0.0.1:${HTTP_PORT}/dashboard"
colorized_echo green "Данные для входа в Marzban сохранены в: $HOME/marzbandata.json"
colorized_echo green "Данные для Outline сохранены в: $HOME/outlinedata.json"
colorized_echo green "Ключи REALITY сохранены в: $DATA_DIR/pubkey.json и $DATA_DIR/shortid.json"
echo -e "###############################################"