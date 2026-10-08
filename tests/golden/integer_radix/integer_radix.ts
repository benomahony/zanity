function read(text: string) {
  return parseInt(text);
}

function readDecimal(text: string) {
  return parseInt(text, 10);
}

function unrelated(parser: Parser, text: string) {
  return parser.parseInt(text);
}
