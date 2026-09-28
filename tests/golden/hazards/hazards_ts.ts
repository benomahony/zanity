async function save(x: number): Promise<void> {}

function flagged(db: any, name: string, apiKey: string, x: number, y: boolean): number {
  try { save(1); } finally { return 1; }
  if (!y == true) {}
  if (x & 2 == 2) {}
  switch (x) {
    case 1:
      save(2);
    case 2:
      break;
  }
  x;
  https.request({ rejectUnauthorized: false });
  db.query("SELECT * FROM t WHERE n = '" + name + "'");
  const d = Date.now() - x;
  console.log("key", apiKey);
  return d;
}

async function quiet(db: any, name: string, x: number, y: boolean): Promise<number> {
  if (!(y == true)) {}
  if ((x & 2) == 2) {}
  switch (x) {
    case 1:
      await save(2);
      // falls through
    case 2:
      break;
    default:
      break;
  }
  db.query("SELECT * FROM t WHERE n = ?", [name]);
  void save(3);
  if (x > 1) { } else if (x > 2) { } else if (x > 3) { } else if (x > 4) { } else if (x > 5) { }
  return performance.now() - x;
}
