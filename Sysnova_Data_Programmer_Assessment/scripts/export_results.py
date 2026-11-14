"""Run and validate Task 4 reports in one database snapshot, then export files."""

import csv
import json
import os
from collections import defaultdict
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path
from tempfile import TemporaryDirectory

import psycopg


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SUMMARY_SQL = """
WITH balances AS (
    SELECT i.amount - COALESCE((
        SELECT sum(p.amount) FROM public.clean_payments p
        WHERE p.invoice_id = i.invoice_id AND p.payment_date <= DATE '2025-12-31'
    ),0) AS outstanding
    FROM public.clean_invoices i WHERE i.invoice_date <= DATE '2025-12-31'
)
SELECT
    (SELECT count(*) FROM public.clean_customers) AS clean_customers,
    (SELECT count(*) FROM public.clean_orders) AS clean_orders,
    (SELECT count(*) FROM public.rejected_records WHERE source_table = 'raw_orders') AS rejected_orders,
    (SELECT count(*) FROM public.clean_order_lines) AS clean_order_lines,
    (SELECT COALESCE(sum(l.quantity * l.unit_price * (1 - l.discount_pct / 100)),0)
     FROM public.clean_order_lines l JOIN public.clean_orders o USING (order_id)
     WHERE o.status = 'delivered') AS total_recognized_revenue,
    (SELECT count(*) FROM public.clean_payments) AS payments_after_dedupe,
    (SELECT COALESCE(sum(outstanding),0) FROM balances WHERE outstanding > 0) AS ar_total_outstanding
"""


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(reports, summary, customer_totals, open_invoice_count):
    q1, q2, q3 = (reports[name][1] for name in ("q1", "q2", "q3"))
    require(sum((r[1] for r in q1), Decimal(0)) == summary["total_recognized_revenue"],
            "q1 revenue does not reconcile with the independent line-formula total")
    previous = None
    previous_month = None
    for month, revenue, growth in q1:
        if previous_month is not None:
            require(month.year * 12 + month.month == previous_month.year * 12 + previous_month.month + 1,
                    "q1 months are not consecutive")
        expected = None if previous in (None, 0) else (
            100 * (revenue - previous) / previous
        ).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
        require(growth == expected, "q1 month-over-month growth is incorrect")
        previous, previous_month = revenue, month

    # Independently rank all 2025 customer totals in Python, not the q2 result.
    regions = defaultdict(list)
    for region, customer_id, name, revenue in customer_totals:
        regions[region].append((customer_id, name, revenue))
    expected_top = []
    for region in sorted(regions):
        for rank, (customer_id, name, revenue) in enumerate(
            sorted(regions[region], key=lambda row: (-row[2], row[0]))[:3], 1
        ):
            expected_top.append((region, rank, customer_id, name, revenue))
    require(q2 == expected_top, "q2 differs from independently ranked regional customer totals")
    require([r[0] for r in q3] == ["not-yet-due", "1-30", "31-60", "61-90", "90+"],
            "q3 aging buckets are missing or out of order")
    require(sum(r[1] for r in q3) == open_invoice_count, "q3 open-invoice count does not reconcile")
    require(sum((r[2] for r in q3), Decimal(0)) == summary["ar_total_outstanding"],
            "q3 outstanding does not reconcile with independent as-of balances")


def write_exports(reports, summary):
    # Emit exact Decimal values as JSON numbers, without binary float conversion.
    for value in summary.values():
        require(isinstance(value, (int, Decimal)) and value >= 0,
                "Summary contains an invalid numeric value")
    summary_text = "{\n" + ",\n".join(
        f"  {json.dumps(key)}: {value}" for key, value in summary.items()
    ) + "\n}\n"
    require(json.loads(summary_text, parse_float=Decimal) == summary, "JSON numeric roundtrip failed")
    output = PROJECT_ROOT / "results"
    output.mkdir(exist_ok=True)
    # Validate all staged files before replacing any previous successful export.
    with TemporaryDirectory(prefix=".export-", dir=output) as temporary:
        staging = Path(temporary)
        for name, (header, rows) in reports.items():
            path = staging / f"{name}.csv"
            with path.open("w", encoding="utf-8", newline="") as stream:
                writer = csv.writer(stream)
                writer.writerow(header)
                writer.writerows(rows)
            with path.open(encoding="utf-8", newline="") as stream:
                saved = list(csv.reader(stream))
            expected = [header] + [["" if v is None else str(v) for v in row] for row in rows]
            require(saved == expected, f"{name}.csv failed header/content verification")
        (staging / "summary.json").write_text(summary_text, encoding="utf-8")
        for name in ("q1.csv", "q2.csv", "q3.csv", "summary.json"):
            os.replace(staging / name, output / name)


def read_reports():
    reports = {}
    # libpq reads PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD / PGPASSFILE.
    with psycopg.connect(connect_timeout=5) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
            for name in ("q1", "q2", "q3"):
                cursor.execute((PROJECT_ROOT / "sql" / f"{name}.sql").read_text(encoding="utf-8"))
                reports[name] = ([c.name for c in cursor.description], cursor.fetchall())
            cursor.execute(SUMMARY_SQL)
            summary = dict(zip((c.name for c in cursor.description), cursor.fetchone()))
            cursor.execute("""
                SELECT c.region, c.customer_id, c.customer_name,
                       sum(l.quantity * l.unit_price * (1 - l.discount_pct / 100))
                FROM public.clean_customers c JOIN public.clean_orders o USING (customer_id)
                JOIN public.clean_order_lines l USING (order_id)
                WHERE o.status = 'delivered'
                  AND o.order_date >= DATE '2025-01-01' AND o.order_date < DATE '2026-01-01'
                GROUP BY c.region,c.customer_id,c.customer_name
            """)
            customer_totals = cursor.fetchall()
            cursor.execute("""
                SELECT count(*) FROM public.clean_invoices i
                WHERE i.invoice_date <= DATE '2025-12-31'
                  AND i.amount > COALESCE((SELECT sum(p.amount) FROM public.clean_payments p
                      WHERE p.invoice_id = i.invoice_id AND p.payment_date <= DATE '2025-12-31'),0)
            """)
            validate(reports, summary, customer_totals, cursor.fetchone()[0])
    return reports, summary


def main():
    reports, summary = read_reports()
    write_exports(reports, summary)
    for name, (_, rows) in reports.items():
        print(f"results/{name}.csv: {len(rows)} rows; headers and values verified")
    print("results/summary.json: seven database-derived metrics; revenue and AR totals reconciled")


if __name__ == "__main__":
    main()
