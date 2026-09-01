#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REGION=il-central-1
readonly CLUSTER=vault-tekton-demo
readonly CONTEXT="kind-${CLUSTER}"
readonly NAMESPACE=vault-tekton-demo
readonly VAULT_NAMESPACE=vault
readonly VAULT_ROOT_TOKEN=demo-root
readonly STACK_NAME=vault-tekton-demo
readonly BOOTSTRAP_USER=vault-tekton-demo-bootstrap
readonly IMAGE=vault-tekton-demo:local
readonly TEKTON_VERSION=v1.15.0
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
    --stack-name "${STACK_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

vault_exec() {
  kubectl --namespace "${VAULT_NAMESPACE}" exec vault-0 -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_ROOT_TOKEN}" vault "$@"
}

install_local() {
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
  kubectl apply --filename "${ROOT_DIR}/k8s/demo.yaml"
  echo "Local platform ready: Tekton ${TEKTON_VERSION}, Vault chart ${VAULT_CHART_VERSION}"
}

bootstrap_aws_and_vault() {
  for tool in aws jq kubectl; do require "${tool}"; done
  use_demo_context

  local account_id bucket role_arn access_file access_key_id access_secret
  account_id="$(aws sts get-caller-identity --region "${REGION}" --query Account --output text)"
  bucket="vault-tekton-demo-${account_id}-${REGION}"

  aws cloudformation deploy \
    --region "${REGION}" \
    --stack-name "${STACK_NAME}" \
    --template-file "${ROOT_DIR}/infra/aws.yaml" \
    --parameter-overrides "BucketName=${bucket}" \
    --capabilities CAPABILITY_NAMED_IAM

  role_arn="$(stack_output CameraUploaderRoleArn)"
  access_file="$(mktemp)"
  chmod 600 "${access_file}"
  access_key_id=""

  cleanup_unrotated_key() {
    if [[ -n "${access_key_id}" ]]; then
      aws iam delete-access-key \
        --user-name "${BOOTSTRAP_USER}" \
        --access-key-id "${access_key_id}" >/dev/null 2>&1 || true
    fi
    rm -f "${access_file}"
  }
  trap cleanup_unrotated_key EXIT

  aws iam create-access-key \
    --user-name "${BOOTSTRAP_USER}" \
    --output json >"${access_file}"
  access_key_id="$(jq -er '.AccessKey.AccessKeyId' "${access_file}")"
  access_secret="$(jq -er '.AccessKey.SecretAccessKey' "${access_file}")"

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
    vault policy write camera-uploader - >/dev/null <<'HCL'
path "aws/creds/camera-uploader" {
  capabilities = ["read"]
}
HCL

  vault_exec write auth/kubernetes/role/camera-gateway \
    bound_service_account_names=camera-gateway \
    bound_service_account_namespaces="${NAMESPACE}" \
    audience=https://kubernetes.default.svc.cluster.local \
    policies=camera-uploader \
    ttl=5m >/dev/null

  jq -n \
    --arg access_key "${access_key_id}" \
    --arg secret_key "${access_secret}" \
    --arg region "${REGION}" \
    '{access_key:$access_key, secret_key:$secret_key, region:$region, sts_region:$region}' |
    kubectl --namespace "${VAULT_NAMESPACE}" exec -i vault-0 -- \
      env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_ROOT_TOKEN}" \
      vault write aws/config/root - >/dev/null

  vault_exec write aws/roles/camera-uploader \
    credential_type=assumed_role \
    role_arns="${role_arn}" \
    default_sts_ttl=15m \
    max_sts_ttl=15m >/dev/null

  vault_exec write -f aws/config/rotate-root >/dev/null
  access_key_id=""
  access_secret=""
  rm -f "${access_file}"
  trap - EXIT

  echo "Vault configured for ${role_arn} in ${REGION}"
  echo "Bootstrap key rotated: the surviving static secret is known only to Vault"
}

run_demo() {
  for tool in aws jq kubectl; do require "${tool}"; done
  use_demo_context

  local bucket run_id run_name status elapsed
  bucket="$(stack_output BucketName)"
  run_id="$(date -u +%Y%m%d%H%M%S)"

  run_name="$(kubectl create --filename - --output jsonpath='{.metadata.name}' <<YAML
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: onprem-vault-assumerole-
  namespace: ${NAMESPACE}
spec:
  pipelineRef:
    name: onprem-vault-assumerole
  taskRunTemplate:
    serviceAccountName: tekton-deployer
  params:
    - name: aws-region
      value: ${REGION}
    - name: bucket
      value: ${bucket}
    - name: gateway-image
      value: ${IMAGE}
    - name: run-id
      value: "${run_id}"
YAML
)"
  echo "PipelineRun: ${run_name}"

  elapsed=0
  while (( elapsed < 300 )); do
    status="$(kubectl get pipelinerun "${run_name}" --namespace "${NAMESPACE}" \
      --output jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)"
    case "${status}" in
      True) break ;;
      False)
        kubectl logs --namespace "${NAMESPACE}" \
          --selector "tekton.dev/pipelineRun=${run_name}" --all-containers --prefix || true
        echo "Pipeline failed" >&2
        exit 1
        ;;
    esac
    sleep 2
    elapsed=$((elapsed + 2))
  done

  [[ "${status}" == True ]] || {
    echo "Pipeline timed out" >&2
    exit 1
  }
  kubectl logs --namespace "${NAMESPACE}" \
    --selector "tekton.dev/pipelineRun=${run_name}" --all-containers --prefix
  echo "Run './demo.sh audit' for the Vault lease and CloudTrail AssumeRole proof."
}

show_audit() {
  for tool in aws jq kubectl; do require "${tool}"; done
  use_demo_context

  local role_arn job event
  role_arn="$(stack_output CameraUploaderRoleArn)"
  job="$(kubectl get jobs --namespace "${NAMESPACE}" \
    --selector app=camera-gateway \
    --sort-by=.metadata.creationTimestamp \
    --output jsonpath='{.items[-1:].metadata.name}')"

  echo "Vault lease evidence (credentials are intentionally omitted):"
  kubectl logs --namespace "${NAMESPACE}" "job/${job}" --container gateway |
    grep -E '^(AUDIT|PROOF|RESULT)'

  event="$(aws cloudtrail lookup-events \
    --region "${REGION}" \
    --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
    --max-results 50 \
    --output json |
    jq -c --arg role "${role_arn}" '
      [.Events[]
       | . + {detail: (.CloudTrailEvent | fromjson)}
       | select(.detail.requestParameters.roleArn == $role)]
      | sort_by(.EventTime)
      | reverse
      | .[0] // empty')"

  if [[ -z "${event}" ]]; then
    echo "CloudTrail has not surfaced the AssumeRole event yet; rerun './demo.sh audit' in a few minutes."
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
  bash -n "${ROOT_DIR}/demo.sh" "${ROOT_DIR}/app/entrypoint.sh"
  "${ROOT_DIR}/test/entrypoint.sh"
  yq eval-all '.' "${ROOT_DIR}/infra/aws.yaml" "${ROOT_DIR}/k8s/demo.yaml" >/dev/null
  if grep -RIE '(AKIA[0-9A-Z]{16}|aws_secret_access_key[[:space:]]*=)' \
    "${ROOT_DIR}" --exclude-dir=.git; then
    echo "Possible AWS credential found" >&2
    exit 1
  fi
  echo "Static checks passed"
}

cleanup_demo() {
  for tool in aws jq; do require "${tool}"; done

  local bucket access_key_ids
  bucket="$(stack_output BucketName 2>/dev/null || true)"
  if [[ "${bucket}" == vault-tekton-demo-*-"${REGION}" ]]; then
    aws s3 rm "s3://${bucket}/events/" --recursive --region "${REGION}"
  fi

  access_key_ids="$(aws iam list-access-keys \
    --user-name "${BOOTSTRAP_USER}" \
    --query 'AccessKeyMetadata[].AccessKeyId' \
    --output text 2>/dev/null || true)"
  for access_key_id in ${access_key_ids}; do
    aws iam delete-access-key \
      --user-name "${BOOTSTRAP_USER}" \
      --access-key-id "${access_key_id}"
  done

  aws cloudformation delete-stack --region "${REGION}" --stack-name "${STACK_NAME}"
  aws cloudformation wait stack-delete-complete --region "${REGION}" --stack-name "${STACK_NAME}"

  if command -v kind >/dev/null 2>&1 && kind get clusters | grep -Fxq "${CLUSTER}"; then
    kind delete cluster --name "${CLUSTER}"
  fi
  echo "Deleted the demo bucket, Vault bootstrap principal, IAM role, stack, and local cluster."
}

usage() {
  cat <<'USAGE'
Usage: ./demo.sh <command>

  install    Create kind and install pinned Tekton/Vault versions
  bootstrap Create AWS resources, configure Vault, and rotate its bootstrap key
  run        Run the Tekton deployment and security checks
  audit      Show the Vault lease and CloudTrail AssumeRole event
  check      Run static checks without changing infrastructure
  cleanup    Delete all demo AWS and local resources
USAGE
}

case "${1:-}" in
  install) install_local ;;
  bootstrap) bootstrap_aws_and_vault ;;
  run) run_demo ;;
  audit) show_audit ;;
  check) check_files ;;
  cleanup) cleanup_demo ;;
  *) usage; exit 1 ;;
esac
