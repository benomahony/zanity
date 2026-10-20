// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function parse(text: any): number {
  // @ts-ignore
  return text.value;
}

/* eslint-disable */
export function load(): string {
  // @ts-expect-error the type is wrong
  return 1;
}

// biome-ignore lint/style/useConst: legacy
export let count = 0;

/* istanbul ignore next */
export function honest(): number {
  // Explains why eslint rules are strict here.
  return count;
}
