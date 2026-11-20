export function count(lines: string[], word: string): number {
  let found = 0;
  for (const line of lines) {
    if (line.includes(word.toLowerCase())) {
      found += 1;
    }
  }
  return found;
}

export function each(lines: string[]): number {
  let found = 0;
  for (const line of lines) {
    found += line.trim().length;
  }
  return found;
}
