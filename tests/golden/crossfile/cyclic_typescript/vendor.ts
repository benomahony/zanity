import lodash from "lodash";

export function pad(text: string): string {
  return lodash.padStart(text, 4);
}
