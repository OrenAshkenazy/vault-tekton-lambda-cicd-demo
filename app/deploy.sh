#!/usr/bin/env bash
set -euo pipefail

: "${VAULT_ADDR:?VAULT_ADDR is required}"
: "${AWS_REGION:?AWS_REGION is required}"
: "${DEPLOYMENT_BUCKET:?DEPLOYMENT_BUCKET is required}"
: "${LAMBDA_EXECUTION_ROLE_ARN:?LAMBDA_EXECUTION_ROLE_ARN is required}"
: "${SOURCE_DIR:?SOURCE_DIR is required}"
: "${SERVERLESS_TEMPLATE:?SERVERLESS_TEMPLATE is required}"
: "${GIT_SHA:?GIT_SHA is required}"

[[ "${GIT_SHA}" =~ ^[0-9a-f]{7,40}$ ]] || {
  echo "GIT_SHA must be a 7-40 character lowercase hexadecimal revision" >&2
  exit 1
}
[[ -f "${SOURCE_DIR}/processor/handler.py" && -f "${SERVERLESS_TEMPLATE}" ]] || {
  echo "Lambda handler or trusted Serverless template is missing" >&2
  exit 1
}

readonly service_account_token="${SERVICE_ACCOUNT_TOKEN_FILE:-/var/run/secrets/kubernetes.io/serviceaccount/token}"
readonly function_name="${LAMBDA_FUNCTION_NAME:-vault-tekton-lambda-cicd}"
deploy_dir="$(mktemp -d)"

cleanup() {
  unset VAULT_TOKEN AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  rm -rf "${deploy_dir}"
}
trap cleanup EXIT

echo "1/5 Authenticating the Tekton deployment Task to Vault"
login_json="$(vault write -format=json auth/kubernetes/login \
  role=tekton-lambda-deployer \
  jwt="@${service_account_token}")"
export VAULT_TOKEN="$(jq -er '.auth.client_token' <<<"${login_json}")"
unset login_json

echo "2/5 Requesting a leased AWS deployment credential"
credentials_json="$(vault read -format=json aws/creds/lambda-deployer)"
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

echo "3/5 Proving the deployment role cannot enumerate IAM users"
if aws iam list-users --region "${AWS_REGION}" >/dev/null 2>"${deploy_dir}/denied.log"; then
  echo "PROOF unrelated IAM operation denied: FAIL (unexpectedly allowed)" >&2
  exit 1
fi
grep -q 'AccessDenied' "${deploy_dir}/denied.log"
echo "PROOF unrelated IAM operation denied: PASS (AccessDenied)"

echo "4/5 Deploying the tested Lambda revision"
cp "${SOURCE_DIR}/processor/handler.py" "${deploy_dir}/handler.py"
cp "${SERVERLESS_TEMPLATE}" "${deploy_dir}/serverless.yml"
export DEPLOYMENT_SHA="${GIT_SHA}"
(
  cd "${deploy_dir}"
  serverless deploy --stage demo
)
echo "PROOF Serverless deployed Lambda: PASS"

echo "5/5 Invoking Lambda and matching the deployed Git revision"
response_file="${deploy_dir}/response.json"
status_code="$(aws lambda invoke \
  --region "${AWS_REGION}" \
  --function-name "${function_name}" \
  --cli-binary-format raw-in-base64-out \
  --payload '{}' \
  --query StatusCode \
  --output text \
  "${response_file}")"
[[ "${status_code}" == 200 ]]
jq -e --arg sha "${GIT_SHA}" \
  '.message == "Lambda deployed by Tekton with Vault credentials" and .gitSha == $sha' \
  "${response_file}" >/dev/null
printf 'PROOF deployed Lambda returned Git SHA %s: PASS\n' "${GIT_SHA}"
jq '{message, gitSha}' "${response_file}"
