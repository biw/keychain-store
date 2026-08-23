---
name: setup-cloudflare-pr-previews
description: Set up, audit, or repair Cloudflare Workers PR previews with aliased URLs, branch-isolated D1 databases, migrations, binding injection, stable environments, and PR-close cleanup.
---

# Set Up Cloudflare PR Previews

Create a reusable deployment topology while adapting names, build output, migrations, runtime URL variables, and explicitly shared resources to the target project.

## Route the task

1. Inspect repository instructions, package manager, Wrangler/build config, generated Worker output, migrations, bindings, CI, and deployment docs. Inspect Better Auth and Prisma configuration when present.
2. Read only the references needed:
   - `references/topology-and-lifecycle.md` for naming, stable/branch topology, aliases, isolation, or environment selection.
   - `references/d1-and-deployment.md` for provisioning, migrations, binding injection, deploy commands, or target-repository integration.
   - `references/cleanup-and-operations.md` for PR-close cleanup, GitHub trust boundaries, dashboard configuration, access, or credentials.
   - `references/vite-plugin-integration.md` when the repository uses `@cloudflare/vite-plugin`.
     Read all three core references for a full setup; use only the affected reference for a focused audit or repair.
3. Resolve the resource prefix, Worker names, production branches, D1 binding/migrations, deployable config path, stable URLs, origin-dependent variables, and isolated versus shared bindings before rendering.
4. Render the bundled templates into scratch space, never over the target repository:

```bash
python3 <skill-dir>/scripts/render_templates.py \
  --app-name <app> \
  --preview-worker-name <app-staging> \
  --d1-binding DB \
  --migrations-dir prisma/migrations \
  --built-config dist/wrangler.json \
  --url-var BETTER_AUTH_URL \
  --url-var VITE_SITE_URL \
  --output .context/cloudflare-pr-previews
```

5. Integrate rendered files deliberately. Preserve repository behavior and package-manager conventions; never replace Wrangler, package, build, migration, or workflow files blindly.

## Implementation order

1. Confirm the topology, branch identity, resource-isolation map, and stable URLs.
2. Configure explicit development/preview/production inputs and select the environment before bundling.
3. Provision or resolve D1, apply migrations, patch the actual deploy config by binding name, and upload with active-origin variables.
4. Add trusted PR-close cleanup for only lifecycle-owned branch resources.
5. Adapt the rendered `CLOUDFLARE_SETUP.md` as the single dashboard and operations guide.

## Verification

Run checks that do not mutate Cloudflare first:

```bash
bash -n scripts/resolve-cloudflare-env.sh
bash -n scripts/preview-resources.sh
bash -n scripts/deploy.sh
bash -n scripts/cleanup-preview-db.sh
```

Then verify environment resolution, deterministic deploy/cleanup naming, the real generated config path, binding-specific D1 patching, migrations, package-manager consistency, and secret absence. For Vite builds, confirm flattened-config deployment commands omit `--env`.

If credentials and authorization are available, finish with one real non-production preview deployment, redeploy the same branch to prove reuse, then run manual cleanup for that test branch and confirm a second cleanup is a no-op. Do not exercise production merely to validate the setup.

## Guardrails

- Do not auto-create production databases or production buckets.
- Do not delete stable preview or production resources.
- Do not expose secrets through `--var`, source config, logs, or committed dotenv files.
- Do not claim full per-PR isolation when any mutable binding is shared; list shared bindings explicitly.
- Do not use this preview-URL topology for Durable Object Workers or derive an alias from a custom hostname.
- Do not feed commented JSONC to generated `jq`; keep it JSON-compatible or use a JSONC-aware parser.
- Do not treat migration as deployment; record history only after Worker upload succeeds.
- Fail visibly on D1/authentication errors and do not add unnecessary GitHub write permissions.

## Resources

- `references/topology-and-lifecycle.md`: deployment modes, environment resolution, naming, aliases, and binding isolation.
- `references/d1-and-deployment.md`: provisioning, migrations, binding patching, upload modes, and repository integration.
- `references/cleanup-and-operations.md`: cleanup trust boundary, Workers Builds setup, credentials, and public access.
- `references/vite-plugin-integration.md`: dual-config patching and build-time/runtime URL handling.
- `scripts/render_templates.py`: render parameterized orchestration files into a scratch directory.
- `assets/*.tmpl`: source templates copied by the renderer; integrate them rather than editing the skill in place.
