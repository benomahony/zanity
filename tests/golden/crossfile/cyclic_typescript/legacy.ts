import store = require("./store");

export function legacy(): number {
  return store.load();
}
