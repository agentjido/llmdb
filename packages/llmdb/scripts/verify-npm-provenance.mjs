import { readFile } from "node:fs/promises";

const [auditPath, version, releaseSha] = process.argv.slice(2);

if (
  auditPath === undefined ||
  version === undefined ||
  releaseSha === undefined
) {
  throw new Error(
    "Usage: verify-npm-provenance.mjs AUDIT_JSON VERSION RELEASE_SHA",
  );
}

if (!/^\d{4}\.\d+\.\d+$/.test(version) || !/^[a-f0-9]{40}$/.test(releaseSha)) {
  throw new Error("The expected NPM release identity is invalid.");
}

const audit = JSON.parse(await readFile(auditPath, "utf8"));
const verifiedPackage = audit.verified?.find(
  (entry) =>
    entry.name === "@agentjido/llmdb" && entry.version === version,
);
const provenanceBundle = verifiedPackage?.attestationBundles?.find(
  (entry) => entry.predicateType === "https://slsa.dev/provenance/v1",
);
const encodedPayload = provenanceBundle?.bundle?.dsseEnvelope?.payload;

if (typeof encodedPayload !== "string") {
  throw new Error("NPM did not verify the expected provenance attestation.");
}

const statement = JSON.parse(
  Buffer.from(encodedPayload, "base64").toString("utf8"),
);
const build = statement.predicate?.buildDefinition;
const workflow = build?.externalParameters?.workflow;
const github = build?.internalParameters?.github;
const source = build?.resolvedDependencies?.find(
  (dependency) => dependency.digest?.gitCommit === releaseSha,
);

if (
  workflow?.repository !== "https://github.com/agentjido/llmdb" ||
  workflow?.path !== ".github/workflows/release.yml" ||
  workflow?.ref !== `refs/tags/${version}` ||
  github?.event_name !== "workflow_dispatch" ||
  source === undefined
) {
  throw new Error("NPM provenance does not identify the release tag and commit.");
}

console.log(
  `Verified NPM signature and provenance for ${version} at ${releaseSha}.`,
);
