# Cleanup and Operations

## Trusted PR-close cleanup

Use `pull_request_target` only for `closed`. It can access base-repository secrets, so execute trusted base-branch code only:

- check out `pull_request.base.ref`, never the head SHA;
- use only `contents: read` GitHub permission;
- install from the base lockfile;
- pass the head branch name as data, not executable code;
- derive the database name with the exact deploy sanitizer;
- skip protected production branches and treat only an absent database as a successful no-op;
- delete only the branch D1 database owned by this lifecycle.

Do not delete stable preview/production resources, shared bindings, or Worker version history. Fail visibly when credentials, D1 listing, or deletion fail.

Configure `CLOUDFLARE_ACCOUNT_ID` as a repository variable and `CLOUDFLARE_API_TOKEN` as a secret scoped to the target account with D1 list/delete access.

## Workers Builds

Connect two projects:

| Project         | Build variable              | Branch policy                          |
| --------------- | --------------------------- | -------------------------------------- |
| `<app>`         | `CLOUDFLARE_ENV=production` | Production branch only                 |
| `<app>-staging` | `CLOUDFLARE_ENV=preview`    | Production and non-production branches |

Use the repository bundle command and dynamic deploy script. On the preview project, replace both the production-branch and non-production deploy commands; the default non-production upload bypasses D1 provisioning, migrations, binding patching, and URL overrides.

Verify each Workers Builds token can upload the Worker and edit D1. Configure runtime secrets separately for preview and production. Create stable resources once; branch D1 databases are dynamic.

## Operations guide

Adapt the rendered `CLOUDFLARE_SETUP.md` rather than creating competing docs. Record:

- both projects, branch policies, build/deploy commands, and stable bootstrap;
- repository variables, GitHub secrets, Worker secrets, and token permissions;
- isolated/shared binding decisions;
- public preview policy and Cloudflare Access when required;
- manual cleanup, rollback expectations, and resource ownership.

Application authentication is not a network boundary. Preview URLs are public when enabled unless Access protects them.

Docs:

- https://developers.cloudflare.com/workers/ci-cd/builds/configuration/
- https://developers.cloudflare.com/workers/versions-and-deployments/preview-urls/
