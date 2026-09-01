# Vault + Tekton AssumeRole demo

This demo proves one security contract in AWS Region `il-central-1`:

> A simulated on-prem camera gateway has no permanent AWS credential. It logs
> into Vault, receives a leased STS credential for one IAM role, can write only
> to `events/*`, and cannot write elsewhere or read the object back.

## Flow

```text
Tekton deploys a gateway Job
        ↓
Job logs into Vault with its Kubernetes service-account token
        ↓
Vault AWS Secrets Engine calls STS AssumeRole
        ↓
Job receives a 15-minute credential in memory
        ↓
PutObject events/*       → allowed
PutObject private/*      → AccessDenied
GetObject events/*       → AccessDenied
```

Tekton is the delivery and verification path. The gateway Job—not Tekton—uses
Vault at runtime. There is no Vault Agent Injector.

## Prerequisites

- Docker, `kind`, `kubectl`, Helm, AWS CLI, `jq`, and `yq`
- An AWS sandbox identity allowed to deploy CloudFormation, IAM, and S3
- Network access to AWS, GitHub-hosted Tekton manifests, Helm, and container registries

The scripts pin Tekton `v1.15.0` LTS, Vault Helm chart `0.34.0`, Vault `2.0.3`,
AWS CLI container `2.34.48`, kind node `1.36.1`, and Region `il-central-1`.

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

1. The Tekton PipelineRun deploys the simulated on-prem gateway.
2. Vault prints only its lease ID, 15-minute TTL, and assumed-role ARN.
3. `PutObject` under `events/*` succeeds.
4. `PutObject` under `private/*` returns `AccessDenied`.
5. `GetObject` for the uploaded event returns `AccessDenied`.
6. CloudTrail Event History shows Vault's `AssumeRole` call in `il-central-1`.

CloudTrail management events can take a few minutes to appear. Run the demo once
before the interview, then use the previous event as audit evidence if the new
one has not surfaced yet. The audit command never displays AWS credentials.

The closing line is:

> Compromise it and you can write one prefix, never read the gallery back.

## Cleanup

```bash
./demo.sh cleanup
```

This empties the dedicated bucket, deletes all access keys for the demo bootstrap
user, deletes the CloudFormation stack, and deletes the dedicated kind cluster.
