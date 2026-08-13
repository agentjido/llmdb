import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const packageDirectory = fileURLToPath(new URL("../", import.meta.url));
const repositoryDirectory = fileURLToPath(new URL("../../../", import.meta.url));
const typeScriptCli = join(
  repositoryDirectory,
  "node_modules/typescript/bin/tsc",
);

test("installs and imports the packed package in a clean consumer", async () => {
  const consumerDirectory = await mkdtemp(join(tmpdir(), "llmdb-packed-"));
  const packedDirectory = join(consumerDirectory, "packed");

  try {
    await mkdir(packedDirectory);
    const [pack] = JSON.parse(
      run(
        "npm",
        [
          "pack",
          "--json",
          "--ignore-scripts",
          "--pack-destination",
          packedDirectory,
        ],
        packageDirectory,
      ),
    );
    const archivePath = join(packedDirectory, pack.filename);

    await writeFile(
      join(consumerDirectory, "package.json"),
      JSON.stringify({
        name: "llmdb-packed-smoke",
        private: true,
        type: "module",
      }),
    );
    run(
      "npm",
      ["install", "--ignore-scripts", "--no-audit", "--no-fund", archivePath],
      consumerDirectory,
    );

    await writeFile(join(consumerDirectory, "smoke.mjs"), runtimeConsumer);
    run(process.execPath, ["smoke.mjs"], consumerDirectory);

    await writeFile(join(consumerDirectory, "consumer.ts"), typeConsumer);
    await writeFile(join(consumerDirectory, "tsconfig.json"), typeScriptConfig);
    run(
      process.execPath,
      [typeScriptCli, "--project", "tsconfig.json"],
      consumerDirectory,
    );
  } finally {
    await rm(consumerDirectory, { force: true, recursive: true });
  }
});

function run(command, arguments_, cwd) {
  return execFileSync(command, arguments_, {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

const runtimeConsumer = `
import assert from "node:assert/strict";
import { llmdb, manifest } from "@jido/llmdb";
import { catalog } from "@jido/llmdb/full";
import snapshot from "@jido/llmdb/snapshot";
import rawSnapshot from "@jido/llmdb/raw";
import openai from "@jido/llmdb/providers/openai";

assert.equal((await llmdb.get("openai:gpt-5.4")).id, "gpt-5.4");
assert.equal(openai.get("gpt-5.4").id, "gpt-5.4");
assert.equal(catalog.get("openai:gpt-5.4").id, "gpt-5.4");
assert.equal(snapshot.snapshot_id, manifest.snapshot_id);
assert.equal(rawSnapshot.snapshot_id, snapshot.snapshot_id);
`;

const typeConsumer = `
import { llmdb, type Model, type Snapshot } from "@jido/llmdb";
import { catalog } from "@jido/llmdb/full";
import snapshot from "@jido/llmdb/snapshot";
import openai from "@jido/llmdb/providers/openai";

const lazyModel: Promise<Model> = llmdb.get("openai:gpt-5.4");
const directModel: Model = openai.get("gpt-5.4");
const fullModel: Model = catalog.get("openai:gpt-5.4");
const canonicalSnapshot: Snapshot = snapshot;

void lazyModel;
void directModel;
void fullModel;
void canonicalSnapshot;
`;

const typeScriptConfig = JSON.stringify({
  compilerOptions: {
    exactOptionalPropertyTypes: true,
    module: "NodeNext",
    moduleResolution: "NodeNext",
    noEmit: true,
    strict: true,
    target: "ES2023",
  },
  include: ["consumer.ts"],
});
