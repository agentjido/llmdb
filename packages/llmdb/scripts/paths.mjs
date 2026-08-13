import { fileURLToPath } from "node:url";

export const packageDirectory = fileURLToPath(new URL("../", import.meta.url));
export const repositoryDirectory = fileURLToPath(
  new URL("../../../", import.meta.url),
);
export const canonicalSnapshotPath = fileURLToPath(
  new URL("../../../priv/llm_db/snapshot.json", import.meta.url),
);
export const rootLicensePath = fileURLToPath(
  new URL("../../../LICENSE", import.meta.url),
);
export const mixProjectPath = fileURLToPath(
  new URL("../../../mix.exs", import.meta.url),
);
export const packageJsonPath = fileURLToPath(
  new URL("../package.json", import.meta.url),
);
export const rootPackageLockPath = fileURLToPath(
  new URL("../../../package-lock.json", import.meta.url),
);
export const generatedLicensePath = fileURLToPath(
  new URL("../LICENSE", import.meta.url),
);
export const generatedDataDirectory = fileURLToPath(
  new URL("../generated", import.meta.url),
);
export const generatedManifestPath = fileURLToPath(
  new URL("../generated/manifest.json", import.meta.url),
);
export const generatedProvidersDirectory = fileURLToPath(
  new URL("../generated/providers", import.meta.url),
);
export const generatedSourceDirectory = fileURLToPath(
  new URL("../src/generated", import.meta.url),
);
export const providerDeclarationsDirectory = fileURLToPath(
  new URL("../src/providers", import.meta.url),
);
export const distributionDirectory = fileURLToPath(
  new URL("../dist", import.meta.url),
);
export const distributionProvidersDirectory = fileURLToPath(
  new URL("../dist/providers", import.meta.url),
);
