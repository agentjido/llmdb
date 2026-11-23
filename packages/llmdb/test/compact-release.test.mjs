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
  compactStructures,
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

test("shared structures restore JSON values without shared mutable objects", () => {
  const metadata = JSON.parse(
    '{"__proto__":{"safe":true},"description":"Repeated provider metadata","enabled":false,"optional":null}',
  );
  const array = [0, 1, 2, 3, null, false, metadata];
  const source = { first: metadata, second: metadata, arrays: [array, array] };
  const keys = compactKeys([source]);
  const strings = compactStrings([source]);
  const keyIndexes = new Map(keys.map((key, index) => [key, index]));
  const stringIndexes = new Map(strings.map((value, index) => [value, index]));
  const structures = [metadata, array];
  const structureIndexes = new Map(
    structures.map((value, index) => [JSON.stringify(value), index]),
  );
  const dictionary = structures.map((value) =>
    compactValue(value, keyIndexes, stringIndexes),
  );
  const compact = compactValue(
    source, keyIndexes, stringIndexes, structureIndexes,
  );
  const expand = () => expandCompactValue(keys, strings, compact, dictionary);
  const expanded = expand();

  assert.deepEqual(expanded, source);
  assert.deepEqual(expanded, expandCompactValue(
    keys, strings, compactValue(source, keyIndexes, stringIndexes),
  ));
  assert.deepEqual(compact.slice(1, 3), ["first", [3, 0]]);
  assert.equal(Object.getPrototypeOf(expanded.first), Object.prototype);
  assert.equal(Object.hasOwn(expanded.first, "__proto__"), true);
  assert.notEqual(expanded.first, expanded.second);
  assert.notEqual(expanded.arrays[0], expanded.arrays[1]);
  assert.notEqual(expanded.first, expanded.arrays[0][6]);
  expanded.first.__proto__.safe = false;
  expanded.arrays[0].push("changed");
  assert.equal(expanded.second.__proto__.safe, true);
  assert.deepEqual(expand(), source);
});

test("selects profitable structures with a stable, bounded dictionary", () => {
  const values = Array.from({ length: 100 }, (_, index) => ({
    description: `Repeated structure ${index}: ${"metadata ".repeat(10)}`,
  }));
  const repeated = [...values, ...values];
  const keys = new Map([["description", 0]]);
  const strings = new Map();
  const structures = compactStructures(repeated, keys, strings);

  assert.equal(structures.length, 64);
  assert.deepEqual(
    structures,
    compactStructures(repeated.toReversed(), keys, strings),
  );
  assert.equal(compactStructures(repeated, keys, strings, 8).length, 8);
  assert.deepEqual(compactStructures(values, keys, strings), []);
  assert.deepEqual(compactStructures(repeated, keys, strings, 0), []);
  assert.deepEqual(compactStructures([{ x: 1 }, { x: 1 }], keys, strings), []);
});

test("rejects invalid structure references and dictionary recursion", () => {
  const invalidReferences = [
    [3], [3, 0, 1], [3, -1], [3, 0.5], [3, "0"], [3, 1], [3, NaN],
  ];

  for (const reference of invalidReferences) {
    assert.throws(() => expandCompactValue([], [], reference, [[0]]), TypeError);
  }

  assert.throws(() => expandCompactValue([], [], [3, 0]), TypeError);
  for (const dictionary of [[undefined], [null], [[3, 0]], [[0, "nested", [3, 0]]]]) {
    assert.throws(
      () => expandCompactValue([], [], [3, 0], dictionary), TypeError,
    );
  }
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
