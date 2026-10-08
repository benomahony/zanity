import * as util from "node:util";

function unsafe(template: string, value: unknown) {
  return util.format(template, value);
}

function safe(template: string, value: unknown) {
  return util.format("%s: %o", template, value);
}
