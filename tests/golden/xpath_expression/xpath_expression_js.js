function select(node, expression) {
    return xpath.select(expression, node);
}
function selectFixed(node, expression) {
    return xpath.select("/users/user", node);
}
