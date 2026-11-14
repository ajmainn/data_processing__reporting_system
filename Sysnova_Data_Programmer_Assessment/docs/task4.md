# Task 4 — Reporting and Exports

## Overview

Task 4 generates three reports and a summary file from the cleaned PostgreSQL tables. The reporting logic is stored in the project SQL files and executed by `scripts/export_results.py`. Exports do not modify the source or cleaned tables.

The reporting stage requires successful completion of the clean-data load. Database access is configured through PostgreSQL connection environment variables.

## Generate reports

Run the following from the `Sysnova_Data_Programmer_Assessment` directory in PowerShell. The commands assume the project's existing `venv` environment and a local PostgreSQL 18 instance.

```powershell
$env:PGHOST = 'localhost'
$env:PGPORT = '5432'
$env:PGUSER = 'postgres'
$env:PGDATABASE = 'sysnova_assessment'
$password = Read-Host 'PostgreSQL password' -AsSecureString
$env:PGPASSWORD = [System.Net.NetworkCredential]::new('', $password).Password

.\venv\Scripts\python.exe .\scripts\export_results.py
```

The script creates or updates the following files in `results/`:

| File | Contents |
|---|---|
| `q1.csv` | Monthly recognized revenue and month-over-month growth |
| `q2.csv` | Top three customers by recognized revenue in each region for 2025 |
| `q3.csv` | Accounts receivable aging as of 2025-12-31 |
| `summary.json` | Seven metrics specified in `TASK.md` |

Credentials are supplied to the process at runtime; no password is stored in the exports or documentation.

## Reporting rules

### Monthly revenue (`q1.csv`)

Revenue is based on net order-line amounts for delivered orders and grouped by order month. The report covers all years represented in the cleaned orders, including months without delivered revenue. Growth is left blank where there is no valid previous-month comparison and otherwise reported to two decimal places.

### Top customers by region (`q2.csv`)

The customer ranking uses delivered-order revenue from 2025 and the current customer region in `clean_customers`. Up to three customers are included per region. Equal revenue totals are resolved by customer ID to keep the order consistent.

### Receivables aging (`q3.csv`)

Outstanding balances are calculated from invoices issued on or before 2025-12-31, less payments received by that date. Only positive balances are reported. Invoices are grouped into five buckets: not-yet-due, 1–30 days, 31–60 days, 61–90 days and over 90 days (`90+`). All five buckets appear in the export, including buckets with zero balances.

### Summary (`summary.json`)

The summary uses database-derived counts and totals. Rejected orders include duplicate occurrences recorded in the rejection log. The retained payment count reflects deduplication and parent-record validation. Revenue and outstanding-balance totals are reconciled with the corresponding reports.

## Validation results

Report generation completed successfully against the `sysnova_assessment` database:

| Output | Result |
|---|---|
| `results/q1.csv` | 24 rows; headers and values verified |
| `results/q2.csv` | 21 rows; headers and values verified |
| `results/q3.csv` | 5 rows; headers and values verified |
| `results/summary.json` | Seven database-derived metrics validated |

The export process also reconciled recognized revenue and accounts receivable totals. Its checks compare the generated figures against independent database calculations before writing the final files.

An additional run of `scripts/verify_project.py` returned:

```text
PASS: 41 SQL invariant checks; seven raw counts match source CSVs.
PASS: all four required output files match validated current database results.
```

The generated outputs are therefore consistent with the validated database state used for the final run.

To clear the stored password from the PowerShell session:

```powershell
Remove-Item Env:PGPASSWORD
Remove-Variable password
```
