import { spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { isDeepStrictEqual } from "node:util";
import { pathToFileURL } from "node:url";

import {
  canonicalSnapshotPath,
  distributionDirectory,
  generatedManifestPath,
  packageDirectory,
} from "./paths.mjs";

const result = spawnSync(
  "npm",
  ["pack", "--dry-run", "--json", "--ignore-scripts"],
  {
    cwd: packageDirectory,
    encoding: "utf8",
  },
);

if (result.status !== 0) {
  process.stderr.write(result.stderr);
  process.exit(result.status ?? 1);
}

const [pack] = JSON.parse(result.stdout);
const fileNames = new Set(pack.files.map((file) => file.path));
const manifest = JSON.parse(await readFile(generatedManifestPath, "utf8"));
const requiredFiles = [
  "LICENSE",
  "README.md",
  "dist/full.d.ts",
  "dist/full.js",
  "dist/generated/manifest.d.ts",
  "dist/generated/manifest.js",
  "dist/generated/provider-loaders.d.ts",
  "dist/generated/provider-loaders.js",
  "dist/index.d.ts",
  "dist/index.js",
  "dist/providers/openai.d.ts",
  "dist/providers/openai.js",
  "dist/snapshot.d.ts",
  "dist/snapshot.js",
  "dist/types.d.ts",
  "package.json",
];

for (const file of requiredFiles) {
  if (!fileNames.has(file)) {
    throw new Error(`Packed artifact is missing ${file}.`);
  }
}

for (const file of fileNames) {
  if (
    file.startsWith("src/") ||
    file.startsWith("scripts/") ||
    (file.endsWith(".json") && file !== "package.json")
  ) {
    throw new Error(`Packed artifact contains development file ${file}.`);
  }
}

const providerJavaScriptCount = [...fileNames].filter(
  (file) => file.startsWith("dist/providers/") && file.endsWith(".js"),
).length;
const providerDeclarationCount = [...fileNames].filter(
  (file) => file.startsWith("dist/providers/") && file.endsWith(".d.ts"),
).length;

if (
  providerJavaScriptCount !== manifest.provider_count ||
  providerDeclarationCount !== manifest.provider_count
) {
  throw new Error("Packed provider entrypoint count is inconsistent.");
}

const sourceSnapshot = JSON.parse(
  await readFile(canonicalSnapshotPath, "utf8"),
);
const snapshotModule = await import(
  `${pathToFileURL(distributionDirectory).href}/snapshot.js`
);

if (!isDeepStrictEqual(snapshotModule.snapshot, sourceSnapshot)) {
  throw new Error("Packed provider shards do not reconstruct the snapshot.");
}

if (pack.size > 2_000_000 || pack.unpackedSize > 10_000_000) {
  throw new Error(
    `Package is too large (${pack.size} packed, ${pack.unpackedSize} unpacked).`,
  );
}

console.log(
  `Package check passed: ${manifest.provider_count} provider entrypoints, ` +
    `${pack.size} bytes packed, ${pack.unpackedSize} bytes unpacked.`,
);
