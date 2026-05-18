#!/usr/bin/env bash
# Zitadel REST helpers. Uses the SA bearer token from 1P.

zitadel::_token() {
  op::read_field "${KVASIR_OP_ZITADEL_SA_ITEM}" credential
}

zitadel::_base() { echo "https://${KVASIR_ZITADEL_HOST}"; }

# GET. Args: <path>     (e.g. /v2/users/me)
zitadel::get() {
  local path="$1"
  curl -fsS -H "Authorization: Bearer $(zitadel::_token)" \
       "$(zitadel::_base)${path}"
}

# POST with JSON body. Args: <path> <json>
zitadel::post() {
  local path="$1" body="$2"
  if kvasir::is_dry_run; then
    kvasir::log info "DRY: POST ${path} body=$(jq -c <<<"$body")"
    return 0
  fi
  curl -fsS -X POST \
       -H "Authorization: Bearer $(zitadel::_token)" \
       -H "Content-Type: application/json" \
       -d "$body" \
       "$(zitadel::_base)${path}"
}

# PUT with JSON body. Args: <path> <json>
zitadel::put() {
  local path="$1" body="$2"
  if kvasir::is_dry_run; then
    kvasir::log info "DRY: PUT ${path} body=$(jq -c <<<"$body")"
    return 0
  fi
  curl -fsS -X PUT \
       -H "Authorization: Bearer $(zitadel::_token)" \
       -H "Content-Type: application/json" \
       -d "$body" \
       "$(zitadel::_base)${path}"
}

# Resolve a Zitadel user by login-name (loginNames array contains it).
# Echoes user id or empty string if not found. Always read-only.
zitadel::user_id_by_loginname() {
  local login="$1"
  local body
  body=$(jq -nc --arg ln "$login" \
    '{queries:[{loginNameQuery:{loginName:$ln,method:"TEXT_QUERY_METHOD_EQUALS"}}]}')
  curl -fsS -X POST \
       -H "Authorization: Bearer $(zitadel::_token)" \
       -H "Content-Type: application/json" \
       -d "$body" \
       "$(zitadel::_base)/v2/users" \
    | jq -r '.result[0].userId // ""'
}

# Create a human user. Args: <username> <email> <first> <last>
# Echoes the new userId on success.
zitadel::user_create() {
  local user="$1" email="$2" first="$3" last="$4"
  local existing
  existing=$(zitadel::user_id_by_loginname "$user")
  if [[ -n "$existing" ]]; then
    kvasir::log warn "zitadel user already exists: ${user} (id=${existing})"
    echo "$existing"
    return 0
  fi
  local body
  body=$(jq -nc \
    --arg u  "$user" \
    --arg e  "$email" \
    --arg f  "$first" \
    --arg l  "$last" \
    '{username:$u,
      profile:{givenName:$f, familyName:$l, displayName:($f+" "+$l)},
      email:{email:$e, isVerified:true}}')
  if kvasir::is_dry_run; then
    kvasir::log info "DRY: zitadel POST /v2/users/human  username=${user}"
    echo "DRYRUN-USERID"
    return 0
  fi
  zitadel::post "/v2/users/human" "$body" | jq -r '.userId'
}
