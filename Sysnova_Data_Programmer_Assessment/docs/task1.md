# Task 1 — Raw Data Import

## Overview

The raw-data stage loads the seven supplied CSV files into PostgreSQL without changing their source values. The tables use text columns so that inconsistent dates, spacing, missing values and duplicate records remain available for profiling and cleaning in later tasks.

The database used for the assessment is `sysnova_assessment`. The import is implemented in `sql/01_create_raw.sql` and `scripts/load_raw.py`.

## Setup and import

Requirements: Python 3.10 or later, PostgreSQL and the packages listed in `requirements.txt`.

From the `Sysnova_Data_Programmer_Assessment` directory in PowerShell:

```powershell
python -m venv venv
.\venv\Scripts\python.exe -m pip install -r requirements.txt

$psql = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
$createdb = 'C:\Program Files\PostgreSQL\18\bin\createdb.exe'

$env:PGHOST = 'localhost'
$env:PGPORT = '5432'
$env:PGUSER = 'postgres'
$env:PGDATABASE = 'sysnova_assessment'
$password = Read-Host 'PostgreSQL password' -AsSecureString
$env:PGPASSWORD = [System.Net.NetworkCredential]::new('', $password).Password
```

Create the database only if it does not already exist:

```powershell
& $createdb --maintenance-db=postgres sysnova_assessment
```

Then create the raw tables and load the CSV files:

```powershell
& $psql -X -v ON_ERROR_STOP=1 -f .\sql\01_create_raw.sql
.\venv\Scripts\python.exe .\scripts\load_raw.py
```

The loader reads CSV files from the project directory rather than the shell's current location. It replaces the contents of the raw tables within a transaction, preserving duplicate source rows. A failed import rolls back instead of leaving partially loaded data.

## Import results

The loaded row counts were checked in PostgreSQL and matched the source CSV record counts.

| Raw table | Rows |
|---|---:|
| `raw_customers` | 408 |
| `raw_customer_changes` | 73 |
| `raw_products` | 60 |
| `raw_orders` | 20,200 |
| `raw_order_lines` | 49,213 |
| `raw_invoices` | 16,941 |
| `raw_payments` | 19,096 |
| **Total** | **105,991** |

Counts can be checked again with:

```sql
SELECT 'raw_customers' AS table_name, COUNT(*) AS rows FROM raw_customers
UNION ALL SELECT 'raw_customer_changes', COUNT(*) FROM raw_customer_changes
UNION ALL SELECT 'raw_products', COUNT(*) FROM raw_products
UNION ALL SELECT 'raw_orders', COUNT(*) FROM raw_orders
UNION ALL SELECT 'raw_order_lines', COUNT(*) FROM raw_order_lines
UNION ALL SELECT 'raw_invoices', COUNT(*) FROM raw_invoices
UNION ALL SELECT 'raw_payments', COUNT(*) FROM raw_payments;
```

A separate project verification run confirmed that all seven raw-table counts matched their CSV inputs. Raw data issues are documented in `docs/data_issues.md`; cleaning takes place in Task 3.

For security, remove the session password variable after running database commands:

```powershell
Remove-Item Env:PGPASSWORD
Remove-Variable password
```
