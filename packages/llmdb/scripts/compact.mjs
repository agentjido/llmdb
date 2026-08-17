export function compactKeys(values, minimumOccurrences = 2) {
  const counts = new Map();

  for (const value of values) {
    countObjectKeys(value, counts);
  }

  return [...counts]
    .filter(([, count]) => count >= minimumOccurrences)
    .sort(([leftKey, leftCount], [rightKey, rightCount]) =>
      rightCount - leftCount || leftKey.localeCompare(rightKey),
    )
    .map(([key]) => key);
}

export function compactStrings(values, maximumEntries = 256) {
  const counts = new Map();

  for (const value of values) {
    countStrings(value, counts);
  }

  return [...counts]
    .map(([value, count]) => {
      const sourceSize = JSON.stringify(value).length;
      const conservativeTokenSize = 7;
      const estimatedSavings =
        count * (sourceSize - conservativeTokenSize) - sourceSize - 1;

      return { estimatedSavings, value };
    })
    .filter(({ estimatedSavings }) => estimatedSavings > 0)
    .sort(
      (left, right) =>
        right.estimatedSavings - left.estimatedSavings ||
        left.value.localeCompare(right.value),
    )
    .slice(0, maximumEntries)
    .map(({ value }) => value);
}

export function compactValue(value, keyIndexes, stringIndexes) {
  if (Array.isArray(value)) {
    return [
      1,
      ...value.map((item) => compactValue(item, keyIndexes, stringIndexes)),
    ];
  }

  if (value !== null && typeof value === "object") {
    const result = [0];

    for (const [key, childValue] of Object.entries(value)) {
      result.push(
        keyIndexes.get(key) ?? key,
        compactValue(childValue, keyIndexes, stringIndexes),
      );
    }

    return result;
  }

  if (typeof value === "string" && stringIndexes.has(value)) {
    return [2, stringIndexes.get(value)];
  }

  return value;
}

function countObjectKeys(value, counts) {
  if (Array.isArray(value)) {
    for (const item of value) {
      countObjectKeys(item, counts);
    }

    return;
  }

  if (value === null || typeof value !== "object") {
    return;
  }

  for (const [key, childValue] of Object.entries(value)) {
    counts.set(key, (counts.get(key) ?? 0) + 1);
    countObjectKeys(childValue, counts);
  }
}

function countStrings(value, counts) {
  if (Array.isArray(value)) {
    for (const item of value) {
      countStrings(item, counts);
    }

    return;
  }

  if (value !== null && typeof value === "object") {
    for (const childValue of Object.values(value)) {
      countStrings(childValue, counts);
    }

    return;
  }

  if (typeof value === "string") {
    counts.set(value, (counts.get(value) ?? 0) + 1);
  }
}
