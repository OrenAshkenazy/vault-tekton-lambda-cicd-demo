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
