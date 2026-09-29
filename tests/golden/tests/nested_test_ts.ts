it("deep", () => {
  let n = 0;
  for (const a of [1, 2, 3]) {
    if (a > 0) {
      for (const b of [1, 2, 3]) {
        if (b > 0) {
          if (a > b) n += 1;
        }
      }
    }
  }
});

it("flat", () => {
  let n = 0;
  for (const a of [1, 2, 3]) {
    if (a > 0) n += 1;
  }
});
