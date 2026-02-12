#!/usr/bin/env bash
set -euo pipefail

VAULT_NAME="sops-sync"

while [[ $# -gt 0 ]]; do
  case "$1" in
  -v | --vault)
    VAULT_NAME="$2"
    shift 2
    ;;
  -h | --help)
    echo "usage: $0 [-v vault] <sops-file>"
    exit 0
    ;;
  -*)
    echo "error: unknown option $1" >&2
    exit 1
    ;;
  *)
    SOPS_FILE="$1"
    shift
    ;;
  esac
done

[[ -n "${SOPS_FILE:-}" ]] || {
  echo "error: no sops file specified" >&2
  exit 1
}
[[ -f "$SOPS_FILE" ]] || {
  echo "error: $SOPS_FILE not found" >&2
  exit 1
}

require() { command -v "$1" >/dev/null 2>&1 || {
  echo "error: $1 not found" >&2
  exit 1
}; }
require sops
require pass-cli
require jq

is_authenticated() {
  pass-cli test >/dev/null 2>&1 || pass-cli info >/dev/null 2>&1
}

is_ssh_key() {
  [[ "$1" == *"BEGIN OPENSSH PRIVATE KEY"* ]] ||
    [[ "$1" == *"BEGIN RSA PRIVATE KEY"* ]] ||
    [[ "$1" == *"BEGIN EC PRIVATE KEY"* ]]
}

decrypt_and_flatten() {
  sops -d --output-type json "$1" | jq -r '
        path(.. | select(type == "string" or type == "number" or type == "boolean")) as $p
        | select($p[0] != "sops")
        | ($p | map(tostring) | join("/")) + "\t" + (getpath($p) | tostring | @base64)
    '
}

create_ssh_key_item() {
  local title="$1" value="$2"
  local keyfile="$TMPDIR/$(printf '%s' "$title" | tr '/' '_')"

  printf '%s\n' "$value" >"$keyfile"
  chmod 600 "$keyfile"

  if pass-cli item create ssh-key import \
    --from-private-key "$keyfile" \
    --vault-name "$VAULT_NAME" \
    --title "$title" >/dev/null 2>&1; then
    echo "  + $title (ssh-key)"
  else
    echo "  ssh-key import failed for $title, storing as login" >&2
    create_login_item "$title" "$value"
  fi

  shred -u "$keyfile" 2>/dev/null || rm -f "$keyfile"
}

create_login_item() {
  local title="$1" value="$2"

  if jq -n --arg title "$title" --arg password "$value" \
    '{"title":$title,"password":$password}' |
    pass-cli item create login \
      --vault-name "$VAULT_NAME" \
      --from-template - >/dev/null 2>&1; then
    echo "  + $title"
  else
    echo "  failed: $title" >&2
    FAILED=1
  fi
}

is_authenticated || {
  echo "error: not authenticated (run: pass-cli login)" >&2
  exit 1
}

echo "decrypting $SOPS_FILE"
SECRETS=$(decrypt_and_flatten "$SOPS_FILE")

SECRET_COUNT=$(printf '%s' "$SECRETS" | grep -c . || true)
echo "found $SECRET_COUNT secret(s)"
[[ "$SECRET_COUNT" -gt 0 ]] || exit 0

# delete and recreate the vault
echo "recreating vault: $VAULT_NAME"
pass-cli vault delete --vault-name "$VAULT_NAME" >/dev/null 2>&1 || true
pass-cli vault create --name "$VAULT_NAME" >/dev/null

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

FAILED=0

echo "syncing $SECRET_COUNT secret(s)"
while IFS=$'\t' read -r key value_b64; do
  value=$(printf '%s' "$value_b64" | base64 -d)
  if is_ssh_key "$value"; then
    create_ssh_key_item "$key" "$value"
  else
    create_login_item "$key" "$value"
  fi
done < <(printf '%s\n' "$SECRETS")

echo "done"
[[ "$FAILED" -eq 0 ]]
