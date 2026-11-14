# AI Usage Disclosure

## 1. Tools and models used

| Tool | Model / version | Used for |
|---|---|---|
| ChatGPT (OpenAI) | GPT-6 | Project review, PostgreSQL troubleshooting, execution guidance, interpretation of verification results, and documentation drafting. |

## 2. Where AI helped, by task

- **Task 1:** Assisted with checking the PostgreSQL connection and interpreting raw-table row counts. The seven raw-table counts were later checked against the source CSV files by the project's verification script.
- **Task 2:** Assisted with interpreting the output of `sql/inspect_data.sql` and preparing the data-quality documentation from measured issue counts.
- **Task 3:** Assisted with interpreting `sql/verify_clean.sql` output, including duplicate checks, referential-integrity checks, rejected-record accounting, and cleaning-rule checks.
- **Task 4 (queries):** Reviewed the reporting implementation and guided execution of `scripts/export_results.py`. The generated CSV and JSON outputs were checked using `scripts/verify_project.py`.
- **Task 5 / optional extras:** Assisted with interpreting overall verification results and preparing the final submission checklist. No optional extra is claimed here.
- **README / docs:** Assisted with preparing the README and updating data-quality documentation. This disclosure describes that assistance separately.

## 3. Significant prompts (3–5, copied from the development conversation) and how the responses were used

1. **Prompt:** "check theprojetc now. I completed it with the command you gave me. review the project and find out how much completed and the given requirements are fullfilled or not. give me summary here"
   **Result and follow-up:** Received a requirement-by-requirement review. Remaining checks and documentation gaps were identified for verification.

2. **Prompt:** "not all step together. one step at a time. i will complete one step and then give you feedback. then go to the next step. okay?"
   **Result and follow-up:** The workflow was broken into individual commands, each followed by review of the actual PowerShell output.

3. **Prompt:** "start step 1. and reply in english"
   **Result and follow-up:** Received PostgreSQL connection instructions and confirmed the `sysnova_assessment` connection using `psql`.

4. **Prompt:** "there is no readme.md file. make me a fresh readme.md file. and jeta .md file banao tmi, emn vabe banaba jate sekhane emn kichu na thake jeta dekhe bojha jay je AI diye complete kora hoiche purata. and objective tone use korba. not I or you that type. understand? like just akta description dicche keu ei type"
   **Result and follow-up:** A README was drafted in a neutral technical style. AI assistance is disclosed explicitly in this separate file as required by the assessment.

## 4. Times the AI was wrong or misleading (at least 2) and how these issues were identified

1. **What went wrong:** The first attempt to generate reports failed with `psycopg.OperationalError: ... no password supplied`, despite earlier PostgreSQL setup guidance.
   **How it was noticed / verified:** `python .\scripts\export_results.py` printed the connection error in PowerShell. The earlier successful `psql` session did not establish that the Python process had a usable password.
   **Fix:** Re-entered the PostgreSQL password into the session's `PGPASSWORD` environment variable and reran the exporter. It generated `q1.csv` (24 rows), `q2.csv` (21 rows), `q3.csv` (5 rows), and `summary.json` (seven metrics).

2. **What went wrong:** Earlier AI guidance treated database execution and output verification as outstanding, even after parts of the database had been created. This was a status assessment based on the available project package, not definitive evidence about the local PostgreSQL database.
   **How it was noticed / verified:** Ran the actual SQL and Python verification commands against PostgreSQL 18 rather than relying on the project package or the AI review.
   **Fix:** Updated the project status using observed command results: clean-data checks showed zero reported violations, and `scripts/verify_project.py` reported 41 passing SQL invariant checks, seven raw counts matching source CSVs, and all four output files matching the current database results.

## 5. What was deliberately done independently (and why)

The PostgreSQL 18 database was operated locally, and the SQL/Python commands were executed in the project virtual environment. Connection results, raw-table counts, cleaning checks, report-generation output, and final verification output were inspected directly rather than accepting an AI statement as proof of execution. Database passwords were entered locally and were not included in documentation.

Recorded verification results:

- Seven populated raw tables; total raw rows: **105,991**.
- Six populated clean tables; **1,384** rejected source records tracked.
- Report files: `results/q1.csv`, `results/q2.csv`, `results/q3.csv`, and `results/summary.json`.
- Final verification: **41 SQL invariant checks passed**; all seven raw counts matched source CSVs; all four generated output files matched validated database results.

## 6. Declaration

I reviewed and understand all submitted code and can explain it. I did not get help from another person.

**Name:** ____________________  
**Date:** ____________________

> Complete and sign this declaration only after independently confirming that it is accurate. Review the prompt excerpts and descriptions above before submission, and correct any statement that does not match the actual development record.
