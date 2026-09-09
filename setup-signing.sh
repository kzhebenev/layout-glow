#!/bin/bash
# Создаёт постоянный самоподписанный сертификат для подписи LayoutGlow.
# Без него каждая пересборка меняет хеш бинарника, и macOS сбрасывает
# выданные разрешения (Input Monitoring, Accessibility).
# Запускается один раз на каждом маке. Пароль админа не требуется.
set -euo pipefail

SUPPORT="$HOME/Library/Application Support/LayoutGlow"
KEYCHAIN="$HOME/Library/Keychains/layoutglow.keychain-db"
KC_NAME="layoutglow.keychain"
PASSFILE="$SUPPORT/signing.pass"
CN="LayoutGlow Self-Signed"

# Пароль мог остаться в основной связке, если файл потерялся
if [ ! -f "$PASSFILE" ]; then
    RECOVERED=$(security find-generic-password -s ru.devkz.layoutglow.signing -w 2>/dev/null || true)
    if [ -n "$RECOVERED" ]; then
        mkdir -p "$SUPPORT"
        umask 077
        printf '%s' "$RECOVERED" > "$PASSFILE"
        echo "Пароль подписи восстановлен из связки ключей."
    fi
fi

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CN"; then
    if [ -f "$PASSFILE" ] && security unlock-keychain -p "$(cat "$PASSFILE")" "$KEYCHAIN" 2>/dev/null; then
        echo "Сертификат «$CN» уже есть."
        exit 0
    fi
    echo "Связка есть, но пароль утерян — пересоздаю сертификат."
    echo "После этого macOS попросит заново выдать разрешения приложению."
    security delete-keychain "$KC_NAME" 2>/dev/null || security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    rm -f "$KEYCHAIN"
fi

mkdir -p "$SUPPORT"
umask 077
if [ ! -f "$PASSFILE" ]; then
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 > "$PASSFILE"
fi
PASS="$(cat "$PASSFILE")"

# Дубликат пароля в основной связке: файл в Application Support может
# исчезнуть при переносе проекта, и тогда сертификат становится мусором
security add-generic-password -U -s ru.devkz.layoutglow.signing -a signing -w "$PASS" 2>/dev/null || true

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$CN" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# LibreSSL: формат PKCS12, совместимый с импортом в macOS Keychain
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -name "$CN" -passout "pass:$PASS" \
    -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES 2>/dev/null

if [ ! -f "$KEYCHAIN" ]; then
    security create-keychain -p "$PASS" "$KC_NAME"
fi
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"          # без автоблокировки по таймауту
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$PASS" -A -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null 2>&1

# Добавляем связку в пользовательский список поиска, чтобы codesign её видел
CURRENT=$(security list-keychains -d user | tr -d '"' | xargs)
case "$CURRENT" in
    *layoutglow*) ;;
    *) security list-keychains -d user -s $CURRENT "$KEYCHAIN" ;;
esac

# Доверие для подписи кода (пользовательский домен, без пароля админа)
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null \
    || echo "Предупреждение: не удалось выставить доверие, подпись может не пройти."

echo "Сертификат «$CN» создан."
