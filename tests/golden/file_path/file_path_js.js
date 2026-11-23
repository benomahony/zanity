import * as fs from "node:fs";
function read(path) {
    return fs.readFileSync(path);
}
function readFixed(path) {
    return fs.readFileSync("data/config.json");
}
