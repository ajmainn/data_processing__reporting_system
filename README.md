# Sales Data Processing and Reporting System

A PostgreSQL and Python pipeline for loading, profiling, cleaning, and reporting on a synthetic food-distribution sales dataset. The workflow covers customers, products, sales orders, order lines, invoices, and payments. Monetary amounts are in BDT.

The implementation is located in `Sysnova_Data_Programmer_Assessment/`. The original files in `data/raw/` are treated as read-only inputs.

## Technology

- PostgreSQL (locally verified with PostgreSQL 18)
- Python 3 with `psycopg[binary]`
- SQL for data validation, transformation, and reporting
- PowerShell for the setup commands shown below

## Repository layout

```text
data_processing__reporting_system/
├── README.md
└── Sysnova_Data_Programmer_Assessment/
    ├── data/raw/                # Seven supplied CSV files
    ├── docs/                    # Data profiling and implementation notes
    ├── scripts/
    │   ├── load_raw.py
    │   ├── export_results.py
    │   └── verify_project.py
    ├── sql/
    │   ├── 01_create_raw.sql
    │   ├── inspect_data.sql
    │   ├── 02_clean.sql
    │   ├── verify_clean.sql
    │   ├── q1.sql
    │   ├── q2.sql
    │   └── q3.sql
    ├── results/                 # Generated report files
    │   ├── q1.csv
    │   ├── q2.csv
    │   ├── q3.csv
    │   └── summary.json
    ├── requirements.txt
    └── TASK.md
```

## Setup and execution

The following commands are intended for **Windows PowerShell**. PostgreSQL must be installed and running. The commands use a local server on port `5432` and the `postgres` role; adjust the connection settings where necessary.

From the repository root:

```powershell
Set-Location .\Sysnova_Data_Programmer_Assessment

python -m venv venv
$python = (Resolve-Path .\venv\Scripts\python.exe).Path
& $python -m pip install -r .\requirements.txt

$psql = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
$createdb = 'C:\Program Files\PostgreSQL\18\bin\createdb.exe'

$env:PGHOST = 'localhost'
$env:PGPORT = '5432'
$env:PGUSER = 'postgres'
$password = Read-Host 'PostgreSQL password' -AsSecureString
$env:PGPASSWORD = [System.Net.NetworkCredential]::new('', $password).Password

# Run once for a new setup; skip if the database already exists.
& $createdb --maintenance-db=postgres sysnova_assessment
$env:PGDATABASE = 'sysnova_assessment'
& $psql -c 'SELECT current_database(), current_user;'
```

After successful connection, execute the pipeline in this order:

```powershell
# 1. Create and populate seven raw tables.
& $psql -X -v ON_ERROR_STOP=1 -f .\sql\01_create_raw.sql
& $python .\scripts\load_raw.py

# 2. Profile the source data.
& $psql -X -v ON_ERROR_STOP=1 -P pager=off -f .\sql\inspect_data.sql

# 3. Transform and validate the clean tables.
& $psql -X -v ON_ERROR_STOP=1 -f .\sql\02_clean.sql
& $psql -X -v ON_ERROR_STOP=1 -P pager=off -f .\sql\verify_clean.sql

# 4. Generate the required reporting outputs.
& $python .\scripts\export_results.py

# 5. Verify database invariants, source counts, and exported files.
& $python .\scripts\verify_project.py
```

Stop and investigate if any command returns an error. The database creation command is not intended to run again against an existing database. The raw loader replaces the raw-table contents transactionally; the cleaning logic can be rerun without accumulating duplicate records.

When finished, clear the password from the session:

```powershell
Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
Remove-Variable password -ErrorAction SilentlyContinue
```

## Data preparation and validation

The pipeline preserves the source CSV data in seven raw tables before applying transformations to typed clean tables. Processing includes:

- Selecting the latest customer master record and the latest effective customer change.
- Standardizing customer regions and order statuses.
- Parsing ISO and `DD/MM/YYYY` order dates.
- Deduplicating orders and payments by their business keys.
- Rejecting orders with missing statuses or unknown customers, along with invalid or dependent records.
- Rejecting nonpositive line quantities and replacing missing line prices with the corresponding product list price.
- Calculating line net amounts using quantity, unit price, and discount percentage.
- Recording excluded source rows in `rejected_records` with explicit reasons.

The clean schema uses typed columns, primary keys, foreign keys, and applicable constraints. Cleaning rules, additional assumptions, and measured source-data findings are documented in [`docs/data_issues.md`](Sysnova_Data_Programmer_Assessment/docs/data_issues.md).

### Data-quality findings

Selected findings from the completed raw-data inspection:

| Finding | Affected raw rows |
|---|---:|
| Excess duplicate customer IDs | 8 |
| Customer regions requiring normalization | 25 |
| Missing order-line unit prices | 147 |
| Nonpositive order-line quantities | 246 |
| Excess duplicate order IDs | 200 |
| Orders referencing unknown customers | 102 |
| Missing order statuses | 60 |
| Order dates in `DD/MM/YYYY` format | 1,614 |
| Order statuses requiring normalization | 805 |
| Excess duplicate payment IDs | 95 |

These findings can overlap and should not be summed as a total rejection count. Following transformation, the verified reject log contains **1,384 records**.

## Order-to-cash workflow

A customer and product catalog provide the master data used in sales transactions.
A sales order is recorded in `orders`, with its purchased items in `order_lines`.
Each order line identifies a product, quantity, unit price, and discount.
An eligible shipped, delivered, or returned order can be associated with an invoice in `invoices`.
The invoice records the billed amount and the invoice and due dates.
Payments received against an invoice are recorded in `payments`; several payments may relate to the same invoice.
Accounts receivable is the billed invoice amount less eligible payments received by the reporting cutoff date.

## Reports

| Output | Description |
|---|---|
| `results/q1.csv` | Monthly recognized revenue from delivered-order net lines, with month-over-month growth percentages. |
| `results/q2.csv` | Top three customers by recognized revenue in each current region for calendar year 2025. |
| `results/q3.csv` | Open receivables aging as of 2025-12-31, including invoice counts and outstanding balances across five aging buckets. |
| `results/summary.json` | Seven database-derived summary metrics specified by the assessment. |

Revenue recognition uses delivered orders only. Receivables use billed invoice amounts and subtract payments received on or before `2025-12-31`. Invoices without a positive outstanding balance are excluded from open receivables. See [`docs/task4.md`](Sysnova_Data_Programmer_Assessment/docs/task4.md) for detailed reporting conventions.

## Results and verification

A completed local run against the `sysnova_assessment` PostgreSQL database produced the following clean-table counts:

| Table | Rows |
|---|---:|
| `clean_customers` | 400 |
| `clean_products` | 60 |
| `clean_orders` | 19,840 |
| `clean_order_lines` | 48,593 |
| `clean_invoices` | 16,805 |
| `clean_payments` | 18,849 |
| `rejected_records` | 1,384 |

The reporting export completed with 24 rows in `q1.csv`, 21 rows in `q2.csv`, and five rows in `q3.csv`. The summary JSON contains seven metrics.

The local verification command reported:

```text
PASS: 41 SQL invariant checks; seven raw counts match source CSVs.
PASS: all four required output files match validated current database results.
```

The database verification also reported zero duplicate clean IDs, orphaned relationships, accounting inconsistencies, and cleaning-rule violations. These are results of the recorded local run, not a claim of an independently tested fresh checkout on another machine.

## Implementation decisions

- Duplicate customer records are resolved using the latest `updated_at`; customer change history is resolved using the latest `effective_date`. Deterministic source-text ordering resolves otherwise tied records.
- Duplicate source occurrences are accounted for individually. Each rejected occurrence receives one primary rejection reason.
- Invoices and payments whose parent records are missing or rejected are not loaded into the respective clean tables.
- Invoice billed amounts remain unchanged; they are not recomputed from order lines.
- Monthly growth is left blank for the first reporting month or when the preceding month's revenue is zero.
- Aging distinguishes not-yet-due amounts and balances 1–30, 31–60, 61–90, and more than 90 days past due.

These decisions and their implications are described further in the accompanying documentation.

## Potential improvements

- Add an automated integration test that creates and tears down a fresh test database.
- Incorporate structured execution logs and clearer command-level failure reporting.
- Add a continuous integration workflow for Python checks and reproducible database tests.
- Review query execution plans and indexes for larger production-scale datasets.

## Additional documentation

- [`docs/task1.md`](Sysnova_Data_Programmer_Assessment/docs/task1.md) — raw-data loading approach.
- [`docs/data_issues.md`](Sysnova_Data_Programmer_Assessment/docs/data_issues.md) — data-quality findings and cleaning decisions.
- [`docs/task4.md`](Sysnova_Data_Programmer_Assessment/docs/task4.md) — report definitions and export validation.

The `AI_USAGE.md` disclosure is maintained separately in accordance with the assessment instructions when AI tools have been used.
