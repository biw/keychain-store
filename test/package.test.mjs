import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const rootDirectory = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const packageName = "keychain-store";

const packageManifest = JSON.parse(readFileSync(path.join(rootDirectory, "package.json"), "utf8"));

const run = (command, arguments_, cwd) =>
  execFileSync(command, arguments_, { cwd, encoding: "utf8", stdio: "pipe" });

const findTarball = (directory) => {
  const tarball = readdirSync(directory).find((name) => name.startsWith(`${packageName}-`));
  assert.ok(tarball, "npm pack should create a package tarball");
  return path.join(directory, tarball);
};

test("installs the packed package for ESM, CommonJS, and TypeScript consumers", () => {
  assert.deepEqual(packageManifest.cpu, ["arm64", "x64"]);

  const temporaryDirectory = mkdtempSync(path.join(tmpdir(), "keychain-store-package-"));
  const packageDirectory = path.join(temporaryDirectory, "package");
  const consumerDirectory = path.join(temporaryDirectory, "consumer");

  try {
    mkdirSync(packageDirectory);
    mkdirSync(consumerDirectory);
    run("npm", ["pack", "--ignore-scripts", "--pack-destination", packageDirectory], rootDirectory);

    const tarball = findTarball(packageDirectory);
    const contents = run("tar", ["-tzf", tarball], rootDirectory);
    const targetBinary = `package/dist/keychain_store.darwin-${process.arch}.node`;
    for (const requiredPath of [
      "package/dist/index.js",
      "package/dist/index.cjs",
      "package/dist/index.d.ts",
      "package/dist/index.d.cts",
      targetBinary,
    ]) {
      assert.ok(contents.includes(requiredPath), `packed package must contain ${requiredPath}`);
    }

    writeFileSync(
      path.join(consumerDirectory, "package.json"),
      JSON.stringify({ name: "keychain-store-package-test", private: true, type: "module" }),
    );
    run("npm", ["install", "--ignore-scripts", tarball], consumerDirectory);

    const esmOutput = run(
      process.execPath,
      [
        "--input-type=module",
        "-e",
        `
          import { openKeychainStore } from "${packageName}";
          const store = openKeychainStore({
            accounts: ["token"],
            authentication: "none",
            iCloudSync: false,
          });
          if (typeof store.get !== "function") process.exit(1);
        `,
      ],
      consumerDirectory,
    );
    assert.equal(esmOutput, "");

    const commonJsOutput = run(
      process.execPath,
      [
        "-e",
        `
          const { openKeychainStore } = require("${packageName}");
          const store = openKeychainStore({
            accounts: ["token"],
            authentication: "none",
            iCloudSync: false,
          });
          if (typeof store.set !== "function") process.exit(1);
        `,
      ],
      consumerDirectory,
    );
    assert.equal(commonJsOutput, "");

    writeFileSync(
      path.join(consumerDirectory, "type-smoke.ts"),
      `
        import { openKeychainStore } from "${packageName}";

        const store = openKeychainStore({
          accounts: ["data-key", "archive-key"] as const,
          mutableAccounts: ["token"] as const,
          authentication: "none",
          iCloudSync: false,
        });

        const token: Promise<string | null> = store.get("token", "string");
        const dataKey: Promise<Uint8Array | null> = store.get("data-key", "Uint8Array");
        const generated: Promise<Uint8Array> = store.getOrCreate("data-key");
        const supplied: Promise<string> = store.getOrCreate("token", "initial token");
        const written: Promise<void> = store.set("token", "updated token");

        void [token, dataKey, generated, supplied, written];

        // @ts-expect-error Immutable accounts cannot be changed.
        store.set("archive-key", "nope");
        // @ts-expect-error Account names are checked from the declared arrays.
        store.get("not-configured", "string");
      `,
    );
    writeFileSync(
      path.join(consumerDirectory, "type-smoke.cts"),
      `
        import keychainStore = require("${packageName}");

        const store = keychainStore.openKeychainStore({
          accounts: ["token"] as const,
          authentication: "none",
          iCloudSync: false,
        });

        const token: Promise<string | null> = store.get("token", "string");
        const generated: Promise<Uint8Array> = store.getOrCreate("token");

        void [token, generated];
      `,
    );

    const tsc = path.join(rootDirectory, "node_modules", "typescript", "bin", "tsc");
    run(
      process.execPath,
      [
        tsc,
        "--module",
        "NodeNext",
        "--moduleResolution",
        "NodeNext",
        "--target",
        "ES2023",
        "--strict",
        "--noEmit",
        "type-smoke.ts",
        "type-smoke.cts",
      ],
      consumerDirectory,
    );
  } finally {
    rmSync(temporaryDirectory, { force: true, recursive: true });
  }
}, 120_000);
