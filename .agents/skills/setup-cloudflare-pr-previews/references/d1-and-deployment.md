# D1 and Deployment

## Provision and migrate

Keep committed D1 IDs as placeholders. During deployment:

1. List databases and match the exact name.
2. Require production D1 to exist; create stable/branch preview D1 idempotently.
3. Copy source `wrangler.jsonc` to an ignored temporary config.
4. Patch the selected environment's matching D1 binding by name.
5. Apply the migration ledger with the temporary source config and `--remote`.
6. Verify the required deployment-history table.
7. Patch the framework-emitted deploy config's matching top-level binding.

Never write remote IDs into committed Wrangler config or assume the target binding is the first array item. Require at least one migration file. Keep Prisma schema/config, generated client, `migrations_dir`, and the migration workflow aligned when Prisma is present.

Use an existing durable deployment record when equivalent. Otherwise record branch, UTC time, build ID, and commit SHA only after the Worker deploy or version upload succeeds.

## Upload

Use stable `wrangler deploy` for the production and stable-preview Workers. Use `wrangler versions upload --preview-alias <alias>` for a branch preview. Supply every origin-dependent non-secret runtime variable so auth callbacks, WebAuthn origins, CORS, and server URLs match the active alias.

For `@cloudflare/vite-plugin`, the generated config is flattened to the build-time environment. Deploy it without `--env`; keep `--env` only on migration commands that use the unflattened temporary source config. See `vite-plugin-integration.md`.

Keep Better Auth's `BETTER_AUTH_URL` equal to the exact active origin and its secret in Worker secrets. Never pass secrets with `--var`.

## Integrate into the repository

Adapt rather than replace:

- Wrangler environments, preview URLs, bindings, and placeholder IDs.
- Build-time environment selection and public-client URL handling.
- Package scripts using the repository's package manager.
- Existing migration naming and deployment-history model.
- Generated deploy-config path discovered from a real build.
- Gitignore entries for temporary config, build output, `.context`, dev vars, and local Wrangler state.
- Trusted PR-close cleanup and one deployment guide.

If source `wrangler.jsonc` contains comments, replace the rendered `jq` source-patching step with a JSONC-aware parser.

## Verify

Check resolution precedence, local development, both stable builds, a non-production preview, deterministic/bounded naming, matching deploy/cleanup sanitizers, binding-specific patching, migrations, the generated config path, package-manager consistency, and secret absence. With credentials and authorization, deploy and redeploy one non-production test branch, then clean it twice to prove reuse and idempotence. Do not exercise production merely to test setup.

Docs:

- https://developers.cloudflare.com/d1/wrangler-commands/
- https://developers.cloudflare.com/workers/vite-plugin/reference/cloudflare-environments/
