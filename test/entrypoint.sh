#!/usr/bin/env bash
set -euo pipefail

readonly root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT
mkdir "${test_dir}/bin"
printf 'synthetic-token' >"${test_dir}/service-account-token"

cat >"${test_dir}/bin/vault" <<'VAULT'
#!/usr/bin/env bash
if [[ "$1" == write ]]; then
  printf '%s\n' '{"auth":{"client_token":"MOCK_VAULT_TOKEN"}}'
else
  printf '%s\n' '{"lease_id":"aws/creds/camera-uploader/mock","lease_duration":900,"data":{"arn":"arn:aws:sts::123456789012:assumed-role/VaultTektonDemoCameraUploader/mock","access_key":"MOCK_ACCESS_KEY","secret_key":"MOCK_SECRET","security_token":"MOCK_SESSION"}}'
fi
VAULT

cat >"${test_dir}/bin/aws" <<'AWS'
#!/usr/bin/env bash
if [[ "$1 $2" == 'sts get-caller-identity' ]]; then
  echo 'arn:aws:sts::123456789012:assumed-role/VaultTektonDemoCameraUploader/mock'
  exit 0
fi
if [[ "$1 $2" == 's3api put-object' && "$*" == *'private/'* ]]; then
  echo 'An error occurred (AccessDenied)' >&2
  exit 254
fi
if [[ "$1 $2" == 's3api get-object' ]]; then
  echo 'An error occurred (AccessDenied)' >&2
  exit 254
fi
exit 0
AWS

chmod +x "${test_dir}/bin/vault" "${test_dir}/bin/aws"

output="$(
  PATH="${test_dir}/bin:${PATH}" \
  SERVICE_ACCOUNT_TOKEN_FILE="${test_dir}/service-account-token" \
  VAULT_ADDR=http://vault.test:8200 \
  VAULT_ROLE=camera-gateway \
  VAULT_AWS_ROLE=camera-uploader \
  S3_BUCKET=vault-tekton-demo-test-il-central-1 \
  AWS_REGION=il-central-1 \
  RUN_ID=test \
  "${root_dir}/app/entrypoint.sh"
)"

grep -Fq 'PROOF allowed PutObject inside events/*: PASS' <<<"${output}"
grep -Fq 'PROOF denied PutObject outside events/*: PASS (AccessDenied)' <<<"${output}"
grep -Fq 'PROOF denied GetObject read-back: PASS (AccessDenied)' <<<"${output}"
grep -Fq 'AUDIT Lease TTL: 900s' <<<"${output}"
if grep -Eq 'MOCK_SECRET|MOCK_SESSION|MOCK_VAULT_TOKEN' <<<"${output}"; then
  echo 'Credential leaked to output' >&2
  exit 1
fi
echo 'Entrypoint security checks passed'
