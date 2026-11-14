# Task 4: reports and exports

Run only after Task 3 has successfully populated and verified the clean tables.
The script uses the existing `psycopg` dependency and PostgreSQL environment
variables. It reads SQL and writes results relative to the project folder, so
the current terminal directory does not affect paths. It changes no database
tables, raw files, or cleaning rules.

## Run from the repository root (PowerShell)

The existing project virtual environment is named `venv`. If you used `.venv`
instead, replace `venv` in the commands below. If necessary, install the existing
dependency using `venv\Scripts\python.exe -m pip install -r requirements.txt`
from the assessment folder first.

```powershell
$env:PGHOST = 'localhost'
$env:PGPORT = '5432'
$env:PGUSER = 'postgres' # Replace with your PostgreSQL role.
$env:PGDATABASE = 'sysnova_assessment'
$password = Read-Host 'PostgreSQL password' -AsSecureString
$env:PGPASSWORD = [System.Net.NetworkCredential]::new('', $password).Password

& .\Sysnova_Data_Programmer_Assessment\venv\Scripts\python.exe `
    .\Sysnova_Data_Programmer_Assessment\scripts\export_results.py
if ($LASTEXITCODE -ne 0) { throw 'Export failed; inspect the error before continuing.' }

Remove-Item Env:PGPASSWORD
Remove-Variable password
```

`psql` is not needed for exports. The loader/exporter do not load `.env` files.
Credentials must be available to the Python process, or configured through a
PostgreSQL password file (`PGPASSFILE`). Do not commit passwords.

On success, these four files are written under the assessment's `results/`:

- `q1.csv`: month, recognized_revenue, mom_growth_pct.
- `q2.csv`: region, customer_rank, customer_id, customer_name, recognized_revenue.
- `q3.csv`: aging_bucket, invoice_count, outstanding_amount.
- `summary.json`: the seven exact keys required by `TASK.md`.

## Report conventions

- **q1:** delivered-order net line revenue by order-date month, across all years.
  Include every month from the first to last clean order month, using zero when
  no delivered revenue exists. Growth is NULL (empty CSV field) for the first
  month or a zero previous month; otherwise round growth to two decimals.
  Revenue itself is not rounded.
- **q2:** delivered-order net revenue in the half-open date range
  `[2025-01-01, 2026-01-01)`, using current `clean_customers.region`. Select up to
  three customers per region among those with delivered lines. Break equal
  revenue by ascending customer ID with `C` collation; use the same collation
  for region output ordering.
- **q3:** only invoices issued by 2025-12-31 exist in the as-of balance. Subtract
  only clean payments received by that date, after aggregating payments per
  invoice to avoid duplicating billed amounts. Keep only positive outstanding.
  Due today/future goes in `not-yet-due`; other buckets are days 1–30, 31–60,
  61–90, and greater than 90 (labelled `90+` to follow the brief). This makes the
  overlapping wording at day 90 unambiguous. Output all five buckets, including
  zero-count buckets. Do not recalculate `invoice.amount` from order lines.
- **summary:** `rejected_orders` counts every audited rejected raw-order
  occurrence, including discarded duplicates, consistently with Task 3's
  raw = retained + rejected reconciliation. `payments_after_dedupe` counts
  retained `clean_payments` after deduplication and dependent-record rejection.
  Revenue covers all years as in q1; outstanding equals q3's positive balances.

## Validation and current status

All queries, metrics, and cross-checks read one repeatable-read, read-only
database snapshot. Before writing exports the script checks:

- q1 revenue against an independent delivered-line formula total, and every
  month's growth and calendar sequence.
- q2 against all database-derived 2025 customer totals, independently ranked
  in Python by current region, revenue and customer ID.
- q3 outstanding and open-invoice count against independent billed-invoice
  balance queries with the same as-of cutoff.
- Every CSV's saved headers and values, and the JSON numeric round trip.

JSON monetary values remain JSON numbers and are serialized from exact Decimal
values, without conversion through binary floating-point. All files are staged
and checked before replacing previous exports; database/validation failures
produce no new final result files.

**Database run pending:** the server on localhost:5432 responds but requires a
password, and the agent has no configured authentication. SQL execution, actual
report totals, and the four final output files have not been verified/generated
in this session. No placeholder results or hand-entered summary values are used.
Python syntax and synthetic validation/serialization checks can be run without
claiming they verify the actual PostgreSQL reports.
