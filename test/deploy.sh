#!/usr/bin/env bash
set -euo pipefail

readonly root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT
mkdir "${test_dir}/bin"
mkdir -p "${test_dir}/source/processor"
printf 'synthetic-token' >"${test_dir}/service-account-token"
cp "${root_dir}/processor/handler.py" "${test_dir}/source/processor/handler.py"
printf '%s\n' 'malicious: ignored' >"${test_dir}/source/processor/serverless.yml"

cat >"${test_dir}/bin/vault" <<'VAULT'
#!/usr/bin/env bash
if [[ "$1" == write && "$2" == -format=json && "$3" == auth/kubernetes/login ]]; then
  printf '%s\n' '{"auth":{"client_token":"MOCK_VAULT_TOKEN"}}'
elif [[ "$1" == read && "$2" == -format=json && "$3" == aws/creds/lambda-deployer ]]; then
  printf '%s\n' '{"lease_id":"aws/creds/lambda-deployer/mock","lease_duration":900,"data":{"arn":"arn:aws:sts::123456789012:assumed-role/VaultTektonDemoLambdaDeployer/mock","access_key":"MOCK_ACCESS_KEY","secret_key":"MOCK_SECRET","security_token":"MOCK_SESSION"}}'
else
  echo "Unexpected Vault command: $*" >&2
  exit 1
fi
VAULT

cat >"${test_dir}/bin/aws" <<'AWS'
#!/usr/bin/env bash
if [[ "$1 $2" == 'sts get-caller-identity' ]]; then
  echo 'arn:aws:sts::123456789012:assumed-role/VaultTektonDemoLambdaDeployer/mock'
  exit 0
fi
if [[ "$1 $2" == 'iam list-users' ]]; then
  echo 'An error occurred (AccessDenied)' >&2
  exit 254
fi
if [[ "$1 $2" == 'lambda invoke' ]]; then
  output_file="${*: -1}"
  printf '{"message":"Lambda deployed by Tekton with Vault credentials","gitSha":"%s"}\n' \
    "${DEPLOYMENT_SHA}" >"${output_file}"
  echo 200
  exit 0
fi
echo "Unexpected AWS command: $*" >&2
exit 1
AWS

cat >"${test_dir}/bin/serverless" <<'SERVERLESS'
#!/usr/bin/env bash
[[ "$1 $2" == 'deploy --stage' && "$3" == demo ]]
[[ -f handler.py && -f serverless.yml ]]
grep -Fq 'service: vault-tekton-lambda-cicd' serverless.yml
! grep -Fq 'malicious: ignored' serverless.yml
[[ "${DEPLOYMENT_SHA}" == a1b2c3d ]]
echo 'Serverless deploy complete'
SERVERLESS

chmod +x "${test_dir}/bin/vault" "${test_dir}/bin/aws" "${test_dir}/bin/serverless"

output="$(
  PATH="${test_dir}/bin:${PATH}" \
  SERVICE_ACCOUNT_TOKEN_FILE="${test_dir}/service-account-token" \
  SOURCE_DIR="${test_dir}/source" \
  SERVERLESS_TEMPLATE="${root_dir}/processor/serverless.yml" \
  GIT_SHA=a1b2c3d \
  VAULT_ADDR=http://vault.test:8200 \
  AWS_REGION=us-east-1 \
  DEPLOYMENT_BUCKET=vault-tekton-demo-deployments \
  LAMBDA_EXECUTION_ROLE_ARN=arn:aws:iam::123456789012:role/VaultTektonDemoLambdaExecutionRole \
  "${root_dir}/app/deploy.sh"
)"

grep -Fq 'AUDIT Vault lease: aws/creds/lambda-deployer/mock' <<<"${output}"
grep -Fq 'AUDIT Lease TTL: 900s' <<<"${output}"
grep -Fq 'PROOF unrelated IAM operation denied: PASS (AccessDenied)' <<<"${output}"
grep -Fq 'PROOF Serverless deployed Lambda: PASS' <<<"${output}"
grep -Fq 'PROOF deployed Lambda returned Git SHA a1b2c3d: PASS' <<<"${output}"
if grep -Eq 'MOCK_SECRET|MOCK_SESSION|MOCK_VAULT_TOKEN|MOCK_ACCESS_KEY' <<<"${output}"; then
  echo 'Credential leaked to output' >&2
  exit 1
fi
echo 'Vault deployment checks passed'
