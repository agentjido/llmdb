import { mkdir, readFile, writeFile } from "node:fs/promises";

import { compactKeys, compactStrings, compactValue } from "./compact.mjs";
import {
  distributionDirectory,
  distributionProvidersDirectory,
  generatedManifestPath,
} from "./paths.mjs";

const manifest = JSON.parse(await readFile(generatedManifestPath, "utf8"));
const providerIds = Object.keys(manifest.providers).sort();
const providers = new Map(
  await Promise.all(
    providerIds.map(async (providerId) => [
      providerId,
      JSON.parse(
        await readFile(
          new URL(`../generated/providers/${providerId}.json`, import.meta.url),
          "utf8",
        ),
      ),
    ]),
  ),
);
const sharedKeys = compactKeys(providers.values());
const keyIndexes = new Map(sharedKeys.map((key, index) => [key, index]));
const sharedStrings = compactStrings(providers.values());
const stringIndexes = new Map(
  sharedStrings.map((value, index) => [value, index]),
);

await mkdir(distributionProvidersDirectory, { recursive: true });

const providerVariables = providerIds.map(
  (_providerId, index) => `provider${index}`,
);

await Promise.all(
  providerIds.flatMap((providerId) => {
    const provider = providers.get(providerId);

    if (provider === undefined) {
      throw new Error(`Generated provider ${providerId} is missing.`);
    }

    return [
      buildProviderJavaScript(providerId, provider),
      buildProviderDeclaration(providerId, provider),
    ];
  }),
);

await Promise.all([
  writeFile(
    new URL("../dist/full.js", import.meta.url),
    fullModule(providerIds, providerVariables),
  ),
  writeFile(
    new URL("../dist/full.d.ts", import.meta.url),
    `import type { FullCatalog } from "./types.js";
export declare const catalog: FullCatalog;
export default catalog;
`,
  ),
  writeFile(
    new URL("../dist/snapshot.js", import.meta.url),
    snapshotModule(providerIds, providerVariables),
  ),
  writeFile(
    new URL("../dist/snapshot.d.ts", import.meta.url),
    `import type { Snapshot } from "./types.js";
export declare const snapshot: Snapshot;
export default snapshot;
`,
  ),
]);

console.log(
  `Built ${providerIds.length} provider entrypoints in ` +
    `${distributionDirectory}.`,
);

async function buildProviderJavaScript(providerId, provider) {
  const source = JSON.stringify(
    compactValue(provider, keyIndexes, stringIndexes),
  );
  const output = `import { expandCompactValue } from "../compact.js";
import { compactKeys } from "../generated/compact-keys.js";
import { compactStrings } from "../generated/compact-strings.js";
import { createProviderCatalog } from "../provider.js";

export const data = expandCompactValue(compactKeys, compactStrings, ${source});
const provider = /* @__PURE__ */ createProviderCatalog(data);
export default provider;
`;

  await writeFile(
    new URL(`../dist/providers/${providerId}.js`, import.meta.url),
    output,
  );
}

async function buildProviderDeclaration(providerId, provider) {
  const modelNames = new Set(Object.keys(provider.models));

  for (const model of Object.values(provider.models)) {
    for (const alias of model.aliases ?? []) {
      modelNames.add(alias);
    }
  }

  const modelUnion =
    [...modelNames].sort().map(JSON.stringify).join(" | ") || "never";

  const output = `import type {
  Provider,
  ProviderCatalog,
} from "../types.js";

export declare const data: Provider;
declare const provider: ProviderCatalog<
  ${JSON.stringify(providerId)},
  ${modelUnion}
>;
export default provider;
`;

  await writeFile(
    new URL(`../dist/providers/${providerId}.d.ts`, import.meta.url),
    output,
  );
}

function fullModule(providerIds, variables) {
  const imports = providerIds
    .map(
      (providerId, index) =>
        `import ${variables[index]} from "./providers/${providerId}.js";`,
    )
    .join("\n");

  return `import { createCatalog } from "./catalog.js";
import { manifest } from "./generated/manifest.js";
${imports}

export const catalog = /* @__PURE__ */ createCatalog(
  [${variables.join(", ")}],
  manifest,
);
export default catalog;
`;
}

function snapshotModule(providerIds, variables) {
  const imports = providerIds
    .map(
      (providerId, index) =>
        `import { data as ${variables[index]} } ` +
        `from "./providers/${providerId}.js";`,
    )
    .join("\n");

  const providers = providerIds
    .map(
      (providerId, index) =>
        `    ${JSON.stringify(providerId)}: ${variables[index]},`,
    )
    .join("\n");

  return `import { manifest } from "./generated/manifest.js";
${imports}

export const snapshot = {
  schema_version: manifest.snapshot_schema_version,
  version: manifest.catalog_version,
  generated_at: manifest.generated_at,
  snapshot_id: manifest.snapshot_id,
  providers: {
${providers}
  },
};
export default snapshot;
`;
}
