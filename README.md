# sre-utils

Small utilities for day-to-day SRE work: scripts that use the AWS API (through the AWS CLI) for **surveys** and, when needed, **controlled changes** to resources in the account.

This is not a product or a framework. The tools are small and explicit, meant for security audits, for justifying a change, and for applying a remediation carefully (dry-run first).

**Languages:** English (this file) · [Español](README.es.md)

## Requirements

- [AWS CLI](https://aws.amazon.com/cli/) v2, configured (`aws configure` or `AWS_PROFILE`)
- [jq](https://jqlang.github.io/jq/) to parse JSON responses
- Bash 4+
- IAM read access on the resources you survey; write access only if you run a remediation script with `--apply`

## Structure

```text
sre-utils/
└── aws/
    └── s3/          # Buckets: public access, ACLs, encryption
```

Utilities are grouped by service (`aws/s3`, and later `aws/ec2`, `aws/iam`, and so on) as they are added.

## Current scripts (S3)

| Script | Mode | What it does |
|--------|------|----------|
| `bucketAccessList.sh` | Read-only | Surveys Block Public Access (BPA) per bucket |
| `bucketAnonymousPolicies.sh` | Read-only | Finds policies with `Principal: "*"` (anonymous access). Excludes `*-public-*` |
| `bucketAclSurvey.sh` | Read-only | Surveys Object Ownership and ACLs (AllUsers / AuthenticatedUsers) |
| `bucketEncryptionSurvey.sh` | Read-only | Surveys default encryption (SSE-KMS, SSE-S3, or none) |
| `bucketEnableSseKms.sh` | Dry-run / `--apply` | Plans or applies default SSE-KMS encryption. Excludes `*-public` |

### Examples

```bash
export AWS_PROFILE=my-account

# Surveys
./aws/s3/bucketAccessList.sh
./aws/s3/bucketAnonymousPolicies.sh
./aws/s3/bucketAclSurvey.sh | tee inventory-acl-$(date +%Y%m%d).txt
./aws/s3/bucketEncryptionSurvey.sh

# Remediation: dry-run first, then apply
./aws/s3/bucketEnableSseKms.sh
./aws/s3/bucketEnableSseKms.sh --apply
./aws/s3/bucketEnableSseKms.sh --apply --cmk alias/my-key-s3
```

## Design criteria

- **Survey before you change anything.** Most scripts are read-only.
- **Dry-run by default** on scripts that change state.
- **Explicit exclusions** when a name pattern means public access is intentional (for example buckets matching `*-public*`), so apps that serve files by URL keep working.
- **Terminal output you can paste** into a ticket or a report (`tee`).

## Scope and limits

- They run against the **account / profile** configured in the CLI.
- They do not replace CSPM, Config Rules, or IaC. They support manual work and remediation evidence.
- Check the impact on applications (public URLs, KMS/SigV4, ACLs vs bucket policies) before `--apply`.

## Contributing

Add new scripts under `aws/<service>/`, document usage and mode (read vs write) in this README, and keep dry-run as the default when a script changes resources.
