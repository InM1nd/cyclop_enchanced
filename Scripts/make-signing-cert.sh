#!/bin/bash
# Один раз заводит в login-связке самоподписанный сертификат для подписи кода.
# Ad-hoc подпись меняет «личность» приложения при каждой сборке: macOS видит
# новое приложение и заново спрашивает Accessibility, календарь, доступ к
# Keychain. С постоянным сертификатом личность одна и та же от сборки к сборке.
# Доверять сертификату в системе не нужно — codesign подписывает им и так.
set -euo pipefail

NAME="${CYCLOP_SIGN_IDENTITY:-Cyclop Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "==> «${NAME}» уже есть в связке — ничего не делаю"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> создаю сертификат «${NAME}»"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

# LibreSSL из /usr/bin пакует p12 в формате, который понимает security;
# OpenSSL 3 из Homebrew по умолчанию — нет.
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/id.p12" -passout pass:cyclop

# -T сразу пускает codesign к ключу, без диалога при каждой сборке.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P cyclop -T /usr/bin/codesign

echo "==> готово. Дальше ./Scripts/bundle.sh подписывает этим сертификатом"
