# Authentication flow: the short, ADHD-friendly version

Remember one sentence:

> Kubernetes proves who the Tekton workload is; Vault trades that identity for
> a temporary AWS credential.

And one sequence:

```text
Kubernetes ID card → Vault visitor badge → AWS keycard → deploy → expire
```

## The three credentials

| Credential | Meaning | Lifetime | Location |
|---|---|---:|---|
| Kubernetes JWT | “I am the approved Tekton workload” | 10 minutes | File mounted only in the deploy step |
| Vault token | “I may request the Lambda deployer role” | 5 minutes | Deploy process memory |
| AWS STS credentials | “I may deploy this Lambda” | 15 minutes | Deploy process environment |

None is stored as a GitHub or Kubernetes Secret.

## Kubernetes resource map

### Webhook and trigger path

```text
GitHub push
   │
   ▼
Service/el-github-release
   │ routes to the Pod managed by Deployment/el-github-release
   ▼
EventListener/github-release ──uses──► ServiceAccount/github-trigger
   ▼
ClusterInterceptor/cel checks event type, tag prefix, and repository
   ▼
TriggerBinding/github-release extracts tag, object ID, and fixed repository URL
   ▼
TriggerTemplate/lambda-cicd
   │ EventListener sink instantiates
   ▼
PipelineRun/lambda-cicd-* ──references──► Pipeline/lambda-cicd
```

The EventListener controller creates its `Service` and `Deployment`. The
EventListener sink resolves the binding and template, then creates the
PipelineRun. The PipelineRun references the existing Pipeline definition.

### Pipeline ownership tree

```text
PipelineRun/lambda-cicd-*
├─ owns PVC/pvc-*                         shared source workspace
├─ owns TaskRun/*-fetch-source
│  └─ owns Pod/*-fetch-source-pod         no service-account token
├─ owns TaskRun/*-test-lambda
│  └─ owns Pod/*-test-lambda-pod          no service-account token
└─ owns TaskRun/*-deploy-and-verify
   └─ owns Pod/*-deploy-and-verify-pod
      ├─ uses ServiceAccount/tekton-ci
      ├─ reads ConfigMap/lambda-cicd-config (non-secret AWS settings)
      └─ mounts an explicit 10-minute, Vault-audience JWT
```

The Pipeline controller turns the PipelineRun into three TaskRuns. The TaskRun
controller creates one Pod for each TaskRun. The PipelineRun owns the shared
PVC directly.

### Vault validation path

```text
deploy Pod → Service/vault → StatefulSet Pod/vault-0
                               │ uses ServiceAccount/vault
                               ▼
ClusterRoleBinding/vault-tekton-demo-token-review
                               │ binds
                               ▼
ClusterRole/system:auth-delegator
                               │ permits TokenReview creation
                               ▼
Kubernetes TokenReview API
```

## What each RBAC object does

| Object | Subject | Permission and reason |
|---|---|---|
| `RoleBinding/github-trigger-eventlistener` | `ServiceAccount/github-trigger` | Inside `vault-tekton-demo`: read trigger definitions and ConfigMaps; create PipelineRuns, TaskRuns, PipelineResources, and events; impersonate ServiceAccounts; patch events |
| `ClusterRole/vault-tekton-demo-eventlistener-cluster` | Bound below | Read/list/watch ClusterInterceptors and ClusterTriggerBindings; unlike Tekton's broader installed role, it grants no Secret access |
| `ClusterRoleBinding/github-trigger-eventlistener` | `ServiceAccount/github-trigger` | Attach the preceding cluster-scoped read permissions to the EventListener identity |
| `ClusterRoleBinding/vault-tekton-demo-token-review` | `ServiceAccount/vault` | Use `system:auth-delegator` to create TokenReview and SubjectAccessReview requests |
| No binding for `tekton-ci` | `ServiceAccount/tekton-ci` | It needs no Kubernetes API permission; its identity is useful to Vault even without Kubernetes RBAC privileges |

Two similarly named objects do different jobs:

- A `RoleBinding` grants permissions only in one namespace.
- A `ClusterRoleBinding` grants the referenced permissions cluster-wide.

The Tekton and Vault installation controllers have their own platform RBAC.
They are installation concerns, not identities used by this application
pipeline.

## Step 1: Kubernetes gives Tekton an ID card

Only `deploy-and-verify` receives this file:

```text
/var/run/secrets/vault/token
```

The JWT says:

```text
service account: tekton-ci
namespace:       vault-tekton-demo
audience:        vault
expires:         10 minutes
```

`fetch-source` and `test-lambda` receive no service-account token.

## Step 2: Tekton shows the ID card to Vault

The trusted deploy entrypoint calls:

```bash
vault write auth/kubernetes/login \
  role=tekton-lambda-deployer \
  jwt=@/var/run/secrets/vault/token
```

### Why the Pod YAML does not show that command

The Pipeline's Tekton step contains only:

```bash
/usr/local/bin/deploy-lambda
```

Tekton writes that snippet into `/tekton/scripts/script-*`. Therefore, the
generated Pod shows `/tekton/bin/entrypoint` launching the generated script,
not the nested Vault command. That script calls `/usr/local/bin/deploy-lambda`.
The `Dockerfile` copies `app/deploy.sh` to that path when it builds the pinned
tool image, and `vault write` is inside that file.

It runs at this exact point:

```text
fetch-source succeeds
        ↓
test-lambda succeeds
        ↓
deploy-and-verify starts
        ↓
/usr/local/bin/deploy-lambda
        ↓
vault write auth/kubernetes/login
```

The script uses `set -euo pipefail`, not `set -x`, so logs show the safe
`1/5 Authenticating...` milestone without echoing the JWT or later credentials.

Vault asks the Kubernetes TokenReview API whether the JWT is genuine. It checks
the service account, namespace, audience, signature, and expiration.

Wrong identity? Stop. Expired token? Stop. Wrong audience? Stop.

## Step 3: Vault gives Tekton a visitor badge

After validation, Vault returns a five-minute token. Its only
application-secret capability is:

```text
read aws/creds/lambda-deployer
```

It is not a Vault administrator token and cannot read unrelated secrets.

## Step 4: Vault asks AWS for a temporary keycard

Tekton reads `aws/creds/lambda-deployer`. Vault then calls:

```text
AWS STS AssumeRole → VaultTektonLambdaCICDDeployer
```

AWS returns a temporary access key, secret key, and session token. They last 15
minutes and are exported only inside the deploy process.

## Step 5: Tekton deploys and access ends

```text
Serverless Framework → CloudFormation → Lambda
```

When the Task ends, its process exits and clears the credential variables. The
completed Pod may remain temporarily so operators can inspect its safe logs,
but the Vault token and AWS credentials still expire. CloudTrail keeps the
`AssumeRole` audit event.

## What the demo proves

Look for these lines in `deploy-and-verify`:

```text
AUDIT Lease TTL: 900s
AUDIT AWS caller: ...assumed-role/VaultTektonLambdaCICDDeployer/...
PROOF unrelated IAM operation denied: PASS (AccessDenied)
PROOF deployed Lambda returned Git SHA ...: PASS
```

The important security moment is the denial: the same credential that deploys
Lambda cannot enumerate IAM users.

## What `demo-root` is—and is not

`demo-root` configures the disposable Vault dev server during
`./demo.sh prepare`. Tekton never uses it.

Production Vault would use OIDC or LDAP for humans, Kubernetes Auth for
workloads, encrypted persistent storage, TLS, auto-unseal, and no root token in
a script.

## Say this in 20 seconds

> The deploy Task gets a short-lived Kubernetes identity, not an AWS secret.
> Vault validates that identity with Kubernetes and returns a narrowly scoped
> Vault token. Vault then assumes the AWS deployment role and provides a
> 15-minute STS credential. Tekton deploys Lambda, the credentials expire,
> and CloudTrail records the role assumption.
