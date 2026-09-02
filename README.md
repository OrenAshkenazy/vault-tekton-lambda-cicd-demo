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
Tekton deploys a simulated edge gateway Job
        ↓
Job logs into Vault with its Kubernetes service-account token
        ↓
Vault AWS Secrets Engine calls STS AssumeRole
        ↓
Job receives a 15-minute credential in memory
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
