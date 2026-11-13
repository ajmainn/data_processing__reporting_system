"""Replace the seven raw tables atomically with the supplied CSV contents."""

import csv
from pathlib import Path

import psycopg
from psycopg import sql


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCES = (
    "customers", "customer_changes", "products", "orders",
    "order_lines", "invoices", "payments",
)


def main():
    counts = {}
    # libpq reads PGHOST, PGPORT, PGDATABASE, PGUSER and PGPASSWORD.
    # One transaction means a failed import restores all previous raw contents.
    with psycopg.connect(connect_timeout=5) as connection:
        with connection.cursor() as cursor:
            tables = [sql.Identifier("public", "raw_" + name) for name in SOURCES]
            cursor.execute(sql.SQL("TRUNCATE TABLE {}").format(sql.SQL(", ").join(tables)))
            for name, table in zip(SOURCES, tables):
                path = PROJECT_ROOT / "data" / "raw" / (name + ".csv")
                with path.open(encoding="utf-8-sig", newline="") as stream:
                    reader = csv.reader(stream, strict=True)
                    header = next(reader)
                    cursor.execute(sql.SQL("SELECT * FROM {} LIMIT 0").format(table))
                    if header != [column.name for column in cursor.description]:
                        raise ValueError(f"{path.name}: CSV header does not match raw table")
                    statement = sql.SQL("COPY {} ({}) FROM STDIN").format(
                        table, sql.SQL(", ").join(map(sql.Identifier, header))
                    )
                    count = 0
                    with cursor.copy(statement) as copy:
                        for row in reader:
                            if len(row) != len(header):
                                raise ValueError(f"{path.name}: invalid field count at CSV line {reader.line_num}")
                            # No stripping, casting, deduplication or blank-to-NULL conversion.
                            copy.write_row(row)
                            count += 1
                    cursor.execute(sql.SQL("SELECT COUNT(*) FROM {}").format(table))
                    if cursor.fetchone()[0] != count:
                        raise ValueError(f"{path.name}: imported row count does not match CSV")
                    counts["raw_" + name] = count
    for table, count in counts.items():
        print(f"{table}: {count}")
    print("Import committed successfully.")


if __name__ == "__main__":
    main()
