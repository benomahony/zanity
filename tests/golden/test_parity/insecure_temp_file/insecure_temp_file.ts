import tmp from "tmp";

export function scratch(): string {
  return tmp.tmpNameSync();
}

export function managed(): string {
  return tmp.fileSync().name;
}
