# Raw data quality: Task 2

**Status: database counts unverified.** The Task 2 SQL has not been executed in
this session. During Task 3, the project's `venv` was found to contain `psycopg`;
a connection to localhost:5432 / `sysnova_assessment` as `postgres` reached the
server but required a password. No connection credentials are configured in the
agent's environment, and `psql` is not on PATH. No SQL query results are claimed
below. Earlier CSV observations are not substitutes for database counts.
The Task 3 implementation and approved assumptions are documented below;
database execution is pending authentication.

Run `sql/inspect_data.sql` against the loaded Task 1 database to obtain measured
counts. It reads all seven raw tables in one read-only transaction.

| Check / potential issue | Measured affected rows | Intended fix or reject reason |
|---|---|---|
| Duplicate customer IDs, including conflicting versions | Unverified | Keep latest `updated_at`; decide handling of conflicting ties before cleaning. |
| Duplicate order IDs | Unverified | Deduplicate by `order_id`; decide a deterministic rule if versions conflict. |
| Duplicate payment IDs | Unverified | Deduplicate by `payment_id`; resolve conflicting versions before cleaning. |
| Duplicate product, line or invoice IDs | Unverified | Investigate before enforcing primary keys; no arbitrary winner. |
| Duplicate customer-change `(customer_id, effective_date)` pairs | Unverified | Investigate tied changes; choose latest effective change per customer. Customer ID alone is not unique in this history. |
| Missing values in every column of every raw table | Unverified | Apply specific rules below; inspect other missing fields before deciding required fields and rejects. |
| Missing order status | Unverified | Reject: `missing_order_status`. |
| Invalid nonblank order status after normalization | Unverified | Investigate; propose rejection as `invalid_order_status`, subject to human decision. |
| Order status case / spacing differences | Unverified | Trim and lowercase; retain only the five specified valid values. |
| ISO, DD/MM/YYYY, missing and other order-date formats | Unverified | Parse non-ISO dates as DD/MM/YYYY. Investigate missing/other formats before deciding rejection. |
| Orders referencing absent customers | Unverified | Reject: `unknown_customer`; also reject dependent order lines. |
| Customer changes referencing absent customers | Unverified | Investigate; propose `unknown_customer` reject rather than silent loss. |
| Lines referencing absent orders or products | Unverified | Investigate; propose `unknown_order` / `unknown_product` rejects. |
| Invoices referencing absent orders | Unverified | Decide invoice rejection policy before cleaning. |
| Payments referencing absent invoices | Unverified | Decide payment rejection policy before cleaning. |
| Quantity <= 0 | Unverified | Reject: `nonpositive_quantity`. |
| Missing or nonnumeric quantity | Unverified | Investigate; propose `invalid_quantity` reject. |
| Missing line unit price | Unverified | Fill from the matching product's `list_price`. |
| Missing/nonnumeric product list price, malformed/negative line prices, malformed/out-of-range discounts | Unverified | Investigate; do not invent monetary values or reject policies. |
| Customer and customer-change region case / spacing | Unverified | Trim and Title Case; apply region and segment from latest effective change, otherwise latest master record. |

## Read the output

- `row_count` gives the loaded row count for each table.
- `duplicate_key_excess` counts rows beyond one per key;
  `rows_in_duplicate_key_groups` counts all rows in repeated-key groups;
  `rows_in_conflicting_key_groups` counts all rows in groups whose full records differ.
  These are different measurements, not additional reject totals.
- `missing_value` counts SQL NULL, empty string, and space-only values per column.
- `missing_reference` uses exact raw key equality and `NOT EXISTS`, so parent
  duplicates do not inflate the count. It checks raw references only: descendants
  of orders later rejected for other reasons need a separate Task 3 audit.
- `order_date_format` classifies text shape; it does **not** validate calendar
  dates (for example, a matching string can still contain an impossible day).
- Numeric checks guard casts with a decimal-text pattern; missing fields are
  counted separately. `region_value` shows quoted original spellings and counts.
- Counts include source duplicates and can overlap across checks. Do not add
  them together to derive total rejected records. An absent format/value group
  means there were no rows in that group; confirm table totals first.

## Run locally (PowerShell)

After completing Task 1, open PowerShell at the repository root. Ensure the
PostgreSQL `bin` directory is on PATH, then run:

```powershell
Set-Location .\Sysnova_Data_Programmer_Assessment
$env:PGHOST = 'localhost'
$env:PGPORT = '5432'
$env:PGUSER = 'postgres' # Replace with your local role.
$env:PGDATABASE = 'sysnova_assessment'
$password = Read-Host 'PostgreSQL password' -AsSecureString
$env:PGPASSWORD = [System.Net.NetworkCredential]::new('', $password).Password

psql -X -v ON_ERROR_STOP=1 -P pager=off -f .\sql\inspect_data.sql

Remove-Item Env:PGPASSWORD
Remove-Variable password
```

If the raw tables have not been loaded, first follow `docs/task1.md`. A populated
database is required: empty tables cannot establish the dataset's issue counts.
Use the query output to replace the unverified entries with actual counts,
retaining separate per-table/per-column counts where a row above groups checks.

## Task 3: approved assumptions and implementation

The candidate approved these rules before implementation. They supplement the
eleven business rules in `TASK.md`; the assessment rules take precedence.

- Keep the latest customer `updated_at` and latest change `effective_date`.
  Break ties by ascending full source JSON text using PostgreSQL's `C` collation.
  Use the same comparison for duplicate orders and payments. Identical copies
  are interchangeable. A stable occurrence number distinguishes each copy.
- Rank before validation. An invalid winning row is rejected; do not silently
  substitute an older version. Discarded customers/orders/payments receive
  `duplicate_customer_id`, `duplicate_order_id`, or `duplicate_payment_id` reasons.
- Reject invoices without a retained order (`missing_or_rejected_order`), and
  payments without a retained invoice (`missing_or_rejected_invoice`). Lines
  without a retained order/product receive the corresponding reason.
- Retain a latest customer change through `clean_customers.change_source_row`.
  Older changes receive `superseded_customer_change`; an unapplied latest change
  receives `missing_or_rejected_customer`. Superseded history is not corrupt,
  but is audited here so every input occurrence has an outcome.
- Each rejected source occurrence has exactly one primary reason. Checks run
  in the order written in SQL: duplicates first, then required keys/parents and
  value validation. Overlapping problems do not create multiple reject rows.
- Source numbering is per raw table, ordered by original JSON text with `C`
  collation. Clean tables retain `source_row`; rejects retain that number plus
  the complete original record. Numbers are stable for unchanged inputs, not
  permanent identifiers across edits or replacement of raw data.
- Unexpected duplicate product, line or invoice IDs abort the transaction;
  no winner policy for those keys was approved. Multiple invoices for one order
  likewise fail the one-invoice-per-order constraint. Existing clean data is
  restored by rollback, and the unexpected input must be investigated.

`sql/02_clean.sql` creates typed tables, primary/foreign keys, required fields
and numeric/status checks, then replaces only the clean tables and reject log
in one transaction. It locks raw tables against concurrent writes while reading
them; it does not update, truncate or otherwise change them. Invalid calendar
dates and nonnumeric/missing required numbers become explicit rejects. No dates,
discounts or monetary values are inferred. Negative prices/amounts/credit limits
and discounts outside 0..100 are rejected as invalid values.

Missing line prices alone fall back to product `list_price`; malformed nonblank
prices do not. `numeric` columns have no fixed scale, preserving billed invoice
amounts exactly and avoiding rounding the net line formula. Customer region is
trimmed/Title Case; status is trimmed/lowercase. Current region and segment both
come from the latest change if present, otherwise the latest customer record.

All valid order statuses and all valid payment dates remain in clean data.
Delivered-only revenue and the receivables cutoff of **2025-12-31** belong to
Task 4 queries; cleaning neither filters future payments nor calculates reports.

### Execute and verify Task 3 locally

Prerequisites: Task 1 raw tables are already loaded; configure the same `PG*`
environment variables and password shown above. Open PowerShell at the repository
root. Set `$psql` to your installed executable (the version below is an example):

```powershell
Set-Location .\Sysnova_Data_Programmer_Assessment
$psql = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'

& $psql -X -v ON_ERROR_STOP=1 -f .\sql\02_clean.sql
if ($LASTEXITCODE -ne 0) { throw 'Cleaning failed; transaction rolled back.' }
& $psql -X -v ON_ERROR_STOP=1 -P pager=off -f .\sql\verify_clean.sql
if ($LASTEXITCODE -ne 0) { throw 'Verification SQL failed.' }

# Capture all counts, checks, and full-content fingerprints, then rerun cleaning.
$before = & $psql -X -q -A -t -v ON_ERROR_STOP=1 -f .\sql\verify_clean.sql
if ($LASTEXITCODE -ne 0) { throw 'First verification failed.' }
& $psql -X -v ON_ERROR_STOP=1 -f .\sql\02_clean.sql
if ($LASTEXITCODE -ne 0) { throw 'Second cleaning failed.' }
$after = & $psql -X -q -A -t -v ON_ERROR_STOP=1 -f .\sql\verify_clean.sql
if ($LASTEXITCODE -ne 0) { throw 'Second verification failed.' }
if (Compare-Object $before $after) { throw 'Rerun output changed.' }
'Rerun counts, checks and fingerprints match.'
```

In `verify_clean.sql`, all duplicate, orphan, accounting, reject-payload and
business-rule violation counts must be **0**. Review these values even if the
SQL command exits successfully: verification prints violations for inspection.
Every table must satisfy `raw_rows = retained_rows + rejected_rows`; for
`raw_customer_changes`, retained means a change applied to a clean customer.
The final fingerprints include all clean/reject contents and all raw contents.
Matching counts alone are insufficient to establish rerun stability.

Actual clean/reject row counts and rerun results remain **unverified until these
commands are executed against PostgreSQL**. No Task 4 files have been added.
