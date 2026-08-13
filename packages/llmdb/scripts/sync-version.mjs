import { readFile, writeFile } from "node:fs/promises";

import {
  mixProjectPath,
  packageJsonPath,
  rootPackageLockPath,
} from "./paths.mjs";

const checkOnly = process.argv.includes("--check");
const mixProject = await readFile(mixProjectPath, "utf8");
const match = mixProject.match(/@version\s+"([^"]+)"/);

if (match === null || match[1] === undefined) {
  throw new Error("Could not read @version from mix.exs.");
}

const elixirVersion = match[1];
const packageJson = JSON.parse(await readFile(packageJsonPath, "utf8"));
const packageLock = JSON.parse(await readFile(rootPackageLockPath, "utf8"));
const workspaceLock = packageLock.packages?.["packages/llmdb"];

if (
  packageJson.version === elixirVersion &&
  workspaceLock?.version === elixirVersion
) {
  console.log(`NPM and Elixir versions are in sync at ${elixirVersion}.`);
  process.exit(0);
}

if (checkOnly) {
  throw new Error(
    `NPM package version ${packageJson.version} and lock version ` +
      `${workspaceLock?.version ?? "(missing)"} must match Elixir version ` +
      `${elixirVersion}. Run npm run npm:sync.`,
  );
}

if (workspaceLock === undefined) {
  throw new Error("Could not find packages/llmdb in package-lock.json.");
}

packageJson.version = elixirVersion;
workspaceLock.version = elixirVersion;

await Promise.all([
  writeFile(packageJsonPath, `${JSON.stringify(packageJson, null, 2)}\n`),
  writeFile(rootPackageLockPath, `${JSON.stringify(packageLock, null, 2)}\n`),
]);
console.log(`Updated the NPM package version to ${elixirVersion}.`);
