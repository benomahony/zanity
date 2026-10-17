"""Keep committed parity and language coverage from silently moving backwards.

The expensive comparison benchmark writes results.json.  CI compares the durable parts of
that report with floors.json, while the golden integration suite exercises the current binary.
When coverage improves, run this file with --write so the improvement becomes the new floor.
"""

import argparse
import json
from pathlib import Path


HERE = Path(__file__).resolve().parent
RESULTS = HERE / "results.json"
FLOORS = HERE / "floors.json"


def snapshot(data: dict) -> dict:
    """Return only stable coverage facts, excluding dates, timings and corpus totals."""
    fixture_rows = [
        row
        for row in data["fixtures"]
        if row["old_fires"] and row["zanity_fires"]
    ]
    fixtures = {
        f"{row['tool']}:{row['rule']}": row["same_line"]
        for row in sorted(fixture_rows, key=lambda row: (row["tool"], row["rule"]))
    }
    questions = sorted(
        f"{row['rule']}:{row['zanity']}"
        for row in data["inference"]["questions"]
        if row["present"]
    )
    languages = {
        language: {
            rule: result["matched"]
            for rule, result in sorted(report["recall"].items())
        }
        for language, report in sorted(data["languages"].items())
    }
    assert len(fixtures) == len(fixture_rows), "fixture coverage keys must be unique"
    assert len(questions) == len(set(questions)), "inference question keys must be unique"
    return {"fixtures": fixtures, "inference_questions": questions, "language_recall": languages}


def regressions(current: dict, floors: dict) -> list[str]:
    assert set(current) == {"fixtures", "inference_questions", "language_recall"}, f"unexpected current coverage fields: {sorted(current)}"
    assert set(floors) == set(current), f"floor fields {sorted(floors)} do not match current fields {sorted(current)}"
    errors = []
    for field, label in (("fixtures", "covered fixture"), ("inference_questions", "inference question")):
        missing = sorted(set(floors[field]) - set(current[field]))
        errors.extend(f"missing {label}: {item}" for item in missing)
    for fixture, same_line in floors["fixtures"].items():
        if fixture in current["fixtures"] and same_line is True and current["fixtures"][fixture] is not True:
            errors.append(f"fixture no longer matches on the same line: {fixture}")

    current_languages = current["language_recall"]
    for language, rules in floors["language_recall"].items():
        if language not in current_languages:
            errors.append(f"missing language: {language}")
            continue
        for rule, floor in rules.items():
            matched = current_languages[language].get(rule)
            if matched is None:
                errors.append(f"missing language feature: {language}:{rule}")
            elif matched < floor:
                errors.append(f"language recall fell: {language}:{rule} matched {matched}, floor {floor}")
    return errors


def additions(current: dict, floors: dict) -> list[str]:
    assert set(current) == {"fixtures", "inference_questions", "language_recall"}, f"unexpected current coverage fields: {sorted(current)}"
    assert set(floors) == set(current), f"floor fields {sorted(floors)} do not match current fields {sorted(current)}"
    gains = []
    for field, label in (("fixtures", "covered fixture"), ("inference_questions", "inference question")):
        added = sorted(set(current[field]) - set(floors[field]))
        gains.extend(f"new {label}: {item}" for item in added)
    for fixture, same_line in current["fixtures"].items():
        if fixture in floors["fixtures"] and same_line is True and floors["fixtures"][fixture] is not True:
            gains.append(f"fixture now matches on the same line: {fixture}")

    floor_languages = floors["language_recall"]
    for language, rules in current["language_recall"].items():
        if language not in floor_languages:
            gains.append(f"new language: {language}")
            continue
        for rule, matched in rules.items():
            floor = floor_languages[language].get(rule)
            if floor is None:
                gains.append(f"new language feature: {language}:{rule} matched {matched}")
            elif matched > floor:
                gains.append(f"language recall rose: {language}:{rule} matched {matched}, floor {floor}")
    return gains


def main() -> None:
    assert RESULTS.is_file(), f"{RESULTS} is missing; run the parity benchmark first"
    assert HERE.is_dir(), f"parity directory {HERE} is missing"
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--write", action="store_true", help="raise floors to the coverage in results.json")
    args = parser.parse_args()
    current = snapshot(json.loads(RESULTS.read_text()))
    floors = json.loads(FLOORS.read_text()) if FLOORS.is_file() else None

    if floors:
        errors = regressions(current, floors)
        if errors:
            raise SystemExit("parity ratchet failed:\n  " + "\n  ".join(errors))
    if args.write:
        FLOORS.write_text(json.dumps(current, indent=2) + "\n")
        print(f"wrote {FLOORS.relative_to(HERE.parent.parent)}")
        return
    if floors is None:
        raise SystemExit(f"{FLOORS} is missing; run {Path(__file__).name} --write")
    gains = additions(current, floors)
    if gains:
        raise SystemExit(
            "parity improved; raise the committed floor with "
            f"`python3 {Path(__file__).relative_to(HERE.parent.parent)} --write`:\n  "
            + "\n  ".join(gains)
        )
    print(
        f"parity ratchet: {len(current['fixtures'])} fixtures, "
        f"{len(current['inference_questions'])} inference questions, "
        f"{sum(len(rules) for rules in current['language_recall'].values())} language features"
    )


if __name__ == "__main__":
    main()
