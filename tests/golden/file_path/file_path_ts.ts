import * as fs from "node:fs";

function read(path: string) {
  return fs.readFileSync(path);
}

function readFixed(path: string) {
  return fs.readFileSync("data/config.json");
}
