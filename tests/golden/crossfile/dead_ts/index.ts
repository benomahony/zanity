export function api(): number {
  return helper();
}

function helper(): number {
  return 1;
}

function forgotten(): number {
  return 2;
}

class Internal {
  run(): void {}
}
