#!/usr/bin/env bash
set -euo pipefail
umask 077

CLI="${KUBECTL:-kubectl}"
NAMESPACE="${NAMESPACE:-vvp-system}"
RELEASE="${RELEASE:-ververica-platform}"
SECRET="vvp-license-fingerprint"
LICENSE_FILE="${1:-30-values-vvp.yaml}"
TOKEN_FILE="${INSTALLATION_TOKEN_FILE:-.work/installation-token.txt}"

for bin in "$CLI" yq jq base64; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: missing command: $bin" >&2; exit 1; }
done
[[ -f "$LICENSE_FILE" ]] || { echo "ERROR: license file not found: $LICENSE_FILE" >&2; exit 1; }

license_token="$(yq -r '.global.vvp.license.data.spec.params.token // ""' "$LICENSE_FILE")"
license_id="$(yq -r '.global.vvp.license.data.spec.licenseId // ""' "$LICENSE_FILE")"
metadata_id="$(yq -r '.global.vvp.license.data.metadata.id // ""' "$LICENSE_FILE")"
license_spec_b64="$(yq -r '.global.vvp.license.data.metadata.annotations.licenseSpec // ""' "$LICENSE_FILE")"
signature_b64="$(yq -r '.global.vvp.license.data.metadata.annotations.signature // ""' "$LICENSE_FILE")"

[[ -n "$license_token" && "$license_token" != "null" ]] || { echo "ERROR: missing license token" >&2; exit 1; }
[[ -n "$license_id" && "$license_id" == "$metadata_id" ]] || { echo "ERROR: metadata.id != spec.licenseId" >&2; exit 1; }
[[ -n "$license_spec_b64" && "$license_spec_b64" != "null" ]] || { echo "ERROR: missing licenseSpec" >&2; exit 1; }
[[ -n "$signature_b64" && "$signature_b64" != "null" ]] || { echo "ERROR: missing signature" >&2; exit 1; }

spec_json="$(yq -o=json '.global.vvp.license.data.spec' "$LICENSE_FILE" | jq -S -c .)"
decoded_spec_json="$(printf '%s' "$license_spec_b64" | base64 -d | jq -S -c .)" || {
  echo "ERROR: licenseSpec is not valid base64 JSON" >&2; exit 1;
}
printf '%s' "$signature_b64" | base64 -d >/dev/null || {
  echo "ERROR: signature is not valid base64" >&2; exit 1;
}
[[ "$spec_json" == "$decoded_spec_json" ]] || {
  echo "ERROR: decoded licenseSpec does not match spec; use the vendor-supplied license unchanged" >&2; exit 1;
}

secret_json="$("$CLI" get secret "$SECRET" -n "$NAMESPACE" --ignore-not-found=true -o json)" || {
  echo "ERROR: unable to read fingerprint Secret; refusing license activation" >&2
  exit 1
}
cluster_token=""
if [[ -n "$secret_json" ]]; then
  cluster_token="$(printf '%s' "$secret_json" | jq -er '.data.fingerprint | select(type == "string" and length > 0)' | base64 -d)" || {
    echo "ERROR: fingerprint Secret has invalid JSON, missing fingerprint, or invalid base64" >&2
    exit 1
  }
else
  if [[ -n "${INSTALLATION_TOKEN:-}" ]]; then
    cluster_token="$INSTALLATION_TOKEN"
  elif [[ -s "$TOKEN_FILE" ]]; then
    cluster_token="$(tr -d '\r\n' < "$TOKEN_FILE")"
  else
    echo "ERROR: $SECRET does not exist and no saved installation token was provided." >&2
    echo "Set INSTALLATION_TOKEN or save it in $TOKEN_FILE before proceeding." >&2
    exit 1
  fi
fi

[[ "$license_token" == "$cluster_token" ]] || {
  echo "ERROR: license token does not match this installation fingerprint/token" >&2
  exit 1
}

echo "PASS: licenseSpec == spec"
echo "PASS: license token matches this installation"
echo "License ID: $license_id"

label_json="$("$CLI" get secrets -n "$NAMESPACE" -l name=vvp-license-fingerprint -o json)" || {
  echo "ERROR: unable to list fingerprint Secrets; refusing license activation" >&2
  exit 1
}
label_matches="$(printf '%s' "$label_json" | jq -er '.items | select(type == "array") | length')" || {
  echo "ERROR: invalid fingerprint Secret list response" >&2
  exit 1
}
if (( label_matches > 1 )); then
  echo "ERROR: more than one Secret has label name=vvp-license-fingerprint" >&2
  exit 1
fi
if (( label_matches == 1 )); then
  labeled_name="$(printf '%s' "$label_json" | jq -er '.items[0].metadata.name')"
  [[ "$labeled_name" == "$SECRET" ]] || {
    echo "ERROR: label name=vvp-license-fingerprint belongs to unexpected Secret '$labeled_name'" >&2; exit 1;
  }
fi

if [[ -z "$secret_json" ]]; then
  echo "PASS: fingerprint Secret is absent; no Helm adoption is required."
  echo "The VVP 3.1.3 chart will render the Secret from the inline license token."
  exit 0
fi

owner_release="$(printf '%s' "$secret_json" | jq -r '.metadata.annotations["meta.helm.sh/release-name"] // ""')"
owner_namespace="$(printf '%s' "$secret_json" | jq -r '.metadata.annotations["meta.helm.sh/release-namespace"] // ""')"
manager="$(printf '%s' "$secret_json" | jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""')"

[[ -z "$owner_release" || "$owner_release" == "$RELEASE" ]] || {
  echo "ERROR: Secret belongs to Helm release '$owner_release', expected '$RELEASE'" >&2; exit 1;
}
[[ -z "$owner_namespace" || "$owner_namespace" == "$NAMESPACE" ]] || {
  echo "ERROR: Secret belongs to Helm namespace '$owner_namespace', expected '$NAMESPACE'" >&2; exit 1;
}
[[ -z "$manager" || "$manager" == "Helm" ]] || {
  echo "ERROR: Secret managed-by='$manager'; inspect ownership before adoption" >&2; exit 1;
}

mkdir -p backups
printf '%s\n' "$secret_json" > "backups/${SECRET}-$(date -u +%Y%m%dT%H%M%SZ).yaml"

"$CLI" label secret "$SECRET" -n "$NAMESPACE" \
  name=vvp-license-fingerprint \
  app.kubernetes.io/managed-by=Helm \
  --overwrite

"$CLI" annotate secret "$SECRET" -n "$NAMESPACE" \
  meta.helm.sh/release-name="$RELEASE" \
  meta.helm.sh/release-namespace="$NAMESPACE" \
  --overwrite

echo "PASS: fingerprint Secret adopted by Helm release $RELEASE/$NAMESPACE; data was not changed"
