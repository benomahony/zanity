function inspect(value) {
    return util.isArray(value);
}
function inspectSupported(value) {
    return Array.isArray(value);
}
function unrelated(otherUtil, value) {
    return otherUtil.isArray(value);
}
