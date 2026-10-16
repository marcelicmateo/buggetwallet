#!/usr/bin/env bash
# Local builds in a rootless Podman container. Runs the same steps as CI (.github/workflows/ci.yml).
#
#   tools/build.sh test     importer + core + app: analyze and tests
#   tools/build.sh apk      Android release APK   -> dist/BudgetWallet-android.apk
#   tools/build.sh linux    Linux release bundle  -> dist/BudgetWallet-linux-x64.tar.gz
#   tools/build.sh all      test, then apk and linux
#   tools/build.sh shell    interactive shell in the container
#   tools/build.sh image    (re)build the container image (first build ~15 min)
#
# The image is rebuilt automatically when dev/Containerfile or the Flutter version changes.
# The Flutter version comes from `environment: flutter:` in app/pubspec.yaml (CI reads the same line).
# Logs go to dist/logs/<step>.log; the exit code is non-zero if any step failed.
# BW_NATIVE=1 runs the steps directly on a machine that already has the right Flutter installed.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FLUTTER_VERSION=$(grep -oP '^\s+flutter:\s*"?\K[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/app/pubspec.yaml")
# Tag = Flutter version + Containerfile hash, so editing either rebuilds the image on the next run
IMAGE="localhost/budget-wallet-dev:$FLUTTER_VERSION-$(sha256sum "$ROOT/dev/Containerfile" | cut -c1-8)"
CMD=${1:-test}

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

# ---- host side: hand the command to the container ----
if [[ "${BW_NATIVE:-}" != 1 ]]; then
  build_image() { podman build --build-arg FLUTTER_VERSION="$FLUTTER_VERSION" -t "$IMAGE" "$ROOT/dev"; }
  case "$CMD" in
    image) build_image; exit ;;
    test|apk|linux|all|shell) ;;
    *) usage ;;
  esac
  podman image exists "$IMAGE" || build_image
  # Android release signing key (tools/make-signing-key.sh), mounted read-only
  SIGNING_DIR="${BW_SIGNING_DIR:-$HOME/.config/budget-wallet}"
  signing=()
  if [[ -f "$SIGNING_DIR/signing.env" ]]; then
    signing=(-v "$SIGNING_DIR:/signing:ro,z" --env-file "$SIGNING_DIR/signing.env" -e BW_KEYSTORE=/signing/android-release.jks)
  elif [[ "$CMD" == apk || "$CMD" == all ]]; then
    echo "No Android signing key in $SIGNING_DIR. Run tools/make-signing-key.sh first," >&2
    echo "otherwise the APK can't update the installed app." >&2
    exit 1
  fi
  tty=(); [[ -t 0 && -t 1 ]] && tty=(-it)
  inner=(tools/build.sh "$CMD"); [[ "$CMD" == shell ]] && inner=(bash)
  # Rootless: container root is the host user, so build outputs stay owned by you.
  # Named volumes keep the pub and Gradle caches between runs.
  exec podman run --rm "${tty[@]}" \
    -v "$ROOT:/work:z" \
    -v bw-pub-cache:/cache/pub \
    -v bw-gradle-cache:/cache/gradle \
    -v bw-android-user:/cache/android \
    "${signing[@]}" \
    -e BW_NATIVE=1 \
    -w /work "$IMAGE" "${inner[@]}"
fi

# ---- inside the container (or native) ----
cd "$ROOT"
LOGS="$ROOT/dist/logs"
mkdir -p "$LOGS"
results=()
failed=0

step() {
  local name=$1; shift
  echo "=== $name ==="
  if ( set -o pipefail; bash -c "$*" 2>&1 | tee "$LOGS/$name.log" ); then
    results+=("$name=ok")
  else
    results+=("$name=FAILED"); failed=1
  fi
}

run_tests() {
  step importer 'cd packages/wallet_importer && dart pub get && dart analyze && dart test'
  step core     'cd packages/wallet_core && dart pub get && dart analyze && dart test'
  step app      'cd app && flutter pub get && flutter analyze --no-fatal-infos && flutter test'
}
build_apk() {
  if [[ ! -f "${BW_KEYSTORE:-}" ]]; then
    echo "BW_KEYSTORE is not set to the release key; refusing to build an APK that can't update the app." >&2
    results+=("apk=FAILED"); failed=1; return
  fi
  step apk 'cd app && flutter build apk --release && cp build/app/outputs/flutter-apk/app-release.apk ../dist/BudgetWallet-android.apk'
  [[ $failed == 0 ]] && step apk-signature check_signature
}
# The APK must carry the release key's certificate, or Android refuses it as an update.
check_signature() {
  local want got apksigner
  want=$(keytool -list -v -keystore "$BW_KEYSTORE" -storepass "$BW_KEYSTORE_PASSWORD" -alias "$BW_KEY_ALIAS" \
    | grep -m1 -oP 'SHA256:\s*\K[0-9A-F:]+' | tr -d ':' | tr 'A-F' 'a-f')
  apksigner=$(ls "$ANDROID_HOME"/build-tools/*/apksigner | sort -V | tail -1)
  got=$("$apksigner" verify --print-certs dist/BudgetWallet-android.apk | grep -m1 -oP 'SHA-256 digest: \K[0-9a-f]+')
  echo "release key: $want"; echo "apk signer:  $got"
  [[ -n "$want" && "$want" == "$got" ]]
}
export -f check_signature
build_linux() {
  step linux 'cd app && flutter build linux --release && tar -C build/linux/x64/release -czf ../dist/BudgetWallet-linux-x64.tar.gz bundle'
}

case "$CMD" in
  test)  run_tests ;;
  apk)   build_apk ;;
  linux) build_linux ;;
  all)   run_tests; if [[ $failed == 0 ]]; then build_apk; build_linux; fi ;;
  *)     usage ;;
esac

echo
echo "${results[*]}"
exit $failed
