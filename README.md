# Vault + Tekton AssumeRole demo

This demo proves two security contracts in AWS Region `us-east-1`:

> Tekton deploys an S3-triggered Lambda through Serverless Framework using a
> short-lived Vault lease. A simulated on-prem camera gateway receives a
> different leased role, uploads a synthetic image directly to `events/*`, and
> cannot write elsewhere or read the image back.

## Flow

```text
Tekton logs into Vault as lambda-deployer
        ↓
Serverless Framework deploys the EventBridge-triggered Lambda
        ↓
Tekton runs a simulated edge task as camera-gateway
        ↓
The task logs into Vault with its Kubernetes service-account token
        ↓
Vault AWS Secrets Engine calls STS AssumeRole
        ↓
The task receives a 15-minute credential in memory
        ↓
PutObject events/*.svg   → allowed
PutObject private/*      → AccessDenied
GetObject events/*       → AccessDenied
        ↓
S3 Object Created → EventBridge → Lambda → marker in CloudWatch Logs
```

Tekton and the edge task use separate Kubernetes identities, Vault policies,
and AWS roles. The Lambda execution role is pre-created, so the deployer may
pass it but cannot rewrite it. The gateway can only write under `events/*`.
Serverless artifacts use a separate bucket, so the deployer has no S3
data-plane access to camera objects; it retains read-only processor-log access
for pipeline verification. There is no Vault Agent Injector and no AWS
credential is stored in a Kubernetes Secret.

## Prerequisites

- Docker, `kind`, `kubectl`, Helm, AWS CLI, `jq`, and `yq`
- An AWS sandbox identity allowed to deploy CloudFormation, IAM, and S3
- Network access to AWS, GitHub-hosted Tekton manifests, Helm, and container registries

The scripts pin Tekton `v1.15.0` LTS, Vault Helm chart `0.34.0`, Vault `2.0.3`,
Serverless Framework `3.40.0`, AWS CLI container `2.34.48`, kind node `1.36.1`,
and Region `us-east-1`. Serverless v3 is pinned for this self-contained demo so
the live pipeline does not depend on a separate Serverless Dashboard login.

## Prepare once

```bash
./demo.sh check
./demo.sh install
./demo.sh bootstrap
```

`bootstrap` creates a dedicated IAM user long enough to configure the Vault AWS
Secrets Engine. It immediately calls Vault's `rotate-root`, deleting the key
seen by the setup process and replacing it with one known only to Vault. The
bootstrap principal itself remains until the demo ends because Vault still needs
that identity to call `AssumeRole`; `cleanup` deletes it and its Vault-owned key.

## Tekton Dashboard

The Dashboard is optional and is not installed by `demo.sh`. Dashboard `v0.72.0`
supports the pinned Pipelines `v1.15.x`. Install its read-only release:

```bash
kubectl apply --filename \
  https://infra.tekton.dev/tekton-releases/dashboard/previous/v0.72.0/release.yaml
kubectl wait --namespace tekton-pipelines \
  --for=condition=available deployment/tekton-dashboard --timeout=180s
```

Expose it only on the local machine:

```bash
kubectl --namespace tekton-pipelines \
  port-forward service/tekton-dashboard 9097:9097
```

Open <http://127.0.0.1:9097>, select namespace `vault-tekton-demo`, and open
the latest `onprem-vault-assumerole-*` PipelineRun. There is no Dashboard
username or password. A Kubernetes context is required to start the local
port-forward, but any process or user on that workstation can then reach the
Dashboard and its logs. Run it only on a trusted single-user workstation and
stop it with `Ctrl-C` immediately after the demo.

## Get fresh AWS credentials through Vault

Vault exposes two dynamic AWS roles. Each read creates a fresh STS
`AssumeRole` session. The Tekton PipelineRun uses both: its deployment tasks
use `lambda-deployer`, while its simulated edge task uses `camera-uploader`.
No AWS credential is stored in a Kubernetes Secret.

| Purpose | Kubernetes service account | Vault login role | Credentials path |
| --- | --- | --- | --- |
| Edge upload | `camera-gateway` | `camera-gateway` | `aws/creds/camera-uploader` |
| Lambda deployment | `tekton-deployer` | `tekton-lambda-deployer` | `aws/creds/lambda-deployer` |

### Workload-authenticated path

Start an ephemeral shell with the edge identity:

```bash
kubectl run vault-aws-shell \
  --namespace vault-tekton-demo \
  --rm --stdin --tty \
  --restart=Never \
  --image=vault-tekton-demo:local \
  --image-pull-policy=IfNotPresent \
  --overrides='{"spec":{"serviceAccountName":"camera-gateway"}}' \
  --command -- sh
```

Inside that shell, exchange the Kubernetes token for a Vault token, then read
the AWS role. The credential values are exported but never printed:

```sh
export VAULT_ADDR=http://vault.vault.svc:8200

login_json="$(vault write -format=json auth/kubernetes/login \
  role=camera-gateway \
  jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token)"
export VAULT_TOKEN="$(printf '%s' "${login_json}" | jq -er '.auth.client_token')"
unset login_json

credential_json="$(vault read -format=json aws/creds/camera-uploader)"
lease_id="$(printf '%s' "${credential_json}" | jq -er '.lease_id')"
lease_ttl="$(printf '%s' "${credential_json}" | jq -er '.lease_duration')"
export AWS_ACCESS_KEY_ID="$(printf '%s' "${credential_json}" | jq -er '.data.access_key')"
export AWS_SECRET_ACCESS_KEY="$(printf '%s' "${credential_json}" | jq -er '.data.secret_key')"
export AWS_SESSION_TOKEN="$(printf '%s' "${credential_json}" | jq -er \
  '.data.security_token // .data.session_token')"
export AWS_REGION=us-east-1
unset credential_json VAULT_TOKEN

printf 'Vault lease: %s; TTL: %ss\n' "${lease_id}" "${lease_ttl}"
aws sts get-caller-identity --region "${AWS_REGION}"
```

These are real temporary AWS credentials. An assumed-role credential requires
all three values: access key, secret key, and session token. To request the
deployer credential instead, use service account `tekton-deployer`, Vault login
role `tekton-lambda-deployer`, and path `aws/creds/lambda-deployer`.

Clear the shell when finished; the AWS session expires after 15 minutes:

```sh
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION
unset lease_id lease_ttl
exit
```

### Local admin shortcut

For troubleshooting only, port-forward Vault and use the dev root token. This
bypasses Kubernetes authentication, so do not present it as the workload flow:

```bash
kubectl --namespace vault port-forward service/vault 8200:8200
```

In a second terminal, replace the credentials in that shell with a fresh
`camera-uploader` lease:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
credential_json="$(VAULT_TOKEN=demo-root \
  vault read -format=json aws/creds/camera-uploader)"
export AWS_ACCESS_KEY_ID="$(printf '%s' "${credential_json}" | jq -er '.data.access_key')"
export AWS_SECRET_ACCESS_KEY="$(printf '%s' "${credential_json}" | jq -er '.data.secret_key')"
export AWS_SESSION_TOKEN="$(printf '%s' "${credential_json}" | jq -er \
  '.data.security_token // .data.session_token')"
export AWS_REGION=us-east-1
unset credential_json

aws sts get-caller-identity --region "${AWS_REGION}"
```

Never echo the secret key or session token, paste them into slides, or commit
them. A new `vault read aws/creds/...` returns a different leased STS session.

## Live demo

```bash
./demo.sh run
./demo.sh audit
```

Show these beats in order:

1. Tekton obtains the `lambda-deployer` lease and runs `serverless deploy`.
2. Tekton runs the simulated on-prem edge task under a different service account.
3. The gateway obtains a `camera-uploader` lease and uploads a synthetic SVG image directly to `events/*`.
4. `PutObject` under `private/*` returns `AccessDenied` with the same credentials.
5. `GetObject` for the uploaded image returns `AccessDenied`.
6. S3 emits the object event through EventBridge; Tekton finds the Lambda marker in CloudWatch Logs.
7. CloudTrail Event History shows Vault's exact `AssumeRole` session in `us-east-1`.

CloudTrail management events can take a few minutes to appear. Run the demo once
before the interview to measure that delay. During the presentation, `audit`
matches the current edge task's unique assumed-role session; wait and rerun it rather
than substituting a stale event. The command never displays AWS credentials.

The closing line is:

> Compromise it and you can write one prefix, never read the gallery back.

## Cleanup

```bash
./demo.sh cleanup
```

This empties both dedicated buckets, deletes all access keys for the demo
bootstrap user, deletes both CloudFormation stacks, and deletes the dedicated
kind cluster.
