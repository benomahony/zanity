const child_process = require("child_process");
const crypto = require("crypto");
const yaml = require("js-yaml");

function run(command) {
  return child_process.exec(command);
}

function listing() {
  return child_process.exec("ls -l");
}

function read(text) {
  return yaml.load(text);
}

function readSafely(text) {
  return JSON.parse(text);
}

function seal(key, data) {
  return crypto.publicEncrypt({ key, padding: crypto.constants.RSA_PKCS1_PADDING }, data);
}

function sealSafely(key, data) {
  return crypto.publicEncrypt({ key, padding: crypto.constants.RSA_PKCS1_OAEP_PADDING }, data);
}

module.exports = { run, listing, read, readSafely, seal, sealSafely };
