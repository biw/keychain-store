# Cloudflare Vite Plugin Integration

## Contents

1. [Why two configs are involved](#why-two-configs-are-involved)
2. [Build-time environment selection](#build-time-environment-selection)
3. [Public URL variables](#public-url-variables)
4. [Runtime URL override](#runtime-url-override)
5. [Verification](#verification)

## Why Two Configs Are Involved

With `@cloudflare/vite-plugin`, `wrangler.jsonc` is build input. The plugin emits a deployable Worker config with the bundle. Its path depends on the framework and build configuration, so locate it from a real build instead of assuming a fixed output path.

The emitted config is flattened to the environment selected at build time. Deploy that generated config without `--env`; deployment-time environment selection is not applicable to the flattened output.

The D1 UUID must be patched in both places for different reasons:

- a temporary copy of source `wrangler.jsonc` lets Wrangler target the correct D1 database while applying migrations and running verification SQL;
- the emitted built config controls the D1 binding attached to the uploaded Worker version.

Patching only the source copy migrates the right database but can upload a Worker bound to the placeholder or stable database. Patching only the built config uploads the right binding but leaves migration commands unable to resolve the ephemeral database.

Patch by binding name. Do not assume the target D1 binding is the first item in either array.

## Build-Time Environment Selection

The Vite plugin reads a Wrangler environment at build time through `CLOUDFLARE_ENV`. Resolve and export it before `vite build`:

```json
{
  "scripts": {
    "bundle": "bash -c 'env_name=\"$(bash scripts/resolve-cloudflare-env.sh)\"; echo \"Building for Cloudflare environment: $env_name\"; CLOUDFLARE_ENV=\"$env_name\" vite build'"
  }
}
```

Do not add `--env` to Vite itself. `--env` is a Wrangler command flag; the Cloudflare Vite plugin uses `CLOUDFLARE_ENV`.

## Public URL Variables

Client-exposed values such as `VITE_SITE_URL` are usually compiled into browser code. Read them from the selected Wrangler environment during Vite configuration and inject only the public prefix:

```ts
import { fileURLToPath } from "node:url";
import { unstable_readConfig } from "wrangler";

const wranglerConfigPath = fileURLToPath(new URL("./wrangler.jsonc", import.meta.url));

function getClientRuntimeEnv(): Record<string, string> {
  const cloudflareEnv = process.env.CLOUDFLARE_ENV ?? "development";
  const { vars } = unstable_readConfig({
    config: wranglerConfigPath,
    env: cloudflareEnv,
  });

  return Object.fromEntries(
    Object.entries(vars ?? {}).filter(
      (entry): entry is [string, string] =>
        entry[0].startsWith("VITE_") && typeof entry[1] === "string",
    ),
  );
}
```

Map the returned entries into Vite `define` keys such as `import.meta.env.VITE_SITE_URL`. Never expose secrets with this mechanism.

The stable preview URL is present at bundle time, but a branch alias URL is not known until deployment. Code that truly bakes a branch-specific public URL into browser assets must receive that URL before the bundle or derive it from `window.location.origin`. Passing URL vars to Wrangler updates Worker runtime variables; verify the client build separately rather than assuming `--var` rewrites already-bundled browser JavaScript.

## Runtime URL Override

Collect process overrides for URL-dependent variables and merge them into the plugin config so explicit local or CI build inputs reach the Worker runtime:

```ts
const runtimeEnvOverrideKeys = ["BETTER_AUTH_URL", "VITE_SITE_URL"] as const;

const runtimeEnvOverrides = Object.fromEntries(
  runtimeEnvOverrideKeys.flatMap((key) => {
    const value = process.env[key];
    return value ? [[key, value]] : [];
  }),
);

cloudflare({
  config: (config) => ({
    vars: {
      ...(config.vars ?? {}),
      ...runtimeEnvOverrides,
    },
  }),
  viteEnvironment: { name: "ssr" },
});
```

During remote deployment, also pass each origin-dependent runtime variable with Wrangler `--var KEY:value`. Keep authentication secrets in Worker secrets, never these flags.

For Better Auth, `BETTER_AUTH_URL` must exactly match the active stable or aliased origin. Keep `BETTER_AUTH_SECRET` as an environment-specific Worker secret rather than a build variable, public Vite value, or Wrangler `--var` argument.

## Verification

1. Build once with `CLOUDFLARE_ENV=preview`.
2. Confirm the emitted config exists at the path consumed by `deploy.sh`.
3. Inspect its `name`, `vars`, D1 binding, R2 bindings, compatibility date, and preview URL setting.
4. Run a copy of the D1 patch operation against the emitted config and assert only the configured binding changed.
5. Confirm generated-config deploy and version-upload commands do not pass `--env`.
6. Verify browser code does not contain a secret or an incorrect stable URL where the active origin is required.
7. Run local development with a non-default port when the app supports it and confirm server and client origin handling remain aligned.

Cloudflare documents the flattened build config and build-time environment selection here: <https://developers.cloudflare.com/workers/vite-plugin/reference/cloudflare-environments/>.
