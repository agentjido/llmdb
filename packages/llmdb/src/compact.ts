const objectMarker = 0;
const arrayMarker = 1;
const stringMarker = 2;
const structureMarker = 3;

export function expandCompactValue(
  keys: readonly string[],
  strings: readonly string[],
  value: unknown,
  structures: readonly unknown[] = [],
): unknown {
  if (!Array.isArray(value)) {
    return value;
  }

  if (value[0] === arrayMarker) {
    return value
      .slice(1)
      .map((item) => expandCompactValue(keys, strings, item, structures));
  }

  if (value[0] === structureMarker && value.length === 2) {
    const index = value[1];

    if (
      typeof index !== "number" ||
      !Number.isInteger(index) ||
      index < 0 ||
      index >= structures.length
    ) {
      throw new TypeError("Invalid compact LLMDB structure.");
    }

    const structure = structures[index];

    if (
      !Array.isArray(structure) ||
      (structure[0] !== objectMarker && structure[0] !== arrayMarker)
    ) {
      throw new TypeError("Invalid compact LLMDB structure.");
    }

    // Dictionary entries cannot refer to other structures.
    return expandCompactValue(keys, strings, structure);
  }

  if (value[0] === stringMarker && value.length === 2) {
    const compactString = value[1];
    const result =
      typeof compactString === "number" ? strings[compactString] : undefined;

    if (result === undefined) {
      throw new TypeError("Invalid compact LLMDB string.");
    }

    return result;
  }

  if (value[0] !== objectMarker || value.length % 2 !== 1) {
    throw new TypeError("Invalid compact LLMDB value.");
  }

  const result: Record<string, unknown> = {};

  for (let index = 1; index < value.length; index += 2) {
    const compactKey = value[index];
    const key =
      typeof compactKey === "number" ? keys[compactKey] : compactKey;

    if (typeof key !== "string") {
      throw new TypeError("Invalid compact LLMDB object key.");
    }

    Object.defineProperty(result, key, {
      configurable: true,
      enumerable: true,
      value: expandCompactValue(keys, strings, value[index + 1], structures),
      writable: true,
    });
  }

  return result;
}
