function compile(source) {
    return Handlebars.compile(source);
}
function compileFixed(source) {
    return Handlebars.compile("Hello {{name}}");
}
function compileSelected() {
    const source = "Hello {{name}}";
    return Handlebars.compile(source);
}
