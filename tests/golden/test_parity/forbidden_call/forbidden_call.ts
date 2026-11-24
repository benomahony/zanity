export function run(code: string): unknown {
  return eval(code);
}

export function parse(code: string): unknown {
  return JSON.parse(code);
}
