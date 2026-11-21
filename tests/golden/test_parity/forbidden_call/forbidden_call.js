function run(code) {
  return eval(code);
}

function parse(code) {
  return JSON.parse(code);
}

module.exports = { run, parse };
