import { readdir, readFile } from "node:fs/promises";

import { generatedProvidersDirectory } from "./paths.mjs";

const providerFiles = (await readdir(generatedProvidersDirectory))
  .filter((file) => file.endsWith(".json"))
  .sort();
const providers = await Promise.all(
  providerFiles.map(async (file) => ({
    id: file.slice(0, -".json".length),
    value: JSON.parse(
      await readFile(`${generatedProvidersDirectory}/${file}`, "utf8"),
    ),
  })),
);
const providerSizes = providers
  .map(({ id, value }) => ({ id, size: jsonSize(value) }))
  .sort(
    (left, right) => right.size - left.size || left.id.localeCompare(right.id),
  );
const modelFields = new Map();
const nestedGroups = new Map();
const statistics = {
  keyBytes: 0,
  keyCounts: new Map(),
  modelCount: 0,
  nullCount: 0,
};

for (const { value: provider } of providers) {
  for (const model of Object.values(provider.models)) {
    statistics.modelCount += 1;

    for (const [field, value] of Object.entries(model)) {
      addBytes(modelFields, field, objectFieldSize(field, value));
    }
  }

  inspectValue(provider, statistics, nestedGroups);
}

const totalBytes = providerSizes.reduce(
  (total, provider) => total + provider.size,
  0,
);
const repeatedKeyEntries = [...statistics.keyCounts].filter(
  ([, count]) => count > 1,
);
const repeatedKeyBytes = repeatedKeyEntries.reduce(
  (total, [key, count]) => total + (jsonSize(key) + 1) * count,
  0,
);

console.log("Canonical provider JSON:");
console.log(`  Providers: ${providers.length}`);
console.log(`  Models: ${statistics.modelCount}`);
console.log(`  Total: ${totalBytes} bytes`);
console.log(`  Object keys: ${statistics.keyBytes} bytes`);
console.log(
  `  Repeated object keys: ${repeatedKeyEntries.length} keys, ` +
    `${repeatedKeyBytes} bytes`,
);
console.log(
  `  Null literals: ${statistics.nullCount} values, ` +
    `${statistics.nullCount * 4} bytes`,
);

console.log("\nModel fields (serialized bytes, largest first):");
printEntries(modelFields);

console.log("\nNested metadata groups (groups can overlap):");
printEntries(nestedGroups);

console.log("\nProviders (source JSON bytes, largest first):");
for (const { id, size } of providerSizes) {
  console.log(`  ${id}: ${size}`);
}

function inspectValue(value, currentStatistics, groups) {
  if (value === null) {
    currentStatistics.nullCount += 1;
    return;
  }

  if (Array.isArray(value)) {
    for (const item of value) {
      inspectValue(item, currentStatistics, groups);
    }

    return;
  }

  if (typeof value !== "object") {
    return;
  }

  for (const [key, childValue] of Object.entries(value)) {
    currentStatistics.keyBytes += jsonSize(key) + 1;
    currentStatistics.keyCounts.set(
      key,
      (currentStatistics.keyCounts.get(key) ?? 0) + 1,
    );

    if (["extra", "benchmarks", "llmfit"].includes(key)) {
      addBytes(groups, key, objectFieldSize(key, childValue));
    }

    inspectValue(childValue, currentStatistics, groups);
  }
}

function addBytes(target, key, bytes) {
  target.set(key, (target.get(key) ?? 0) + bytes);
}

function objectFieldSize(key, value) {
  return jsonSize({ [key]: value }) - 2;
}

function jsonSize(value) {
  return Buffer.byteLength(JSON.stringify(value));
}

function printEntries(entries) {
  for (const [key, bytes] of [...entries].sort(
    (left, right) => right[1] - left[1] || left[0].localeCompare(right[0]),
  )) {
    console.log(`  ${key}: ${bytes}`);
  }
}
