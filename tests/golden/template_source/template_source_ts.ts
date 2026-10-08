function compile(source: string) {
  return Handlebars.compile(source);
}

function compileFixed(source: string) {
  return Handlebars.compile("Hello {{name}}");
}

function compileSelected() {
  const source = "Hello {{name}}";
  return Handlebars.compile(source);
}
