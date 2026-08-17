import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { expandCompactValue } from "../dist/compact.js";
import {
  compactKeys,
  compactStrings,
  compactValue,
} from "../scripts/compact.mjs";

test("compacts repeated keys and restores exact JSON objects", () => {
  const source = JSON.parse(
    '{"id":"provider","models":[{"id":"one","summary":"A repeated model description that is long enough to compact"},{"id":"two","summary":"A repeated model description that is long enough to compact"}],"__proto__":{"safe":true}}',
  );
  const keys = compactKeys([source]);
  const strings = compactStrings([source]);
  const indexes = new Map(keys.map((key, index) => [key, index]));
  const stringIndexes = new Map(
    strings.map((value, index) => [value, index]),
  );
  const compact = compactValue(source, indexes, stringIndexes);
  const expanded = expandCompactValue(keys, strings, compact);

  assert.ok(keys.includes("id"));
  assert.ok(
    strings.includes(
      "A repeated model description that is long enough to compact",
    ),
  );
  assert.deepEqual(expanded, source);
  assert.equal(Object.getPrototypeOf(expanded), Object.prototype);
  assert.equal(Object.hasOwn(expanded, "__proto__"), true);
});

test("rejects invalid compact data", () => {
  assert.throws(
    () => expandCompactValue([], [], [0, 99, "value"]),
    TypeError,
  );
  assert.throws(() => expandCompactValue([], [], [2, 0]), TypeError);
  assert.throws(() => expandCompactValue([], [], [3]), TypeError);
});

test("checks an NPM provenance statement against the release tag", async () => {
  const directory = await mkdtemp(join(tmpdir(), "llmdb-provenance-"));
  const auditPath = join(directory, "audit.json");
  const version = "2026.8.4";
  const releaseSha = "a".repeat(40);

  try {
    await writeFile(
      auditPath,
      JSON.stringify(audit(version, releaseSha, `refs/tags/${version}`)),
    );

    assert.match(
      runVerifier(auditPath, version, releaseSha),
      /Verified NPM signature and provenance/,
    );

    await writeFile(
      auditPath,
      JSON.stringify(audit(version, releaseSha, "refs/heads/main")),
    );

    assert.throws(
      () => runVerifier(auditPath, version, releaseSha),
      /does not identify the release tag and commit/,
    );
  } finally {
    await rm(directory, { force: true, recursive: true });
  }
});

function runVerifier(auditPath, version, releaseSha) {
  return execFileSync(
    process.execPath,
    [
      fileURLToPath(
        new URL("../scripts/verify-npm-provenance.mjs", import.meta.url),
      ),
      auditPath,
      version,
      releaseSha,
    ],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
  );
}

function audit(version, releaseSha, ref) {
  const statement = {
    predicate: {
      buildDefinition: {
        externalParameters: {
          workflow: {
            path: ".github/workflows/release.yml",
            ref,
            repository: "https://github.com/agentjido/llmdb",
          },
        },
        internalParameters: { github: { event_name: "workflow_dispatch" } },
        resolvedDependencies: [
          { digest: { gitCommit: releaseSha }, uri: "git+https://example.test" },
        ],
      },
    },
  };

  return {
    verified: [
      {
        name: "@agentjido/llmdb",
        version,
        attestationBundles: [
          {
            predicateType: "https://slsa.dev/provenance/v1",
            bundle: {
              dsseEnvelope: {
                payload: Buffer.from(JSON.stringify(statement)).toString(
                  "base64",
                ),
              },
            },
          },
        ],
      },
    ],
  };
}
