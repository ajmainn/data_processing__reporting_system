# Raw data quality: Task 2

**Status: Verified against PostgreSQL 18 (`sysnova_assessment`) on 2026-11-14.**

Executed `sql/inspect_data.sql` against all seven populated raw tables. The SQL completed successfully (`COMMIT`). The counts below are measured directly from the database, not estimates.

| Check / issue | Measured affected rows | Handling / notes |
|---|---:|---|
| Duplicate customer IDs (excess rows) | 8 | Latest `updated_at` is retained; duplicates are rejected. 16 rows belong to conflicting duplicate groups. |
| Duplicate order IDs (excess rows) | 200 | Deduplicate using the approved deterministic selection rule. |
| Duplicate payment IDs (excess rows) | 95 | Deduplicate using the approved deterministic selection rule. |
| Duplicate product, line, or invoice IDs | 0 | No duplicate IDs detected for these tables. |
| Duplicate customer-change `(customer_id, effective_date)` pairs | 0 | No repeated pairs detected. |
| Missing values in raw tables | 60 missing order statuses; 147 missing line unit prices; 0 for all other inspected fields | Issues overlap across source records; these are column-level counts. |
| Missing order status | 60 | Reject as `missing_order_status`. |
| Invalid nonblank order status after normalization | 0 | No invalid nonblank statuses detected. |
| Order status case / spacing differences | 805 | Trim and lowercase. |
| Order date formats | 18,586 ISO; 1,614 DD/MM/YYYY; 0 missing | Parse DD/MM/YYYY dates accordingly. These are format counts, not error counts. |
| Orders referencing absent raw customers | 102 | Reject affected retained-order candidates as `unknown_customer`; verified cleaning rejected 100 for this reason. |
| Customer changes referencing absent customers | 0 | No missing raw reference detected. |
| Order lines referencing absent raw orders or products | 0 for each | Dependent lines of rejected orders are handled during cleaning. |
| Invoices referencing absent raw orders | 0 | Invoices whose orders were rejected during cleaning are separately rejected. |
| Payments referencing absent raw invoices | 0 | Payments whose invoices were rejected during cleaning are separately rejected. |
| Nonpositive order-line quantities | 246 | Cleaning rejected 244 as `nonpositive_quantity`; other issues can take precedence. |
| Missing or nonnumeric order-line quantity | 0 | No affected rows. |
| Missing line unit price | 147 | Fill from matching product `list_price`. |
| Invalid product prices, malformed/negative line prices, invalid discounts | 0 | No such rows reported by the inspected checks. |
| Region case / spacing needing normalization | 25 customer rows; 0 customer-change rows | Trim and Title Case. |

**Raw row counts:** customers 408; products 60; orders 20,200; order lines 49,213; invoices 16,941; payments 19,096; customer changes 73.

**Cleaning verification:** `sql/verify_clean.sql` reported 0 duplicate-ID violations, 0 foreign-key/orphan violations, 0 accounting/reject-payload violations, and 0 rule violations. Clean tables contain 400 customers, 60 products, 19,840 orders, 48,593 order lines, 16,805 invoices, and 18,849 payments. There are **1,384 rejected source records**; reject counts cannot be computed by adding the raw issue counts because checks can overlap and cleaning assigns one primary rejection reason per source occurrence.

## Read the output**

- `row_count` gives the loaded row count for each table.

- `duplicate_key_excess` counts rows beyond one per key;

  `rows_in_duplicate_key_groups` counts all rows in repeated-key groups;

  `rows_in_conflicting_key_groups` counts all rows in groups whose full records differ.

  These are different measurements, not additional reject totals.

- `missing_value` counts SQL NULL, empty string, and space-only values per column.

- `missing_reference` uses exact raw key equality and `NOT EXISTS`, so parent

  duplicates do not inflate the count. It checks raw references only: descendants

  of orders later rejected for other reasons need a separate Task 3 audit.

- `order_date_format` classifies text shape; it does ****not**** validate calendar

  dates (for example, a matching string can still contain an impossible day).

- Numeric checks guard casts with a decimal-text pattern; missing fields are

  counted separately. `region_value` shows quoted original spellings and counts.

- Counts include source duplicates and can overlap across checks. Do not add

  them together to derive total rejected records. An absent format/value group

  means there were no rows in that group; confirm table totals first.

**## Run locally (PowerShell)**

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

**## Task 3: approved assumptions and implementation**

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

Delivered-only revenue and the receivables cutoff of ****2025-12-31**** belong to

Task 4 queries; cleaning neither filters future payments nor calculates reports.

**### Execute and verify Task 3 locally**

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

\# Capture all counts, checks, and full-content fingerprints, then rerun cleaning.

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

business-rule violation counts must be ****0****. Review these values even if the

SQL command exits successfully: verification prints violations for inspection.

Every table must satisfy `raw_rows = retained_rows + rejected_rows`; for

`raw_customer_changes`, retained means a change applied to a clean customer.

The final fingerprints include all clean/reject contents and all raw contents.

Matching counts alone are insufficient to establish rerun stability.

Clean and rejected row counts have been verified against PostgreSQL. The automated project check passed 41 SQL invariants, matched all seven raw table counts to source CSVs, and verified `results/q1.csv`, `results/q2.csv`, `results/q3.csv`, and `results/summary.json` against the current database. A separate repeat-run fingerprint comparison has not been evidenced in this review.
