"""Check clean SQL invariants and saved reports; never rewrite database or files."""

import csv
import json
from decimal import Decimal

import psycopg

from export_results import PROJECT_ROOT, read_reports, require


OUTPUT_FILES = ("q1.csv", "q2.csv", "q3.csv", "summary.json")
VIOLATION_COLUMNS = {
    "duplicate_ids", "duplicate_source_rows", "violations",
    "accounting_violations", "reject_payload_violations",
}


def check_presence():
    missing = [name for name in OUTPUT_FILES if not (PROJECT_ROOT / "results" / name).is_file()]
    require(not missing, "Missing required outputs: " + ", ".join(missing))


def check_database():
    fingerprints = {}
    checks = 0
    # verify_clean.sql owns its explicit read-only transaction.
    with psycopg.connect(connect_timeout=5, autocommit=True) as connection:
        with connection.cursor() as cursor:
            cursor.execute((PROJECT_ROOT / "sql" / "verify_clean.sql").read_text(encoding="utf-8"))
            while True:
                if cursor.description:
                    columns = [column.name for column in cursor.description]
                    for values in cursor.fetchall():
                        row = dict(zip(columns, values))
                        for column in VIOLATION_COLUMNS.intersection(columns):
                            require(row[column] == 0, f"Database check failed: {row}")
                            checks += 1
                        if "content_fingerprint" in row:
                            fingerprints[row["table_name"]] = row
                if not cursor.nextset():
                    break
    require(checks > 0, "No database invariant checks were returned")
    paths = sorted((PROJECT_ROOT / "data" / "raw").glob("*.csv"))
    require(len(paths) == 7, "Expected all seven supplied raw CSV files")
    for path in paths:
        with path.open(encoding="utf-8-sig", newline="") as stream:
            reader = csv.reader(stream)
            next(reader)
            count = sum(1 for _ in reader)
        name = "raw_" + path.stem
        require(name in fingerprints and fingerprints[name]["rows"] == count,
                f"Raw table count differs from source CSV: {path.name}")
    require(len(fingerprints) == 14, "Expected fingerprints for seven raw and seven output tables")
    return checks


def check_saved_reports(reports, summary):
    for name, (header, rows) in reports.items():
        with (PROJECT_ROOT / "results" / f"{name}.csv").open(encoding="utf-8", newline="") as stream:
            saved = list(csv.reader(stream))
        expected = [header] + [["" if value is None else str(value) for value in row] for row in rows]
        require(saved == expected, f"Saved {name}.csv differs from current database results")
    # Keep pairs until duplicate/extra keys have been checked.
    pairs = json.loads((PROJECT_ROOT / "results" / "summary.json").read_text(encoding="utf-8"),
                       parse_float=Decimal, object_pairs_hook=list)
    require(isinstance(pairs, list) and all(isinstance(pair, tuple) and len(pair) == 2 for pair in pairs),
            "summary.json must be a flat JSON object")
    require(len(pairs) == 7 and {key for key, _ in pairs} == set(summary),
            "summary.json must contain exactly the seven required keys, without duplicates")
    require(dict(pairs) == summary, "Saved summary.json differs from current database metrics")


def main():
    check_presence()
    checks = check_database()
    reports, summary = read_reports()
    check_saved_reports(reports, summary)
    print(f"PASS: {checks} SQL invariant checks; seven raw counts match source CSVs.")
    print("PASS: all four required output files match validated current database results.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, psycopg.Error) as error:
        raise SystemExit(f"FAIL: {error}") from None
