const tmp = require("tmp");

function scratch() {
  return tmp.tmpNameSync();
}

function managed() {
  return tmp.fileSync().name;
}

module.exports = { scratch, managed };
