import { type Plan, schedule } from "./plan";

export function run(plan: Plan): number {
  return schedule(plan);
}
