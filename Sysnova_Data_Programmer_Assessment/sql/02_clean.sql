-- Task 3 only. Run after Task 1; raw tables are read and locked, never changed.
BEGIN;
SET LOCAL search_path = public, pg_temp;
LOCK TABLE public.raw_customers, public.raw_customer_changes, public.raw_products,
    public.raw_orders, public.raw_order_lines, public.raw_invoices, public.raw_payments
    IN SHARE MODE;

-- 1. Safe conversions: invalid values become explicit rejects, not guessed values.
CREATE OR REPLACE FUNCTION pg_temp.raw_date(value text, allow_dmy boolean DEFAULT false)
RETURNS date LANGUAGE plpgsql AS $$
BEGIN
    value := btrim(value);
    IF value ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
        RETURN make_date(substr(value,1,4)::integer, substr(value,6,2)::integer,
                         substr(value,9,2)::integer);
    ELSIF allow_dmy AND value ~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' THEN
        RETURN make_date(substr(value,7,4)::integer, substr(value,4,2)::integer,
                         substr(value,1,2)::integer);
    END IF;
    RETURN NULL;
EXCEPTION WHEN datetime_field_overflow OR invalid_datetime_format THEN
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.raw_number(value text)
RETURNS numeric LANGUAGE sql AS $$
    SELECT CASE WHEN btrim(value) ~ '^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)$'
                THEN btrim(value)::numeric END;
$$;

-- A stable row number distinguishes identical source copies without altering raw.
-- Identical copies are interchangeable; their row-number set is deterministic.
CREATE TEMP TABLE source_rows ON COMMIT DROP AS
WITH inputs AS (
    SELECT 'raw_customers'::text AS source_table, to_jsonb(t) AS record FROM public.raw_customers t
    UNION ALL SELECT 'raw_customer_changes', to_jsonb(t) FROM public.raw_customer_changes t
    UNION ALL SELECT 'raw_products', to_jsonb(t) FROM public.raw_products t
    UNION ALL SELECT 'raw_orders', to_jsonb(t) FROM public.raw_orders t
    UNION ALL SELECT 'raw_order_lines', to_jsonb(t) FROM public.raw_order_lines t
    UNION ALL SELECT 'raw_invoices', to_jsonb(t) FROM public.raw_invoices t
    UNION ALL SELECT 'raw_payments', to_jsonb(t) FROM public.raw_payments t
)
SELECT source_table, row_number() OVER (
    PARTITION BY source_table ORDER BY record::text COLLATE "C"
) AS source_row, record FROM inputs;
ALTER TABLE source_rows ADD PRIMARY KEY (source_table, source_row);

-- No arbitrary deduplication rule was approved for these three unique-key sources.
-- Fail atomically if unexpected duplicates appear, rather than lose records.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM source_rows
        WHERE source_table IN ('raw_products', 'raw_order_lines', 'raw_invoices')
        GROUP BY source_table, CASE source_table
            WHEN 'raw_products' THEN record->>'product_id'
            WHEN 'raw_order_lines' THEN record->>'line_id'
            ELSE record->>'invoice_id' END
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'Unexpected duplicate product/line/invoice keys: resolve policy before cleaning';
    END IF;
END;
$$;

-- 2. Typed clean schema and one audit entry per rejected source row.
CREATE TABLE IF NOT EXISTS public.clean_customers (
    customer_id text PRIMARY KEY CHECK (btrim(customer_id) <> ''),
    customer_name text NOT NULL CHECK (btrim(customer_name) <> ''),
    region text NOT NULL CHECK (region <> '' AND region = initcap(btrim(region))),
    segment text NOT NULL CHECK (btrim(segment) <> ''),
    credit_limit numeric NOT NULL CHECK (credit_limit >= 0),
    email text,
    created_at date NOT NULL,
    updated_at date NOT NULL,
    source_row bigint NOT NULL UNIQUE,
    change_source_row bigint UNIQUE
);
CREATE TABLE IF NOT EXISTS public.clean_products (
    product_id text PRIMARY KEY CHECK (btrim(product_id) <> ''),
    sku text, product_name text, category text,
    list_price numeric NOT NULL CHECK (list_price >= 0),
    uom text,
    source_row bigint NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS public.clean_orders (
    order_id text PRIMARY KEY CHECK (btrim(order_id) <> ''),
    customer_id text NOT NULL REFERENCES public.clean_customers(customer_id),
    order_date date NOT NULL,
    status text NOT NULL CHECK (status IN ('placed','shipped','delivered','cancelled','returned')),
    channel text,
    source_row bigint NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS public.clean_order_lines (
    line_id text PRIMARY KEY CHECK (btrim(line_id) <> ''),
    order_id text NOT NULL REFERENCES public.clean_orders(order_id),
    product_id text NOT NULL REFERENCES public.clean_products(product_id),
    quantity numeric NOT NULL CHECK (quantity > 0),
    unit_price numeric NOT NULL CHECK (unit_price >= 0),
    discount_pct numeric NOT NULL CHECK (discount_pct BETWEEN 0 AND 100),
    net_amount numeric GENERATED ALWAYS AS (quantity * unit_price * (1 - discount_pct / 100)) STORED,
    source_row bigint NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS public.clean_invoices (
    invoice_id text PRIMARY KEY CHECK (btrim(invoice_id) <> ''),
    order_id text NOT NULL UNIQUE REFERENCES public.clean_orders(order_id),
    invoice_date date NOT NULL,
    due_date date NOT NULL,
    amount numeric NOT NULL CHECK (amount >= 0),
    source_row bigint NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS public.clean_payments (
    payment_id text PRIMARY KEY CHECK (btrim(payment_id) <> ''),
    invoice_id text NOT NULL REFERENCES public.clean_invoices(invoice_id),
    payment_date date NOT NULL,
    amount numeric NOT NULL CHECK (amount >= 0),
    method text,
    source_row bigint NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS public.rejected_records (
    source_table text NOT NULL CHECK (source_table IN (
        'raw_customers','raw_customer_changes','raw_products','raw_orders',
        'raw_order_lines','raw_invoices','raw_payments')),
    source_row bigint NOT NULL,
    source_record jsonb NOT NULL,
    reason text NOT NULL CHECK (reason <> ''),
    PRIMARY KEY (source_table, source_row)
);
-- All clean data and audit rows are replaced in the same transaction, never appended.
TRUNCATE public.clean_payments, public.clean_invoices, public.clean_order_lines,
    public.clean_orders, public.clean_products, public.clean_customers, public.rejected_records;

-- 3. Rank master/history records before validation; never fall back to an older row.
CREATE TEMP TABLE customer_candidates ON COMMIT DROP AS
SELECT s.*, pg_temp.raw_date(record->>'updated_at') AS updated_at,
    pg_temp.raw_date(record->>'created_at') AS created_at,
    pg_temp.raw_number(record->>'credit_limit') AS credit_limit,
    row_number() OVER (PARTITION BY record->>'customer_id'
        ORDER BY pg_temp.raw_date(record->>'updated_at') DESC NULLS LAST,
                 record::text COLLATE "C", source_row) AS rank
FROM source_rows s WHERE source_table = 'raw_customers';

CREATE TEMP TABLE change_candidates ON COMMIT DROP AS
SELECT s.*, pg_temp.raw_date(record->>'effective_date') AS effective_date,
    row_number() OVER (PARTITION BY record->>'customer_id'
        ORDER BY pg_temp.raw_date(record->>'effective_date') DESC NULLS LAST,
                 record::text COLLATE "C", source_row) AS rank
FROM source_rows s WHERE source_table = 'raw_customer_changes';

CREATE TEMP TABLE customer_decisions ON COMMIT DROP AS
SELECT c.*, h.source_row AS change_source_row,
    CASE WHEN h.source_row IS NOT NULL THEN h.record->>'region'
         ELSE c.record->>'region' END AS current_region,
    CASE WHEN h.source_row IS NOT NULL THEN h.record->>'segment'
         ELSE c.record->>'segment' END AS current_segment,
    CASE
        WHEN c.rank > 1 THEN 'duplicate_customer_id'
        WHEN NULLIF(btrim(c.record->>'customer_id'),'') IS NULL THEN 'missing_customer_id'
        WHEN c.updated_at IS NULL OR c.created_at IS NULL THEN 'invalid_customer_date'
        WHEN c.credit_limit IS NULL OR c.credit_limit < 0 THEN 'invalid_credit_limit'
        WHEN NULLIF(btrim(c.record->>'customer_name'),'') IS NULL THEN 'missing_customer_name'
        WHEN h.source_row IS NOT NULL AND h.effective_date IS NULL THEN 'invalid_customer_change_date'
        WHEN NULLIF(btrim(CASE WHEN h.source_row IS NOT NULL THEN h.record->>'region'
                              ELSE c.record->>'region' END),'') IS NULL THEN 'missing_current_region'
        WHEN NULLIF(btrim(CASE WHEN h.source_row IS NOT NULL THEN h.record->>'segment'
                              ELSE c.record->>'segment' END),'') IS NULL THEN 'missing_current_segment'
    END AS reason
FROM customer_candidates c LEFT JOIN change_candidates h
    ON h.record->>'customer_id' = c.record->>'customer_id' AND h.rank = 1;

INSERT INTO public.clean_customers
SELECT record->>'customer_id', record->>'customer_name', initcap(btrim(current_region)),
    current_segment, credit_limit, record->>'email', created_at, updated_at,
    source_row, change_source_row
FROM customer_decisions WHERE reason IS NULL;
INSERT INTO public.rejected_records
SELECT source_table, source_row, record, reason FROM customer_decisions WHERE reason IS NOT NULL;
INSERT INTO public.rejected_records
SELECT h.source_table, h.source_row, h.record,
    CASE WHEN h.rank > 1 THEN 'superseded_customer_change'
         ELSE 'missing_or_rejected_customer' END
FROM change_candidates h WHERE NOT EXISTS (
    SELECT 1 FROM public.clean_customers c WHERE c.change_source_row = h.source_row
);

-- 4. Products: retain supplied price for missing-line-price fallback and FK checks.
CREATE TEMP TABLE product_decisions ON COMMIT DROP AS
SELECT s.*, pg_temp.raw_number(record->>'list_price') AS list_price,
    CASE WHEN NULLIF(btrim(record->>'product_id'),'') IS NULL THEN 'missing_product_id'
         WHEN pg_temp.raw_number(record->>'list_price') IS NULL
           OR pg_temp.raw_number(record->>'list_price') < 0 THEN 'invalid_list_price'
    END AS reason
FROM source_rows s WHERE source_table = 'raw_products';
INSERT INTO public.clean_products
SELECT record->>'product_id', record->>'sku', record->>'product_name', record->>'category',
    list_price, record->>'uom', source_row FROM product_decisions WHERE reason IS NULL;
INSERT INTO public.rejected_records
SELECT source_table, source_row, record, reason FROM product_decisions WHERE reason IS NOT NULL;

-- 5. Orders: deterministic dedupe, normalized status, strict ISO or DD/MM/YYYY dates.
CREATE TEMP TABLE order_decisions ON COMMIT DROP AS
WITH ranked AS (
    SELECT s.*, row_number() OVER (PARTITION BY record->>'order_id'
        ORDER BY record::text COLLATE "C", source_row) AS rank
    FROM source_rows s WHERE source_table = 'raw_orders'
)
SELECT r.*, pg_temp.raw_date(record->>'order_date', true) AS order_date,
    lower(btrim(record->>'status')) AS status,
    CASE WHEN rank > 1 THEN 'duplicate_order_id'
         WHEN NULLIF(btrim(record->>'order_id'),'') IS NULL THEN 'missing_order_id'
         WHEN NULLIF(btrim(record->>'status'),'') IS NULL THEN 'missing_order_status'
         WHEN lower(btrim(record->>'status')) NOT IN
              ('placed','shipped','delivered','cancelled','returned') THEN 'invalid_order_status'
         WHEN NOT EXISTS (SELECT 1 FROM public.clean_customers c
                          WHERE c.customer_id = r.record->>'customer_id') THEN 'unknown_customer'
         WHEN pg_temp.raw_date(record->>'order_date',true) IS NULL THEN 'invalid_order_date'
    END AS reason
FROM ranked r;
INSERT INTO public.clean_orders
SELECT record->>'order_id', record->>'customer_id', order_date, status,
    record->>'channel', source_row FROM order_decisions WHERE reason IS NULL;
INSERT INTO public.rejected_records
SELECT source_table, source_row, record, reason FROM order_decisions WHERE reason IS NOT NULL;

-- 6. Lines: reject absent/rejected parents; fill only genuinely missing prices.
CREATE TEMP TABLE line_decisions ON COMMIT DROP AS
WITH parsed AS (
    SELECT s.*, p.product_id AS known_product,
        pg_temp.raw_number(record->>'quantity') AS quantity,
        CASE WHEN NULLIF(btrim(record->>'unit_price'),'') IS NULL THEN p.list_price
             ELSE pg_temp.raw_number(record->>'unit_price') END AS unit_price,
        pg_temp.raw_number(record->>'discount_pct') AS discount_pct
    FROM source_rows s LEFT JOIN public.clean_products p ON p.product_id = s.record->>'product_id'
    WHERE source_table = 'raw_order_lines'
)
SELECT p.*, CASE
    WHEN NULLIF(btrim(record->>'line_id'),'') IS NULL THEN 'missing_line_id'
    WHEN NOT EXISTS (SELECT 1 FROM public.clean_orders o
                     WHERE o.order_id = p.record->>'order_id') THEN 'missing_or_rejected_order'
    WHEN known_product IS NULL THEN 'missing_or_rejected_product'
    WHEN quantity IS NULL THEN 'invalid_quantity'
    WHEN quantity <= 0 THEN 'nonpositive_quantity'
    WHEN unit_price IS NULL OR unit_price < 0 THEN 'invalid_unit_price'
    WHEN discount_pct IS NULL OR discount_pct NOT BETWEEN 0 AND 100 THEN 'invalid_discount_pct'
    END AS reason FROM parsed p;
INSERT INTO public.clean_order_lines (line_id,order_id,product_id,quantity,unit_price,discount_pct,source_row)
SELECT record->>'line_id', record->>'order_id', record->>'product_id', quantity,
    unit_price, discount_pct, source_row FROM line_decisions WHERE reason IS NULL;
INSERT INTO public.rejected_records
SELECT source_table, source_row, record, reason FROM line_decisions WHERE reason IS NOT NULL;

-- 7. Invoices: billed amount is converted to exact numeric, never recalculated.
CREATE TEMP TABLE invoice_decisions ON COMMIT DROP AS
SELECT s.*, pg_temp.raw_date(record->>'invoice_date') AS invoice_date,
    pg_temp.raw_date(record->>'due_date') AS due_date,
    pg_temp.raw_number(record->>'amount') AS amount,
    CASE WHEN NULLIF(btrim(record->>'invoice_id'),'') IS NULL THEN 'missing_invoice_id'
         WHEN NOT EXISTS (SELECT 1 FROM public.clean_orders o
                          WHERE o.order_id = s.record->>'order_id') THEN 'missing_or_rejected_order'
         WHEN pg_temp.raw_date(record->>'invoice_date') IS NULL
           OR pg_temp.raw_date(record->>'due_date') IS NULL THEN 'invalid_invoice_date'
         WHEN pg_temp.raw_number(record->>'amount') IS NULL
           OR pg_temp.raw_number(record->>'amount') < 0 THEN 'invalid_invoice_amount'
    END AS reason
FROM source_rows s WHERE source_table = 'raw_invoices';
INSERT INTO public.clean_invoices
SELECT record->>'invoice_id', record->>'order_id', invoice_date, due_date, amount,
    source_row FROM invoice_decisions WHERE reason IS NULL;
INSERT INTO public.rejected_records
SELECT source_table, source_row, record, reason FROM invoice_decisions WHERE reason IS NOT NULL;

-- 8. Payments: dedupe before validation; keep all dates, including post-cutoff.
-- The 2025-12-31 cutoff applies to Task 4 receivables, not to cleaning.
CREATE TEMP TABLE payment_decisions ON COMMIT DROP AS
WITH ranked AS (
    SELECT s.*, row_number() OVER (PARTITION BY record->>'payment_id'
        ORDER BY record::text COLLATE "C", source_row) AS rank
    FROM source_rows s WHERE source_table = 'raw_payments'
)
SELECT r.*, pg_temp.raw_date(record->>'payment_date') AS payment_date,
    pg_temp.raw_number(record->>'amount') AS amount,
    CASE WHEN rank > 1 THEN 'duplicate_payment_id'
         WHEN NULLIF(btrim(record->>'payment_id'),'') IS NULL THEN 'missing_payment_id'
         WHEN NOT EXISTS (SELECT 1 FROM public.clean_invoices i
                          WHERE i.invoice_id = r.record->>'invoice_id') THEN 'missing_or_rejected_invoice'
         WHEN pg_temp.raw_date(record->>'payment_date') IS NULL THEN 'invalid_payment_date'
         WHEN pg_temp.raw_number(record->>'amount') IS NULL
           OR pg_temp.raw_number(record->>'amount') < 0 THEN 'invalid_payment_amount'
    END AS reason
FROM ranked r;
INSERT INTO public.clean_payments
SELECT record->>'payment_id', record->>'invoice_id', payment_date, amount,
    record->>'method', source_row FROM payment_decisions WHERE reason IS NULL;
INSERT INTO public.rejected_records
SELECT source_table, source_row, record, reason FROM payment_decisions WHERE reason IS NOT NULL;

-- 9. Every source occurrence must have exactly one outcome, including history rows.
DO $$
BEGIN
    IF EXISTS (
        WITH outcomes AS (
            SELECT 'raw_customers' AS source_table, source_row FROM public.clean_customers
            UNION ALL SELECT 'raw_customer_changes', change_source_row FROM public.clean_customers WHERE change_source_row IS NOT NULL
            UNION ALL SELECT 'raw_products', source_row FROM public.clean_products
            UNION ALL SELECT 'raw_orders', source_row FROM public.clean_orders
            UNION ALL SELECT 'raw_order_lines', source_row FROM public.clean_order_lines
            UNION ALL SELECT 'raw_invoices', source_row FROM public.clean_invoices
            UNION ALL SELECT 'raw_payments', source_row FROM public.clean_payments
            UNION ALL SELECT source_table, source_row FROM public.rejected_records
        ), counted AS (
            SELECT source_table, source_row, count(*) AS n FROM outcomes GROUP BY source_table,source_row
        )
        SELECT 1 FROM source_rows s FULL JOIN counted c USING (source_table,source_row)
        WHERE s.source_row IS NULL OR c.n IS DISTINCT FROM 1::bigint
    ) THEN
        RAISE EXCEPTION 'Source row accounting failed; all cleaning changes rolled back';
    END IF;
END;
$$;
COMMIT;
