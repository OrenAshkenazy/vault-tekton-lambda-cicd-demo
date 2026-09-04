# GitHub → Tekton → Vault → AWS Lambda CI/CD demo

This demo follows one Lambda revision from a GitHub release tag to AWS without
storing AWS credentials in GitHub or Kubernetes:

```text
GitHub demo-* tag
        ↓
Tekton EventListener → TriggerBinding → TriggerTemplate
        ↓
PipelineRun clones the exact commit
        ↓
Lambda and deployment-security tests
        ↓
Kubernetes service-account JWT → Vault Kubernetes auth
        ↓
Vault AWS Secrets Engine → 15-minute STS AssumeRole credentials
        ↓
Serverless Framework → CloudFormation → Lambda
        ↓
Lambda response contains the same Git SHA
        ↓
CloudTrail proves the exact AssumeRole session
```

The live pipeline contains only three Tasks: `fetch-source`, `test-lambda`, and
`deploy-and-verify`. The final Task also proves that its deployment role cannot
enumerate IAM users. Credentials exist only in that Task's process memory and
are cleared when it exits. Its deploy script and Serverless template come from
the pinned tool image; only the tested Lambda handler comes from the Git commit.

## Scope

Included:

- a real GitHub `push` event for a `demo-*` tag;
- Tekton Triggers and a read-only Tekton Dashboard;
- Lambda CI tests and Serverless Framework deployment;
- direct Kubernetes-to-Vault authentication;
- a leased AWS `AssumeRole` credential;
- deployed Git revision verification and CloudTrail evidence.

Not included: camera ingestion, image recognition, EventBridge, a Vault Agent
Injector, GitHub Actions, or any AWS credential stored as a Kubernetes Secret.

## Prerequisites

- Docker, `kind`, `kubectl`, Helm, AWS CLI, `jq`, `yq`, Git, and GitHub CLI
- a public GitHub repository containing this project
- an AWS sandbox identity allowed to deploy CloudFormation, IAM, S3, and Lambda
- Region `us-east-1`

The lab pins Tekton Pipelines `v1.15.0`, Tekton Triggers `v0.37.0`, Tekton
Dashboard `v0.72.0`, Vault chart `0.34.0` / Vault `2.0.3`, Serverless Framework
`3.40.0`, and kind node `1.36.1`.

## Prepare once

Load a current AWS sandbox session, then run:

```bash
./demo.sh check
./demo.sh prepare
```

`prepare` creates the local kind cluster, installs Tekton, its read-only
Dashboard, and Vault, then deploys the AWS foundation. The foundation contains:

- one encrypted, private S3 bucket for Serverless deployment artifacts;
- one pre-created Lambda execution role;
- one least-privilege Lambda deployment role;
- one bootstrap principal used only to configure Vault's AWS Secrets Engine.

Vault immediately runs `aws/config/rotate-root`, deleting the access key seen
by the setup process and replacing it with one known only to Vault. Cleanup
deletes the remaining bootstrap principal and its Vault-owned key.

The generated bucket name and execution-role ARN are non-secret values stored
in the `lambda-cicd-config` ConfigMap. AWS credentials are never stored there.

## How the deployment Task authenticates

All Task Pods use the token-disabled service account `tekton-ci`. The Pipeline
explicitly projects a ten-minute, Vault-audience JWT into the deployment step
only; fetch and test receive no service-account token. The file is mounted at:

```text
/var/run/secrets/vault/token
```

The deployment script passes that file directly to Vault:

```bash
vault write -format=json auth/kubernetes/login \
  role=tekton-lambda-deployer \
  jwt=@/var/run/secrets/vault/token
```

Vault asks the Kubernetes TokenReview API to validate the JWT, then checks that
it has audience `vault` and belongs to service account `tekton-ci` in namespace
`vault-tekton-demo`. A successful login receives a five-minute Vault token with
permission to read only:

```text
aws/creds/lambda-deployer
```

That read makes Vault call AWS STS `AssumeRole` and return a 15-minute access
key, secret key, and session token. The script exports all three in memory,
unsets the Vault token, deploys, invokes Lambda, and clears the AWS values on
exit. Logs show the lease ID, TTL, and assumed-role ARN—never credential values.

## Start the live GitHub trigger

The EventListener is kept private inside the local cluster. GitHub CLI forwards
real repository webhook events to it for development use.

Terminal 1 — EventListener:

```bash
kubectl port-forward \
  --namespace vault-tekton-demo \
  service/el-github-release \
  8080:8080 \
  --address=127.0.0.1
```

Terminal 2 — GitHub webhook forwarding:

```bash
gh extension install cli/gh-webhook
gh webhook forward \
  --repo=OrenAshkenazy/vault-tekton-lambda-cicd-demo \
  --events=push \
  --url=http://127.0.0.1:8080
```

This forwarding mode is for a local interview demo, not production. A
production EventListener should be exposed through authenticated TLS ingress
and validate the provider's webhook signature.

Terminal 3 — read-only Dashboard:

```bash
kubectl port-forward \
  --namespace tekton-pipelines \
  service/tekton-dashboard \
  9097:9097 \
  --address=127.0.0.1
```

Open <http://127.0.0.1:9097> and select namespace `vault-tekton-demo`. The
Dashboard has no username or password; use the local port-forward only on a
trusted single-user workstation and stop it immediately after the demo.

## Trigger the CI/CD pipeline

Only tags beginning with `demo-` pass the EventListener's CEL filter:

```bash
demo_tag="demo-$(date -u +%Y%m%d%H%M%S)"
git tag "${demo_tag}"
git push origin "${demo_tag}"
```

The resulting PipelineRun records the full Git commit SHA as a label, checks
out exactly that SHA, tests it, and passes it into the Lambda environment as
`DEPLOYMENT_SHA`.

In the Dashboard show these proofs in order:

1. `fetch-source`: the checked-out SHA matches the GitHub event.
2. `test-lambda`: handler and credential-leak checks pass.
3. `deploy-and-verify`: Vault lease ID and 900-second TTL are visible.
4. The AWS caller is `assumed-role/VaultTektonLambdaCICDDeployer/...`.
5. `iam:ListUsers` returns `AccessDenied` with that same session.
6. Serverless deploy succeeds.
7. The invoked Lambda returns the exact Git SHA from the GitHub event.

Never display the AWS access key, secret key, session token, or Vault token.

## Audit proof

After the PipelineRun succeeds:

```bash
./demo.sh audit
```

The command selects the latest CI/CD PipelineRun, prints only its safe proof
lines, and finds the matching CloudTrail `AssumeRole` event in `us-east-1`.
CloudTrail Event History can take a few minutes to surface the event; rerun
`audit` rather than showing an unrelated or stale session.

## Presentation opening and close

Open with:

> I will push one Git tag and follow that exact Lambda revision through Tekton,
> Vault, AWS deployment, invocation, and CloudTrail without displaying or
> storing an AWS credential.

Close with:

> GitHub proves source provenance, Tekton proves controlled delivery, Vault
> removes static cloud credentials, IAM limits the deployment identity, and
> CloudTrail proves exactly what happened.

## Cleanup

```bash
./demo.sh cleanup
```

This deletes the dedicated Lambda and CloudFormation stacks, empties and
deletes the deployment bucket, deletes every access key for the dedicated
bootstrap user, and deletes the dedicated kind cluster.
