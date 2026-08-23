#!/usr/bin/env python3
"""Render parameterized Cloudflare PR-preview reference files into a scratch directory."""

from __future__ import annotations

import argparse
import json
import re
import stat
from pathlib import Path


TOKEN = re.compile(r"@@([A-Z0-9_]+)@@")
SLUG = re.compile(r"^[a-z][a-z0-9-]*$")
IDENTIFIER = re.compile(r"^[A-Z][A-Z0-9_]*$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Render Worker/D1 pull-request preview orchestration. "
            "Files are written only under the requested staging output path."
        )
    )
    parser.add_argument("--app-name", required=True)
    parser.add_argument("--preview-worker-name")
    parser.add_argument("--d1-binding", default="DB")
    parser.add_argument("--migrations-dir", default="prisma/migrations")
    parser.add_argument("--built-config", default="dist/wrangler.json")
    parser.add_argument(
        "--url-var",
        action="append",
        dest="url_vars",
        help=(
            "Runtime variable that must equal the deployed URL. Repeat for multiple "
            "variables. Defaults to BETTER_AUTH_URL and VITE_SITE_URL."
        ),
    )
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--force",
        action="store_true",
        help="Replace files in an existing staging output directory.",
    )
    return parser.parse_args()


def validate_relative_path(value: str, flag: str) -> str:
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or value in {"", "."}:
        raise SystemExit(f"{flag} must be a non-empty repository-relative path")
    return path.as_posix()


def quoted_shell_array(values: list[str]) -> str:
    return " ".join(f'"{value}"' for value in values)


def json_url_vars(values: list[str], url: str) -> str:
    return "".join(
        f",\n        {json.dumps(value)}: {json.dumps(url)}" for value in values
    )


def render(template: str, values: dict[str, str], template_name: str) -> str:
    missing = sorted(set(TOKEN.findall(template)) - values.keys())
    if missing:
        raise SystemExit(
            f"Template {template_name} has unresolved tokens: {', '.join(missing)}"
        )
    rendered = TOKEN.sub(lambda match: values[match.group(1)], template)
    leftovers = sorted(set(TOKEN.findall(rendered)))
    if leftovers:
        raise SystemExit(
            f"Template {template_name} still has tokens: {', '.join(leftovers)}"
        )
    return rendered


def main() -> int:
    args = parse_args()
    preview_worker = args.preview_worker_name or f"{args.app_name}-staging"
    url_vars = args.url_vars or ["BETTER_AUTH_URL", "VITE_SITE_URL"]

    for value, label in (
        (args.app_name, "--app-name"),
        (preview_worker, "--preview-worker-name"),
    ):
        if not SLUG.fullmatch(value):
            raise SystemExit(
                f"{label} must start with a lowercase letter and contain only "
                "lowercase letters, digits, and hyphens"
            )

    if len(f"{args.app_name}-production") > 64:
        raise SystemExit("--app-name is too long for the production D1 name")
    if len(f"{args.app_name}-preview-") >= 64:
        raise SystemExit("--app-name leaves no room for a branch in preview D1 names")
    if len(preview_worker) > 54:
        raise SystemExit(
            "--preview-worker-name must leave room for an 8-character preview alias"
        )

    if not IDENTIFIER.fullmatch(args.d1_binding):
        raise SystemExit(
            "--d1-binding must be an uppercase Worker binding identifier"
        )
    for url_var in url_vars:
        if not IDENTIFIER.fullmatch(url_var):
            raise SystemExit(f"Invalid --url-var value: {url_var}")
    if len(set(url_vars)) != len(url_vars):
        raise SystemExit("--url-var values must be unique")

    migrations_dir = validate_relative_path(args.migrations_dir, "--migrations-dir")
    built_config = validate_relative_path(args.built_config, "--built-config")
    output = args.output.resolve()
    if output.exists() and not output.is_dir():
        raise SystemExit(f"Output path is not a directory: {output}")
    if output.exists() and any(output.iterdir()) and not args.force:
        raise SystemExit(
            f"Output directory is not empty: {output}. Pass --force to replace staged files."
        )

    assets_dir = Path(__file__).resolve().parent.parent / "assets"
    templates: dict[str, str] = {
        "preview-resources.sh.tmpl": "scripts/preview-resources.sh",
        "resolve-cloudflare-env.sh.tmpl": "scripts/resolve-cloudflare-env.sh",
        "deploy.sh.tmpl": "scripts/deploy.sh",
        "cleanup-preview-db.sh.tmpl": "scripts/cleanup-preview-db.sh",
        "cleanup-preview-db.yml.tmpl": ".github/workflows/cleanup-preview-db.yml",
        "deployment-history.sql.tmpl": f"{migrations_dir}/0000_deployment_history.sql",
        "wrangler-environments.jsonc.tmpl": "integration/wrangler-environments.jsonc",
        "package-scripts.json.tmpl": "integration/package-scripts.json",
        "CLOUDFLARE_SETUP.md.tmpl": "CLOUDFLARE_SETUP.md",
    }

    values = {
        "APP_NAME": args.app_name,
        "PREVIEW_WORKER_NAME": preview_worker,
        "D1_BINDING": args.d1_binding,
        "MIGRATIONS_DIR": migrations_dir,
        "BUILT_CONFIG": built_config,
        "PRIMARY_URL_VAR": url_vars[-1],
        "FALLBACK_URL_VAR": url_vars[0],
        "URL_VARS_SHELL_ARRAY": quoted_shell_array(url_vars),
        "DEVELOPMENT_URL_VARS_JSON": json_url_vars(
            url_vars, "http://localhost:3000"
        ),
        "PREVIEW_URL_VARS_JSON": json_url_vars(
            url_vars, f"https://{preview_worker}.<subdomain>.workers.dev"
        ),
        "PRODUCTION_URL_VARS_JSON": json_url_vars(
            url_vars, f"https://{args.app_name}.<subdomain>.workers.dev"
        ),
    }

    written: list[Path] = []
    for template_name, relative_output in templates.items():
        source = assets_dir / template_name
        destination = output / relative_output
        if destination.exists() and not args.force:
            raise SystemExit(f"Refusing to replace staged file: {destination}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(
            render(source.read_text(), values, template_name), encoding="utf-8"
        )
        if destination.suffix == ".sh":
            destination.chmod(
                destination.stat().st_mode
                | stat.S_IXUSR
                | stat.S_IXGRP
                | stat.S_IXOTH
            )
        written.append(destination)

    print(f"Rendered {len(written)} files under {output}")
    for path in written:
        print(path.relative_to(output))
    print("Integrate these staged files deliberately; do not copy integration snippets verbatim.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
