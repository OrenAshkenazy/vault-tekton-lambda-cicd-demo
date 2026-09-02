#!/usr/bin/env bash
set -euo pipefail

: "${VAULT_ADDR:?VAULT_ADDR is required}"
: "${VAULT_ROLE:?VAULT_ROLE is required}"
: "${VAULT_AWS_ROLE:?VAULT_AWS_ROLE is required}"
: "${S3_BUCKET:?S3_BUCKET is required}"
: "${AWS_REGION:?AWS_REGION is required}"
: "${RUN_ID:?RUN_ID is required}"

readonly service_account_token="${SERVICE_ACCOUNT_TOKEN_FILE:-/var/run/secrets/kubernetes.io/serviceaccount/token}"
readonly allowed_key="events/${RUN_ID}.svg"
readonly denied_key="private/${RUN_ID}.svg"
readonly camera_image=/event/camera-frame.svg

cleanup() {
  unset VAULT_TOKEN AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
}
trap cleanup EXIT

echo "1/6 Authenticating the simulated on-prem gateway to Vault"
login_json="$(vault write -format=json auth/kubernetes/login \
  role="${VAULT_ROLE}" \
  jwt="@${service_account_token}")"
export VAULT_TOKEN="$(jq -er '.auth.client_token' <<<"${login_json}")"
unset login_json

echo "2/6 Requesting a leased AWS assumed-role credential"
credentials_json="$(vault read -format=json "aws/creds/${VAULT_AWS_ROLE}")"
lease_id="$(jq -er '.lease_id' <<<"${credentials_json}")"
lease_ttl="$(jq -er '.lease_duration' <<<"${credentials_json}")"
assumed_role_arn="$(jq -er '.data.arn' <<<"${credentials_json}")"
export AWS_ACCESS_KEY_ID="$(jq -er '.data.access_key' <<<"${credentials_json}")"
export AWS_SECRET_ACCESS_KEY="$(jq -er '.data.secret_key' <<<"${credentials_json}")"
export AWS_SESSION_TOKEN="$(jq -er '.data.security_token // .data.session_token' <<<"${credentials_json}")"
unset credentials_json VAULT_TOKEN

printf 'AUDIT Vault lease: %s\n' "${lease_id}"
printf 'AUDIT Lease TTL: %ss\n' "${lease_ttl}"
printf 'AUDIT Vault returned: %s\n' "${assumed_role_arn}"

caller_arn="$(aws sts get-caller-identity \
  --region "${AWS_REGION}" \
  --query Arn \
  --output text)"
printf 'AUDIT AWS caller: %s\n' "${caller_arn}"

echo "3/6 Allowed operation: PutObject to s3://${S3_BUCKET}/${allowed_key}"
aws s3api put-object \
  --region "${AWS_REGION}" \
  --bucket "${S3_BUCKET}" \
  --key "${allowed_key}" \
  --body "${camera_image}" \
  --content-type image/svg+xml >/dev/null
echo "PROOF synthetic camera image uploaded to events/*: PASS"

echo "4/6 Negative operation: PutObject outside events/*"
if aws s3api put-object \
  --region "${AWS_REGION}" \
  --bucket "${S3_BUCKET}" \
  --key "${denied_key}" \
  --body "${camera_image}" \
  --content-type image/svg+xml >/dev/null 2>/tmp/denied-put.log; then
  echo "PROOF denied PutObject outside events/*: FAIL (unexpectedly allowed)" >&2
  exit 1
fi
grep -q 'AccessDenied' /tmp/denied-put.log
echo "PROOF denied PutObject outside events/*: PASS (AccessDenied)"

echo "5/6 Negative operation: GetObject read-back"
if aws s3api get-object \
  --region "${AWS_REGION}" \
  --bucket "${S3_BUCKET}" \
  --key "${allowed_key}" \
  /tmp/read-back.svg >/dev/null 2>/tmp/denied-get.log; then
  echo "PROOF denied GetObject read-back: FAIL (unexpectedly allowed)" >&2
  exit 1
fi
grep -q 'AccessDenied' /tmp/denied-get.log
echo "PROOF denied GetObject read-back: PASS (AccessDenied)"

echo "6/6 Security contract proven"
echo "RESULT Compromise it and you can write one prefix, never read the gallery back."
