# bonnemai.com static site

This directory contains the static assets for the personal website of Olivier Bonnemaison. The site is optimised for simple static hosting (Amazon S3, CloudFront, etc.) and is intentionally framework-free.

TODO: 
* Use the right AWS_DEPLOY_ROLE_ARN

## Structure

- `index.html` – main landing page
- `404.html` – custom not-found page (make sure S3 is configured to serve this for errors)
- `assets/styles.css` – global styling

## Local preview

```bash
python3 -m http.server 8000
# then open http://localhost:8000
```

## Deployment on Amazon S3

1. Create an S3 bucket named `bonnemai.com` and enable static website hosting.
2. Upload the files in this directory, keeping the folder structure (`assets/styles.css`).
3. Set the bucket policy / ACLs to make the contents publicly readable (or front the bucket with CloudFront).
4. In the static website settings, set `index.html` as the index document and `404.html` as the error document.
5. Point your domain's DNS (typically via Route 53) to the S3 website endpoint or CloudFront distribution.

Optional: add caching headers or a CDN for better global performance.

## Deployment script

Run `./deploy.sh` from the project root to publish the site. The script syncs the
static files to the `bonnemai.com` S3 bucket and then (unless `SKIP_AMPLIFY=1`)
packages the build and triggers an Amplify deployment for the app
(`appId: d3iwsh8gt9f3of`).

Prerequisites:
- AWS CLI configured with credentials allowed to access the bucket and Amplify.
- `curl` and `python3` available locally (used to upload the deployment archive).
- Optional: override defaults with environment variables such as `S3_BUCKET`,
  `AWS_AMPLIFY_BRANCH`, `DRY_RUN=1`, or `SKIP_AMPLIFY=1`.

### Continuous deployment (GitHub Actions)

A GitHub Actions workflow (`.github/workflows/deploy.yml`) syncs the repository
contents to the S3 bucket whenever commits land on `main` (or when run manually
via *Run workflow*). The workflow authenticates with AWS via GitHub OIDC—set a
repository secret `AWS_DEPLOY_ROLE_ARN` containing the ARN of an IAM role that
allows `s3:ListBucket`, `s3:PutObject`, `s3:DeleteObject` on `bonnemai.com` and
trusts `token.actions.githubusercontent.com`.

#### Provisioning the IAM role

Use `scripts/provision_github_deploy_role.sh` to create or update the IAM role
expected by the workflow.

```bash
# customise via ROLE_NAME, BUCKET_NAME, GITHUB_REPO, GITHUB_BRANCH if needed
./scripts/provision_github_deploy_role.sh
```

The script will:
- create the GitHub OIDC provider if it does not already exist
- create/update the IAM role trust policy to allow the specified repo/branch
- attach an inline policy with the required S3 permissions
- output the role ARN to copy into the `AWS_DEPLOY_ROLE_ARN` repository secret
