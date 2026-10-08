function read(text) {
  return Number.parseInt(text);
}

function readDecimal(text) {
  return Number.parseInt(text, 10);
}

function unrelated(parser, text) {
  return parser.parseInt(text);
}
