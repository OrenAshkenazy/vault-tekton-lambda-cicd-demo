#!/usr/bin/env bash
set -euo pipefail

[[ -x /usr/local/bin/aws ]] && export PATH="/usr/local/bin:${PATH}"

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REGION=us-east-1
readonly CLUSTER=vault-tekton-demo
readonly CONTEXT="kind-${CLUSTER}"
readonly NAMESPACE=vault-tekton-demo
readonly VAULT_NAMESPACE=vault
readonly VAULT_ROOT_TOKEN=demo-root
readonly FOUNDATION_STACK=vault-tekton-lambda-cicd-foundation
readonly LAMBDA_STACK=vault-tekton-lambda-cicd-demo
readonly BOOTSTRAP_USER=vault-tekton-lambda-cicd-bootstrap
readonly IMAGE=vault-tekton-demo:local
readonly TEKTON_VERSION=v1.15.0
readonly TRIGGERS_VERSION=v0.37.0
readonly DASHBOARD_VERSION=v0.72.0
readonly VAULT_CHART_VERSION=0.34.0

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

use_demo_context() {
  kubectl config use-context "${CONTEXT}" >/dev/null
}

stack_output() {
  aws cloudformation describe-stacks \
    --region "${REGION}" \
    --stack-name "${FOUNDATION_STACK}" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

vault_exec() {
  kubectl --namespace "${VAULT_NAMESPACE}" exec vault-0 -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_ROOT_TOKEN}" vault "$@"
}

install_platform() {
  for tool in docker kind kubectl helm; do require "${tool}"; done

  if ! kind get clusters | grep -Fxq "${CLUSTER}"; then
    kind create cluster \
      --name "${CLUSTER}" \
      --image kindest/node:v1.36.1 \
      --wait 120s
  fi
  use_demo_context

  kubectl apply --filename \
    "https://infra.tekton.dev/tekton-releases/pipeline/previous/${TEKTON_VERSION}/release.yaml"
  kubectl wait --namespace tekton-pipelines \
    --for=condition=available deployment/tekton-pipelines-controller --timeout=180s

  kubectl apply --filename \
    "https://infra.tekton.dev/tekton-releases/triggers/previous/${TRIGGERS_VERSION}/release.yaml"
  kubectl apply --filename \
    "https://infra.tekton.dev/tekton-releases/triggers/previous/${TRIGGERS_VERSION}/interceptors.yaml"
  kubectl wait --namespace tekton-pipelines \
    --for=condition=available deployment/tekton-triggers-controller --timeout=180s
  kubectl wait --namespace tekton-pipelines \
    --for=condition=available deployment/tekton-triggers-core-interceptors --timeout=180s

  kubectl apply --filename \
    "https://infra.tekton.dev/tekton-releases/dashboard/previous/${DASHBOARD_VERSION}/release.yaml"
  kubectl wait --namespace tekton-pipelines \
    --for=condition=available deployment/tekton-dashboard --timeout=180s

  helm repo add hashicorp https://helm.releases.hashicorp.com --force-update
  helm upgrade --install vault hashicorp/vault \
    --namespace "${VAULT_NAMESPACE}" \
    --create-namespace \
    --version "${VAULT_CHART_VERSION}" \
    --set injector.enabled=false \
    --set server.dev.enabled=true \
    --set server.dev.devRootToken="${VAULT_ROOT_TOKEN}" \
    --set server.image.repository=hashicorp/vault \
    --set server.image.tag=2.0.3 \
    --wait --timeout 3m

  docker build --tag "${IMAGE}" "${ROOT_DIR}"
  docker save "${IMAGE}" |
    docker exec -i "${CLUSTER}-control-plane" \
      ctr --namespace k8s.io images import - >/dev/null
  # TriggerTemplate embeds a PipelineRun as schemaless JSON, so kubectl apply
  # cannot reliably patch nested fields. Recreate this demo-only template.
  kubectl delete triggertemplate/lambda-cicd \
    --namespace "${NAMESPACE}" --ignore-not-found >/dev/null
  kubectl apply --filename "${ROOT_DIR}/k8s/demo.yaml"
}

configure_aws_and_vault() {
  for tool in aws jq kubectl; do require "${tool}"; done
  use_demo_context

  local account_id deployment_bucket lambda_role_arn execution_role_arn
  local access_file access_key_id access_secret attempt existing_access_key_id
  account_id="$(aws sts get-caller-identity --region "${REGION}" --query Account --output text)"
  deployment_bucket="vault-tekton-lambda-cicd-${account_id}-${REGION}-deployments"

  aws cloudformation deploy \
    --region "${REGION}" \
    --stack-name "${FOUNDATION_STACK}" \
    --template-file "${ROOT_DIR}/infra/aws.yaml" \
    --parameter-overrides "DeploymentBucketName=${deployment_bucket}" \
    --capabilities CAPABILITY_NAMED_IAM

  deployment_bucket="$(stack_output DeploymentBucketName)"
  lambda_role_arn="$(stack_output LambdaDeployerRoleArn)"
  execution_role_arn="$(stack_output LambdaExecutionRoleArn)"

  for existing_access_key_id in $(aws iam list-access-keys \
    --user-name "${BOOTSTRAP_USER}" \
    --query 'AccessKeyMetadata[].AccessKeyId' \
    --output text); do
    aws iam delete-access-key \
      --user-name "${BOOTSTRAP_USER}" \
      --access-key-id "${existing_access_key_id}"
  done

  access_file="$(mktemp)"
  chmod 600 "${access_file}"
  access_key_id=""

  cleanup_unrotated_key() {
    local key_to_delete="${access_key_id}"
    if [[ -z "${key_to_delete}" && -s "${access_file}" ]]; then
      key_to_delete="$(jq -r '.AccessKey.AccessKeyId // empty' "${access_file}" 2>/dev/null || true)"
    fi
    if [[ -n "${key_to_delete}" ]]; then
      aws iam delete-access-key \
        --user-name "${BOOTSTRAP_USER}" \
        --access-key-id "${key_to_delete}" >/dev/null 2>&1 || true
    fi
    rm -f "${access_file}"
  }
  trap cleanup_unrotated_key EXIT

  aws iam create-access-key \
    --user-name "${BOOTSTRAP_USER}" \
    --output json >"${access_file}"
  access_key_id="$(jq -er '.AccessKey.AccessKeyId' "${access_file}")"
  access_secret="$(jq -er '.AccessKey.SecretAccessKey' "${access_file}")"

  for ((attempt = 1; attempt <= 12; attempt++)); do
    if AWS_ACCESS_KEY_ID="${access_key_id}" \
      AWS_SECRET_ACCESS_KEY="${access_secret}" \
      AWS_SESSION_TOKEN= \
      aws iam get-user --user-name "${BOOTSTRAP_USER}" >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
  ((attempt <= 12)) || {
    echo "Bootstrap access key did not become usable within 60 seconds" >&2
    return 1
  }

  if ! vault_exec secrets list -format=json | jq -e 'has("aws/")' >/dev/null; then
    vault_exec secrets enable aws >/dev/null
  fi
  if ! vault_exec auth list -format=json | jq -e 'has("kubernetes/")' >/dev/null; then
    vault_exec auth enable kubernetes >/dev/null
  fi

  vault_exec write auth/kubernetes/config \
    kubernetes_host=https://kubernetes.default.svc:443 >/dev/null

  kubectl --namespace "${VAULT_NAMESPACE}" exec -i vault-0 -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
    vault policy write lambda-deployer - >/dev/null <<'HCL'
path "aws/creds/lambda-deployer" {
  capabilities = ["read"]
}
HCL

  vault_exec write auth/kubernetes/role/tekton-lambda-deployer \
    bound_service_account_names=tekton-ci \
    bound_service_account_namespaces="${NAMESPACE}" \
    audience=vault \
    policies=lambda-deployer \
    ttl=5m >/dev/null

  jq -n \
    --arg access_key "${access_key_id}" \
    --arg secret_key "${access_secret}" \
    --arg region "${REGION}" \
    '{access_key:$access_key, secret_key:$secret_key, region:$region, sts_region:$region}' |
    kubectl --namespace "${VAULT_NAMESPACE}" exec -i vault-0 -- \
      env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
      vault write aws/config/root - >/dev/null

  vault_exec write aws/roles/lambda-deployer \
    credential_type=assumed_role \
    role_arns="${lambda_role_arn}" \
    default_sts_ttl=15m \
    max_sts_ttl=15m >/dev/null

  vault_exec write -f aws/config/rotate-root >/dev/null
  access_key_id=""
  access_secret=""
  rm -f "${access_file}"
  trap - EXIT

  kubectl create configmap lambda-cicd-config \
    --namespace "${NAMESPACE}" \
    --from-literal=aws-region="${REGION}" \
    --from-literal=deployment-bucket="${deployment_bucket}" \
    --from-literal=lambda-execution-role-arn="${execution_role_arn}" \
    --dry-run=client \
    --output yaml |
    kubectl apply --filename - >/dev/null

  echo "AWS and Vault ready in ${REGION}; bootstrap key rotated and known only to Vault"
}

prepare_demo() {
  install_platform
  configure_aws_and_vault
  echo "Demo ready. Follow the GitHub trigger commands in README.md."
}

show_audit() {
  for tool in aws jq kubectl; do require "${tool}"; done
  use_demo_context

  local role_arn pipeline_run taskrun pod deploy_logs assumed_role_arn role_session_name event
  role_arn="$(stack_output LambdaDeployerRoleArn)"
  pipeline_run="$(kubectl get pipelineruns --namespace "${NAMESPACE}" \
    --selector app.kubernetes.io/part-of=vault-tekton-lambda-cicd \
    --sort-by=.metadata.creationTimestamp \
    --output jsonpath='{.items[-1:].metadata.name}')"
  taskrun="$(kubectl get taskruns --namespace "${NAMESPACE}" \
    --selector "tekton.dev/pipelineRun=${pipeline_run},tekton.dev/pipelineTask=deploy-and-verify" \
    --output jsonpath='{.items[0].metadata.name}')"
  pod="$(kubectl get pods --namespace "${NAMESPACE}" \
    --selector "tekton.dev/taskRun=${taskrun}" \
    --output jsonpath='{.items[0].metadata.name}')"
  deploy_logs="$(kubectl logs --namespace "${NAMESPACE}" "${pod}" --container step-deploy)"
  assumed_role_arn="$(sed -n 's/^AUDIT Vault returned: //p' <<<"${deploy_logs}" | tail -1)"
  role_session_name="${assumed_role_arn##*/}"

  echo "Pipeline, Vault, and deployment proof (credentials intentionally omitted):"
  printf 'PipelineRun: %s\n' "${pipeline_run}"
  grep -E '^(AUDIT|PROOF)' <<<"${deploy_logs}"

  event="$(aws cloudtrail lookup-events \
    --region "${REGION}" \
    --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
    --max-results 50 \
    --output json |
    jq -c --arg role "${role_arn}" --arg session "${role_session_name}" '
      [.Events[]
       | . + {detail: (.CloudTrailEvent | fromjson)}
       | select(
           .detail.requestParameters.roleArn == $role
           and .detail.requestParameters.roleSessionName == $session)]
      | sort_by(.EventTime)
      | reverse
      | .[0] // empty')"

  if [[ -z "${event}" ]]; then
    echo "CloudTrail has not surfaced this run's AssumeRole session; rerun './demo.sh audit' in a few minutes."
    return 0
  fi

  echo "CloudTrail AssumeRole evidence (${REGION}):"
  jq '{
    EventTime,
    EventId,
    EventName,
    RoleArn: .detail.requestParameters.roleArn,
    RoleSessionName: .detail.requestParameters.roleSessionName,
    SourceIPAddress: .detail.sourceIPAddress,
    UserAgent: .detail.userAgent
  }' <<<"${event}"
}

check_files() {
  require yq
  bash -n "${ROOT_DIR}/demo.sh" "${ROOT_DIR}/app/deploy.sh" "${ROOT_DIR}/test/deploy.sh"
  "${ROOT_DIR}/test/deploy.sh"
  python3 "${ROOT_DIR}/test/handler.py"
  yq eval-all '.' \
    "${ROOT_DIR}/infra/aws.yaml" \
    "${ROOT_DIR}/k8s/demo.yaml" \
    "${ROOT_DIR}/processor/serverless.yml" >/dev/null
  if grep -RIE '(AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|aws_secret_access_key[[:space:]]*=)' \
    "${ROOT_DIR}" --exclude-dir=.git; then
    echo "Possible AWS credential found" >&2
    exit 1
  fi
  echo "Static checks passed"
}

cleanup_demo() {
  for tool in aws jq; do require "${tool}"; done

  local deployment_bucket access_key_id
  deployment_bucket="$(stack_output DeploymentBucketName 2>/dev/null || true)"
  if aws cloudformation describe-stacks \
    --region "${REGION}" \
    --stack-name "${LAMBDA_STACK}" >/dev/null 2>&1; then
    aws cloudformation delete-stack --region "${REGION}" --stack-name "${LAMBDA_STACK}"
    aws cloudformation wait stack-delete-complete --region "${REGION}" --stack-name "${LAMBDA_STACK}"
  fi

  if [[ "${deployment_bucket}" == vault-tekton-lambda-cicd-*-${REGION}-deployments ]]; then
    aws s3 rm "s3://${deployment_bucket}/" --recursive --region "${REGION}"
  fi
  for access_key_id in $(aws iam list-access-keys \
    --user-name "${BOOTSTRAP_USER}" \
    --query 'AccessKeyMetadata[].AccessKeyId' \
    --output text 2>/dev/null || true); do
    aws iam delete-access-key \
      --user-name "${BOOTSTRAP_USER}" \
      --access-key-id "${access_key_id}"
  done

  aws cloudformation delete-stack --region "${REGION}" --stack-name "${FOUNDATION_STACK}"
  aws cloudformation wait stack-delete-complete --region "${REGION}" --stack-name "${FOUNDATION_STACK}"

  if command -v kind >/dev/null 2>&1 && kind get clusters | grep -Fxq "${CLUSTER}"; then
    kind delete cluster --name "${CLUSTER}"
  fi
  echo "Deleted the Lambda, deployment bucket, Vault bootstrap principal, stacks, and local cluster."
}

usage() {
  cat <<'USAGE'
Usage: ./demo.sh <command>

  prepare  Install the local platform and configure AWS/Vault once
  audit    Show the PipelineRun, Vault lease, and CloudTrail AssumeRole proof
  check    Run local tests and static checks
  cleanup  Delete the dedicated demo resources

The live CI/CD trigger is a GitHub demo-* tag, not this script.
USAGE
}

case "${1:-}" in
  prepare) prepare_demo ;;
  audit) show_audit ;;
  check) check_files ;;
  cleanup) cleanup_demo ;;
  *) usage; exit 1 ;;
esac
