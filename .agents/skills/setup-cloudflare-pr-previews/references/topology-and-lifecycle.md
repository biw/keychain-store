# Topology and Lifecycle

## Deployment modes

Use two stable Workers and three D1 classes:

| Trigger                               | Worker action          | D1 database              | URL                                                |
| ------------------------------------- | ---------------------- | ------------------------ | -------------------------------------------------- |
| Production branch, production project | Stable deploy          | `<app>-production`       | Stable production URL                              |
| Production branch, preview project    | Stable deploy          | `<app>-staging`          | Stable preview URL                                 |
| Other branch, preview project         | Aliased version upload | `<app>-preview-<branch>` | `<alias>-<preview-worker>.<subdomain>.workers.dev` |

Branch previews are versions of the stable preview Worker, not separately named Workers. Two PRs from the same branch intentionally share an alias and database. If forks, long-name collisions, or multiple PRs per branch are possible, agree on a hashed, PR-number, or repository-qualified identity before implementation.

Preview URLs require the `workers.dev` host, are public unless protected with Cloudflare Access, and are unavailable for Workers that implement Durable Objects.

## Environment resolution

Resolve in this order:

1. explicit `CLOUDFLARE_ENV`;
2. known Worker/project name;
3. one unambiguous stable URL override;
4. Workers Builds branch/build presence;
5. local `development` fallback.

Set `CLOUDFLARE_ENV=production` on the production project and `preview` on the preview project. Branch name alone is insufficient because the production branch builds both stable Workers. Preserve `WORKERS_CI_BRANCH`, `WORKERS_CI_COMMIT_SHA`, and `WORKERS_CI_BUILD_UUID`.

## Naming

Use one shared database sanitizer in deploy and cleanup. The rendered convention lowercases, maps `/` to `-` and `.` to `_`, replaces invalid runs, collapses separators, trims, falls back to `preview`, and truncates the final D1 name to 64 characters.

Preview aliases allow lowercase letters, numbers, and dashes, must begin with a letter, and must leave the combined `<alias>-<worker-name>` within 63 characters. Truncation can collide; change the identity contract when repository naming makes that plausible.

## Binding isolation

Classify every binding:

| Class                 | Examples                          | Branch behavior                                   |
| --------------------- | --------------------------------- | ------------------------------------------------- |
| Isolated mutable      | D1, write-heavy KV, branch queues | Provision and clean up per branch                 |
| Deliberately shared   | staging R2, immutable fixtures    | Bind stable preview resource; never delete per PR |
| Production-only       | production D1/R2/KV/secrets       | Bind only in production                           |
| External/irreversible | email, payments, webhooks         | Disable, sandbox, or explicitly scope             |

Document all shared mutable state; do not claim full isolation when any mutable binding is shared.

Docs:

- https://developers.cloudflare.com/workers/versions-and-deployments/preview-urls/
- https://developers.cloudflare.com/workers/ci-cd/builds/configuration/
- https://developers.cloudflare.com/workers/wrangler/environments/
