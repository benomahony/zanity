import * as util from "node:util";
function unsafe(template, value) {
    return util.format(template, value);
}
function safe(template, value) {
    return util.format("%s: %o", template, value);
}
