# Task 1: raw data import

Prerequisites: Python 3.10+, PostgreSQL running locally, and PostgreSQL command-line
tools (`psql` and `createdb`) on PATH. Run these PowerShell commands from the
repository root:

```powershell
Set-Location .\Sysnova_Data_Programmer_Assessment
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt

$env:PGHOST = 'localhost'
$env:PGPORT = '5432'
$env:PGUSER = 'postgres' # Replace with your local PostgreSQL role.
$password = Read-Host 'PostgreSQL password' -AsSecureString
$env:PGPASSWORD = [System.Net.NetworkCredential]::new('', $password).Password

# Run once; skip if the database already exists.
createdb --maintenance-db=postgres sysnova_assessment
$env:PGDATABASE = 'sysnova_assessment'

psql -v ON_ERROR_STOP=1 -f .\sql\01_create_raw.sql
.\.venv\Scripts\python.exe .\scripts\load_raw.py
```

Credentials are read from PostgreSQL environment variables. No `.env` file is
needed or automatically loaded. Adjust the host, port and role for your setup.
The loader resolves CSV paths relative to its own project folder, regardless of
the terminal's current directory.

All raw columns are `text`. Empty CSV fields remain empty strings, and original
spacing, date strings and duplicate records remain intact. Each run truncates
and reloads all seven raw tables in one transaction, without `CASCADE`. Failure
rolls back the entire import. Concurrent imports serialize on the table locks.
This replaces raw table contents; it does not append or clean records.

## Row-count checks

Run this in PowerShell after the import:

```powershell
@'
SELECT 'raw_customers' AS table_name, COUNT(*) AS row_count FROM public.raw_customers
UNION ALL SELECT 'raw_customer_changes', COUNT(*) FROM public.raw_customer_changes
UNION ALL SELECT 'raw_products', COUNT(*) FROM public.raw_products
UNION ALL SELECT 'raw_orders', COUNT(*) FROM public.raw_orders
UNION ALL SELECT 'raw_order_lines', COUNT(*) FROM public.raw_order_lines
UNION ALL SELECT 'raw_invoices', COUNT(*) FROM public.raw_invoices
UNION ALL SELECT 'raw_payments', COUNT(*) FROM public.raw_payments
ORDER BY table_name;
'@ | psql -v ON_ERROR_STOP=1
```

Expected counts measured directly from the supplied CSVs (not database results):

| Table | Rows |
|---|---:|
| raw_customers | 408 |
| raw_customer_changes | 73 |
| raw_products | 60 |
| raw_orders | 20,200 |
| raw_order_lines | 49,213 |
| raw_invoices | 16,941 |
| raw_payments | 19,096 |

Run the schema command and loader a second time, then repeat the count query.
Both runs must produce these same counts; source duplicates are intentionally
preserved. The loader also compares each imported table's count to the number
of CSV records before committing.

Clear the password from this PowerShell session when finished:

```powershell
Remove-Item Env:PGPASSWORD
Remove-Variable password
```
