vi.mock("./mountUtils.js");
vi.mock("@/services/repo-env", () => ({ repoEnv: {} }));
vi.mock("node:child_process");
vi.mock("stripe");
jest.mock("../db");
jest.mock("@aws-sdk/client-s3");

it("patches the windows mounts", () => {
  expect(mounts()).toEqual([]);
});
