export function modelIds(provider) {
  const names = new Set(Object.keys(provider.models));
  for (const model of Object.values(provider.models)) {
    for (const alias of model.aliases ?? []) names.add(alias);
  }
  return [...names].sort();
}

export function modelTypes(providers) {
  const entries = Array.from(providers, ([provider, value]) => [provider, modelIds(value)]);
  const frequency = new Map();
  for (const [, ids] of entries) {
    for (const id of ids) frequency.set(id, (frequency.get(id) ?? 0) + 1);
  }

  const shared = new Map();
  for (const [id, count] of frequency) {
    const name = "M" + shared.size.toString(36);
    const literal = JSON.stringify(id);
    const definition = `type ${name} = ${literal};\n`;
    if (count * (literal.length - name.length) > definition.length) shared.set(id, name);
  }

  const lines = [];
  for (const [id, name] of shared) lines.push(`type ${name} = ${JSON.stringify(id)};`);
  lines.push("export interface CatalogModelIds {");
  for (const [provider, ids] of entries) {
    const literalUnion = exactUnion(ids.filter((id) => !shared.has(id)));
    const refs = ids.filter((id) => shared.has(id)).map((id) => shared.get(id));
    const union = [literalUnion, ...refs].filter(Boolean).join(" | ") || "never";
    lines.push(`  ${JSON.stringify(provider)}: ${union};`);
  }
  lines.push("}", "");
  return lines.join("\n");
}

function exactUnion(ids) {
  const direct = ids.map((id) => JSON.stringify(id)).join(" | ");
  if (ids.length < 2) return direct;

  let prefixLength = 0;
  const first = ids[0];
  const last = ids.at(-1);
  while (first[prefixLength] !== undefined && first[prefixLength] === last[prefixLength]) {
    prefixLength++;
  }
  if (prefixLength) {
    const prefix = JSON.stringify(first.slice(0, prefixLength))
      .slice(1, -1)
      .replaceAll("`", "\\`")
      .replaceAll("${", "\\${");
    const suffixes = ids.map((id) => id.slice(prefixLength));
    const factored = "`" + prefix + "${" + exactUnion(suffixes) + "}`";
    return factored.length < direct.length ? factored : direct;
  }

  const groups = new Map();
  for (const id of ids) {
    const firstCharacter = id[0];
    if (!groups.has(firstCharacter)) groups.set(firstCharacter, []);
    groups.get(firstCharacter).push(id);
  }
  const factored = [...groups.values()].map(exactUnion).join(" | ");
  return factored.length < direct.length ? factored : direct;
}
