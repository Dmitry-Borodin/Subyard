#!/usr/bin/env bash
# crypto.sh — age/SOPS encryption and OpenSSH revision signatures.

[ -n "${SUBYARD_CREDENTIAL_CRYPTO_SOURCED:-}" ] && return 0
SUBYARD_CREDENTIAL_CRYPTO_SOURCED=1

keys_sign_record() { # <record>
  local record="$1"
  rm -f "$record.sig"
  "$KEYS_SSH_KEYGEN" -Y sign -q -f "$KEYS_SIGN_KEY" -n subyard-keys "$record" >/dev/null
  [ -s "$record.sig" ] || die "could not sign credential revision"
}
keys_verify_record() { # <record>
  local record="$1" actor revision credential expected_rel counter expected_prefix actual_recipients expected_recipients recipient
  [ -s "$record.sig" ] || return 1
  "$KEYS_JQ" -e --argjson schema "$KEYS_SCHEMA_VERSION" '
    ([keys[]] - ["schemaVersion","credentialId","revisionId","label","kind","zone","scope",
      "consumer","syncable","exclusive","recipientActors","authorityHost","assignedYard",
      "assignmentEpoch","actorId","actorCounter","parents","timestamp","state","payload","sops"] | length)==0 and
    .schemaVersion == $schema and (.credentialId|test("^cred-[0-9a-f]{32}$")) and
    (.revisionId|type)=="string" and (.label|type)=="string" and (.label|length)>0 and (.label|length)<=128 and
    (.kind|test("^[A-Za-z0-9._-]+$")) and (.zone|test("^[A-Za-z0-9._-]+$")) and .zone!="." and .zone!=".." and
    .scope=="staging" and (.consumer=="none" or .consumer=="staging-env" or .consumer=="qa-secrets" or .consumer=="qa-pool") and
    (.actorId|test("^[A-Za-z0-9._-]+$")) and (.actorCounter|type)=="number" and
    (.actorCounter|floor)==.actorCounter and .actorCounter>0 and
    (.parents|type)=="array" and all(.parents[]; type=="string") and (.parents|length)==(.parents|unique|length) and
    (.recipientActors|type)=="array" and (.recipientActors|length)>0 and all(.recipientActors[]; type=="string") and
    (.recipientActors|length)==(.recipientActors|unique|length) and
    (.state=="active" or .state=="revoked" or .state=="tombstone") and
    (.syncable|type)=="boolean" and (.exclusive|type)=="boolean" and
    (.authorityHost|type)=="string" and (.authorityHost=="" or (.authorityHost|test("^[A-Za-z0-9._-]+$"))) and
    (.assignedYard|type)=="string" and (.assignedYard=="" or (.assignedYard|test("^[A-Za-z0-9._-]+/[a-z0-9][a-z0-9_-]*$"))) and
    (.assignmentEpoch|type)=="number" and (.assignmentEpoch|floor)==.assignmentEpoch and .assignmentEpoch>=0 and
    (.timestamp|type)=="string" and (.payload|type)=="string" and (.sops|type)=="object"
  ' "$record" >/dev/null 2>&1 || return 1
  actor="$("$KEYS_JQ" -r '.actorId' "$record")"
  revision="$("$KEYS_JQ" -r '.revisionId' "$record")"
  credential="$("$KEYS_JQ" -r '.credentialId' "$record")"
  counter="$("$KEYS_JQ" -r '.actorCounter' "$record")"
  case "$credential/$revision/$actor" in *[!A-Za-z0-9._/-]*) return 1 ;; esac
  expected_prefix="$actor-$(printf '%012d' "$counter")-"
  case "$revision" in "$expected_prefix"????????) ;; *) return 1 ;; esac
  expected_rel="records/$credential/$revision.json"
  case "$record" in */"$expected_rel") ;; *) return 1 ;; esac
  [ "$("$KEYS_JQ" -r '.recipientActors | length' "$record")" \
    = "$("$KEYS_JQ" -r '.recipientActors | unique | length' "$record")" ] || return 1
  expected_recipients=''
  while IFS= read -r recipient; do
    recipient="$(keys_recipient_for_actor "$recipient")" || return 1
    expected_recipients="${expected_recipients}${recipient}"$'\n'
  done < <("$KEYS_JQ" -r '.recipientActors[]' "$record")
  expected_recipients="$(printf '%s' "$expected_recipients" | sed '/^$/d' | sort -u)"
  actual_recipients="$("$KEYS_JQ" -r '.sops.age[].recipient' "$record" 2>/dev/null | sort -u)"
  [ -n "$actual_recipients" ] && [ "$actual_recipients" = "$expected_recipients" ] || return 1
  "$KEYS_SSH_KEYGEN" -Y verify -q -f "$KEYS_ALLOWED_SIGNERS" -I "$actor" \
    -n subyard-keys -s "$record.sig" < "$record" >/dev/null 2>&1 || return 1
  return 0
}

keys_decrypt_payload() { # <record> <output-file>
  local record="$1" output="$2" tmp
  tmp="$(mktemp)"; chmod 0600 "$tmp"
  keys_track_secret_temp "$tmp"; keys_track_secret_temp "$output"
  if ! SOPS_AGE_KEY_FILE="$KEYS_AGE_ID" "$KEYS_SOPS" decrypt \
      --input-type json --output-type json "$record" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  "$KEYS_JQ" -er '.payload' "$tmp" | base64 -d > "$output" || { rm -f "$tmp" "$output"; return 1; }
  chmod 0600 "$output"; rm -f "$tmp"
}
