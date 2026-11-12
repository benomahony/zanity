const { bump } = require("./counter.cjs");

function get() {
  return bump.length;
}

module.exports = { get };
