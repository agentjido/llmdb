import { rm } from "node:fs/promises";

import {
  distributionDirectory,
  generatedDataDirectory,
  generatedLicensePath,
  generatedSourceDirectory,
  providerDeclarationsDirectory,
} from "./paths.mjs";

await Promise.all([
  rm(distributionDirectory, { force: true, recursive: true }),
  rm(generatedDataDirectory, { force: true, recursive: true }),
  rm(generatedLicensePath, { force: true }),
  rm(generatedSourceDirectory, { force: true, recursive: true }),
  rm(providerDeclarationsDirectory, { force: true, recursive: true }),
]);
