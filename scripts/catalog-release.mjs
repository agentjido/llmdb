import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [mode, version, snapshotPath, directory] = process.argv.slice(2);
if (!["prepare", "verify"].includes(mode) || !/^\d{4}\.\d{1,2}\.\d+$/.test(version ?? "") ||
    !snapshotPath || !directory) {
  throw new Error("Usage: catalog-release.mjs prepare|verify VERSION SNAPSHOT DIRECTORY");
}

const name = "catalog-full.json";
const snapshot = readFileSync(snapshotPath);
const { snapshot_id, providers } = JSON.parse(snapshot);
if (!/^[0-9a-f]{64}$/.test(snapshot_id ?? "") || !providers || Array.isArray(providers) ||
    typeof providers !== "object" || Object.keys(providers).length === 0) {
  throw new Error("Expected a complete canonical snapshot");
}

const manifestPath = join(directory, "catalog-manifest.json");
const expected = {
  version: 1,
  release_version: version,
  snapshot_id,
  asset: name,
  bytes: snapshot.length,
  sha256: createHash("sha256").update(snapshot).digest("hex"),
};

if (mode === "prepare") {
  writeFileSync(join(directory, name), snapshot);
  writeFileSync(manifestPath, JSON.stringify(expected, null, 2) + "\n");
} else {
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  for (const [field, value] of Object.entries(expected)) {
    if (manifest[field] !== value) throw new Error(`Catalog manifest mismatch: ${field}`);
  }
}
