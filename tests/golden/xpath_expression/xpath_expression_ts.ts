function select(node: Node, expression: string) {
  return xpath.select(expression, node);
}

function selectFixed(node: Node, expression: string) {
  return xpath.select("/users/user", node);
}
