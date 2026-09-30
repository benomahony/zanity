it("reaches out", async () => {
  process.env.MODE = "test";
  process.chdir("/tmp");
  fs.readFileSync("config.json");
  fs.mkdtempSync("x");
  await fetch("https://example.com");
  mongoose.connect("mongodb://localhost");
  child_process.spawn("ls");
});

function helper() {
  process.env.MODE = "prod";
  child_process.spawn("ls");
}
