const store = require("./store.cjs");

function bump() {
  return store.get() + 1;
}

module.exports = { bump };
