import { run } from "./inline";

export interface Plan {
  steps: number;
}

export function schedule(plan: Plan): number {
  return plan.steps;
}

export function rerun(plan: Plan): number {
  return run(plan);
}
