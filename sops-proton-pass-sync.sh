#!/usr/bin/env bash
set -euo pipefail

VAULT_NAME="sops-sync"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/sops-pass-sync"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--vault) VAULT_NAME="$2"; shift 2 ;;
    -h|--help)  echo "usage: $0 [-v vault] <sops-file>"; exit 0 ;;
    -*)         echo "error: unknown option $1" >&2; exit 1 ;;
    *)          SOPS_FILE="$1"; shift ;;
  esac
done

[[ -n "${SOPS_FILE:-}" ]] || { echo "error: no sops file specified" >&2; exit 1; }
[[ -f "$SOPS_FILE" ]]     || { echo "error: $SOPS_FILE not found" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || { echo "error: $1 not found" >&2; exit 1; }; }
require sops
require pass-cli
require jq

pass-cli test >/dev/null 2>&1 || pass-cli info >/dev/null 2>&1 \
  || { echo "error: not authenticated (run: pass-cli login)" >&2; exit 1; }

# detect keys by their header
is_ssh_key() {
  [[ "$1" == *"BEGIN OPENSSH PRIVATE KEY"* ]] ||
  [[ "$1" == *"BEGIN RSA PRIVATE KEY"* ]]     ||
  [[ "$1" == *"BEGIN EC PRIVATE KEY"* ]]
}

# decrypt the sops file and flatten all nested keys into path/style/names
# values are base64-encoded so multi-line secrets (keys, certs, etc) don't
# break the line-by-line reading later
decrypt_and_flatten() {
  sops -d --output-type json "$1" | jq -r '
    path(.. | select(type == "string" or type == "number" or type == "boolean")) as $p
    | select($p[0] != "sops")
    | ($p | map(tostring) | join("/")) + "\t" + (getpath($p) | tostring | @base64)
  '
}

get_value() {
  local key_id
  key_id=$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)
  cat "$WORK/val_$key_id"
}

# write the key to a temp file and import it as a native ssh-key item
# falls back to a login item if the import fails for whatever reason
create_ssh_item() {
  local title="$1" value="$2"
  local keyfile="$WORK/$(printf '%s' "$title" | tr '/' '_').key"

  printf '%s\n' "$value" > "$keyfile"
  chmod 600 "$keyfile"

  if pass-cli item create ssh-key import \
      --from-private-key "$keyfile" \
      --vault-name "$VAULT_NAME" \
      --title "$title" >/dev/null 2>&1; then
    echo "  + $title (ssh-key)"
  else
    echo "  ssh-key import failed, storing as login" >&2
    create_login_item "$title" "$value"
  fi

  shred -u "$keyfile" 2>/dev/null || rm -f "$keyfile"
}

# pass the value via json on stdin via --from-template
# this avoids argument parsing issues with values starting with dashes,
# or other weird characters
create_login_item() {
  local title="$1" value="$2"

  if jq -n --arg title "$title" --arg password "$value" \
      '{"title":$title,"password":$password}' |
      pass-cli item create login \
        --vault-name "$VAULT_NAME" \
        --from-template - >/dev/null 2>&1; then
    echo "  + $title"
  else
    echo "  FAILED: $title" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

create_item() {
  local title="$1" value="$2"
  if is_ssh_key "$value"; then
    create_ssh_item "$title" "$value"
  else
    create_login_item "$title" "$value"
  fi
}

delete_item() {
  local title="$1" share_id="$2" item_id="$3"
  if pass-cli item delete --share-id "$share_id" --item-id "$item_id" >/dev/null 2>&1; then
    echo "  - $title"
  else
    echo "  FAILED to delete: $title" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

# setup temp workspace
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ERRORS=0

# 1. decrypt and build state
echo "decrypting $SOPS_FILE..."
SECRETS_TSV="$WORK/secrets.tsv"
decrypt_and_flatten "$SOPS_FILE" > "$SECRETS_TSV"

SECRET_COUNT=$(grep -c . "$SECRETS_TSV" || true)
echo "found $SECRET_COUNT secret(s)"
[[ "$SECRET_COUNT" -gt 0 ]] || { echo "nothing to sync"; exit 0; }

# { "key": { "hash": "sha256", "is_ssh": bool }, ... }
# decrypted values are stashed to disk for retrieval during creation
while IFS=$'\t' read -r key value_b64; do
  [[ -n "$key" ]] || continue

  value=$(printf '%s' "$value_b64" | base64 -d)
  key_id=$(printf '%s' "$key" | sha256sum | cut -d' ' -f1)
  printf '%s' "$value" > "$WORK/val_$key_id"

  hash=$(printf '%s' "$value_b64" | sha256sum | cut -d' ' -f1)
  ssh=false; is_ssh_key "$value" && ssh=true

  jq -cn --arg k "$key" --arg h "$hash" --argjson s "$ssh" \
    '{($k): {hash: $h, is_ssh: $s}}'
done < "$SECRETS_TSV" | jq -s 'add // {}' > "$WORK/desired.json"

# 2. load hash cache and vault contents
HASH_FILE="$CACHE_DIR/${VAULT_NAME}.json"
mkdir -p "$CACHE_DIR"
[[ -f "$HASH_FILE" ]] && cp "$HASH_FILE" "$WORK/old_hashes.json" \
                       || echo '{}' > "$WORK/old_hashes.json"

if pass-cli item list "$VAULT_NAME" --output json > "$WORK/vault_raw.json" 2>/dev/null; then
  jq '
    (.items // [])
    | map({key: .content.title, value: {share_id: .share_id, item_id: .id}})
    | from_entries
  ' "$WORK/vault_raw.json" > "$WORK/vault.json" 2>/dev/null \
    || echo '{}' > "$WORK/vault.json"
else
  echo "creating vault: $VAULT_NAME"
  pass-cli vault create --name "$VAULT_NAME" >/dev/null
  echo '{}' > "$WORK/vault.json"
fi

# 3. sync
CREATED=0; UPDATED=0; DELETED=0; SKIPPED=0

while read -r key; do
  new_hash=$(jq -r --arg k "$key" '.[$k].hash' "$WORK/desired.json")
  old_hash=$(jq -r --arg k "$key" '.[$k] // empty'  "$WORK/old_hashes.json")
  in_vault=$(jq -e --arg k "$key" 'has($k)' "$WORK/vault.json" >/dev/null 2>&1 && echo yes || echo no)

  if [[ "$in_vault" == "no" ]]; then
    create_item "$key" "$(get_value "$key")"
    CREATED=$((CREATED + 1))

  elif [[ "$new_hash" == "$old_hash" ]]; then
    SKIPPED=$((SKIPPED + 1))

  else
    # if value changed or first run then delete and recreate
    share_id=$(jq -r --arg k "$key" '.[$k].share_id' "$WORK/vault.json")
    item_id=$(jq  -r --arg k "$key" '.[$k].item_id'  "$WORK/vault.json")

    delete_item "$key" "$share_id" "$item_id"
    create_item "$key" "$(get_value "$key")"
    UPDATED=$((UPDATED + 1))
  fi
done < <(jq -r 'keys[]' "$WORK/desired.json")

# remove items no longer in sops
while read -r key; do
  in_desired=$(jq -e --arg k "$key" 'has($k)' "$WORK/desired.json" >/dev/null 2>&1 && echo yes || echo no)

  if [[ "$in_desired" == "no" ]]; then
    share_id=$(jq -r --arg k "$key" '.[$k].share_id' "$WORK/vault.json")
    item_id=$(jq  -r --arg k "$key" '.[$k].item_id'  "$WORK/vault.json")

    delete_item "$key" "$share_id" "$item_id"
    DELETED=$((DELETED + 1))
  fi
done < <(jq -r 'keys[]' "$WORK/vault.json")

# 4. persist hash cache
jq 'map_values(.hash)' "$WORK/desired.json" > "$HASH_FILE"

echo "done: $CREATED created, $UPDATED updated, $DELETED deleted, $SKIPPED unchanged"
[[ "$ERRORS" -eq 0 ]] || { echo "$ERRORS error(s) occurred" >&2; exit 1; }
