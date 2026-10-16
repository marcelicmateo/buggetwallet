#!/usr/bin/env bash
# Creates the one Android signing key every release build uses (local and CI), so updates install
# over the existing app instead of needing an uninstall that wipes the wallet.
#
#   tools/make-signing-key.sh            create the key in ~/.config/budget-wallet/ (refuses to overwrite)
#   tools/make-signing-key.sh --upload   also store it as GitHub Actions secrets for CI
#
# The key never goes into git. Back up the whole ~/.config/budget-wallet/ folder (e.g. in a password
# manager): if the key is lost, the next APK can't update the installed app.
set -euo pipefail

DIR="${BW_SIGNING_DIR:-$HOME/.config/budget-wallet}"
KEYSTORE="$DIR/android-release.jks"
ENVFILE="$DIR/signing.env"
ALIAS=budget-wallet

if [[ -e "$KEYSTORE" || -e "$ENVFILE" ]]; then
  echo "Signing key already exists in $DIR — not overwriting it."
else
  mkdir -p "$DIR" && chmod 700 "$DIR"
  pass=$(head -c 24 /dev/urandom | base64 | tr -d '/+=')
  keytool -genkeypair -keystore "$KEYSTORE" -storetype PKCS12 -alias "$ALIAS" \
    -keyalg RSA -keysize 4096 -validity 20000 -dname "CN=Budget Wallet" \
    -storepass "$pass" -keypass "$pass" >/dev/null
  umask 077
  printf 'BW_KEY_ALIAS=%s\nBW_KEYSTORE_PASSWORD=%s\nBW_KEY_PASSWORD=%s\n' "$ALIAS" "$pass" "$pass" > "$ENVFILE"
  chmod 600 "$KEYSTORE" "$ENVFILE"
  echo "Created $KEYSTORE"
fi
keytool -list -keystore "$KEYSTORE" -storepass "$(grep -oP '^BW_KEYSTORE_PASSWORD=\K.*' "$ENVFILE")" -v \
  | grep -m1 'SHA256:' | sed 's/^\s*/Certificate /'

if [[ "${1:-}" == --upload ]]; then
  # shellcheck disable=SC1090
  source "$ENVFILE"
  base64 -w0 "$KEYSTORE" | gh secret set ANDROID_KEYSTORE_BASE64
  printf '%s' "$BW_KEYSTORE_PASSWORD" | gh secret set ANDROID_KEYSTORE_PASSWORD
  printf '%s' "$BW_KEY_ALIAS" | gh secret set ANDROID_KEY_ALIAS
  echo "Uploaded to GitHub Actions secrets: ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS"
fi
