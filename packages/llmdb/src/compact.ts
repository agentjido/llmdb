const objectMarker = 0;
const arrayMarker = 1;
const stringMarker = 2;

export function expandCompactValue(
  keys: readonly string[],
  strings: readonly string[],
  value: unknown,
): unknown {
  if (!Array.isArray(value)) {
    return value;
  }

  if (value[0] === arrayMarker) {
    return value
      .slice(1)
      .map((item) => expandCompactValue(keys, strings, item));
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
      value: expandCompactValue(keys, strings, value[index + 1]),
      writable: true,
    });
  }

  return result;
}
