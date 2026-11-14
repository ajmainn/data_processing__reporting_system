-- Task 3 verification only. No source/clean tables are changed.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;

-- 1. Database-derived row counts, retained source rows and reject reasons.
SELECT 'clean_customers' AS table_name, count(*) AS rows FROM public.clean_customers
UNION ALL SELECT 'clean_products', count(*) FROM public.clean_products
UNION ALL SELECT 'clean_orders', count(*) FROM public.clean_orders
UNION ALL SELECT 'clean_order_lines', count(*) FROM public.clean_order_lines
UNION ALL SELECT 'clean_invoices', count(*) FROM public.clean_invoices
UNION ALL SELECT 'clean_payments', count(*) FROM public.clean_payments
UNION ALL SELECT 'rejected_records', count(*) FROM public.rejected_records
ORDER BY table_name;

SELECT source_table, reason, count(*) AS rejected_rows
FROM public.rejected_records GROUP BY source_table,reason ORDER BY source_table,reason;

-- 2. Unique business IDs and raw-source-row attribution. Each violation count must be 0.
WITH clean_rows AS (
    SELECT 'clean_customers' AS table_name, customer_id AS id, source_row FROM public.clean_customers
    UNION ALL SELECT 'clean_products', product_id, source_row FROM public.clean_products
    UNION ALL SELECT 'clean_orders', order_id, source_row FROM public.clean_orders
    UNION ALL SELECT 'clean_order_lines', line_id, source_row FROM public.clean_order_lines
    UNION ALL SELECT 'clean_invoices', invoice_id, source_row FROM public.clean_invoices
    UNION ALL SELECT 'clean_payments', payment_id, source_row FROM public.clean_payments
)
SELECT table_name, count(*) - count(DISTINCT id) AS duplicate_ids,
       count(*) - count(DISTINCT source_row) AS duplicate_source_rows
FROM clean_rows GROUP BY table_name ORDER BY table_name;

SELECT 'orders_without_customer' AS check_name, count(*) AS violations
FROM public.clean_orders o LEFT JOIN public.clean_customers c USING (customer_id) WHERE c.customer_id IS NULL
UNION ALL SELECT 'lines_without_order', count(*)
FROM public.clean_order_lines l LEFT JOIN public.clean_orders o USING (order_id) WHERE o.order_id IS NULL
UNION ALL SELECT 'lines_without_product', count(*)
FROM public.clean_order_lines l LEFT JOIN public.clean_products p USING (product_id) WHERE p.product_id IS NULL
UNION ALL SELECT 'invoices_without_order', count(*)
FROM public.clean_invoices i LEFT JOIN public.clean_orders o USING (order_id) WHERE o.order_id IS NULL
UNION ALL SELECT 'payments_without_invoice', count(*)
FROM public.clean_payments p LEFT JOIN public.clean_invoices i USING (invoice_id) WHERE i.invoice_id IS NULL
ORDER BY check_name;

-- 3. Per-occurrence reconciliation, not just totals that could mask lost copies.
WITH inputs AS (
    SELECT 'raw_customers' AS source_table, to_jsonb(t) AS record FROM public.raw_customers t
    UNION ALL SELECT 'raw_customer_changes', to_jsonb(t) FROM public.raw_customer_changes t
    UNION ALL SELECT 'raw_products', to_jsonb(t) FROM public.raw_products t
    UNION ALL SELECT 'raw_orders', to_jsonb(t) FROM public.raw_orders t
    UNION ALL SELECT 'raw_order_lines', to_jsonb(t) FROM public.raw_order_lines t
    UNION ALL SELECT 'raw_invoices', to_jsonb(t) FROM public.raw_invoices t
    UNION ALL SELECT 'raw_payments', to_jsonb(t) FROM public.raw_payments t
), numbered AS (
    SELECT *, row_number() OVER (PARTITION BY source_table ORDER BY record::text COLLATE "C") AS source_row
    FROM inputs
), retained AS (
    SELECT 'raw_customers' AS source_table, source_row FROM public.clean_customers
    UNION ALL SELECT 'raw_customer_changes', change_source_row FROM public.clean_customers WHERE change_source_row IS NOT NULL
    UNION ALL SELECT 'raw_products', source_row FROM public.clean_products
    UNION ALL SELECT 'raw_orders', source_row FROM public.clean_orders
    UNION ALL SELECT 'raw_order_lines', source_row FROM public.clean_order_lines
    UNION ALL SELECT 'raw_invoices', source_row FROM public.clean_invoices
    UNION ALL SELECT 'raw_payments', source_row FROM public.clean_payments
), outcomes AS (
    SELECT source_table, source_row, 'retained' AS outcome FROM retained
    UNION ALL SELECT source_table, source_row, 'rejected' FROM public.rejected_records
), counted AS (
    SELECT source_table,source_row,
        count(*) FILTER (WHERE outcome = 'retained') AS retained,
        count(*) FILTER (WHERE outcome = 'rejected') AS rejected
    FROM outcomes GROUP BY source_table,source_row
)
SELECT COALESCE(n.source_table,c.source_table) AS source_table,
    count(n.source_row) AS raw_rows, sum(COALESCE(c.retained,0)) AS retained_rows,
    sum(COALESCE(c.rejected,0)) AS rejected_rows,
    count(*) FILTER (WHERE n.source_row IS NULL OR COALESCE(c.retained,0) + COALESCE(c.rejected,0) <> 1) AS accounting_violations,
    count(*) FILTER (WHERE r.source_row IS NOT NULL AND r.source_record IS DISTINCT FROM n.record) AS reject_payload_violations
FROM numbered n FULL JOIN counted c USING (source_table,source_row)
LEFT JOIN public.rejected_records r ON r.source_table = COALESCE(n.source_table,c.source_table)
    AND r.source_row = COALESCE(n.source_row,c.source_row)
GROUP BY COALESCE(n.source_table,c.source_table) ORDER BY source_table;

-- 4. Business-rule spot checks. Every violation count must be 0.
WITH numbered_orders AS (
    SELECT r.*, row_number() OVER (ORDER BY to_jsonb(r)::text COLLATE "C") AS source_row
    FROM public.raw_orders r
), numbered_payments AS (
    SELECT r.*, row_number() OVER (ORDER BY to_jsonb(r)::text COLLATE "C") AS source_row
    FROM public.raw_payments r
)
SELECT 'invalid_status' AS check_name, count(*) AS violations FROM public.clean_orders
WHERE status IS NULL OR status NOT IN ('placed','shipped','delivered','cancelled','returned')
UNION ALL SELECT 'nonpositive_quantity', count(*) FROM public.clean_order_lines WHERE quantity IS NULL OR quantity <= 0
UNION ALL SELECT 'incorrect_net_amount', count(*) FROM public.clean_order_lines
WHERE net_amount IS DISTINCT FROM quantity * unit_price * (1 - discount_pct / 100)
UNION ALL SELECT 'region_not_normalized', count(*) FROM public.clean_customers
WHERE region IS NULL OR region IS DISTINCT FROM initcap(btrim(region))
UNION ALL SELECT 'invoice_amount_changed', count(*)
FROM public.clean_invoices i JOIN public.raw_invoices r USING (invoice_id)
WHERE i.amount IS DISTINCT FROM r.amount::numeric
UNION ALL SELECT 'payment_amount_changed', count(*)
FROM public.clean_payments p JOIN numbered_payments r USING (source_row)
WHERE p.amount IS DISTINCT FROM r.amount::numeric
UNION ALL SELECT 'wrong_price_fallback', count(*)
FROM public.clean_order_lines l JOIN public.raw_order_lines r USING (line_id)
JOIN public.clean_products p ON p.product_id = l.product_id
WHERE NULLIF(btrim(r.unit_price),'') IS NULL AND l.unit_price IS DISTINCT FROM p.list_price
UNION ALL SELECT 'order_date_parsed_incorrectly', count(*)
FROM public.clean_orders o JOIN numbered_orders r USING (source_row)
WHERE o.order_date IS DISTINCT FROM CASE
    WHEN btrim(r.order_date) ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN btrim(r.order_date)::date
    ELSE make_date(substr(btrim(r.order_date),7,4)::integer,
                   substr(btrim(r.order_date),4,2)::integer,substr(btrim(r.order_date),1,2)::integer) END
UNION ALL SELECT 'customer_not_latest', count(*)
FROM public.clean_customers c WHERE EXISTS (
    SELECT 1 FROM public.raw_customers r WHERE r.customer_id = c.customer_id AND r.updated_at::date > c.updated_at
)
UNION ALL SELECT 'incorrect_current_attributes', count(*)
FROM public.clean_customers c
LEFT JOIN LATERAL (
    SELECT h.region,h.segment FROM public.raw_customer_changes h WHERE h.customer_id = c.customer_id
    ORDER BY h.effective_date::date DESC, to_jsonb(h)::text COLLATE "C" LIMIT 1
) h ON true
LEFT JOIN LATERAL (
    SELECT r.region,r.segment FROM public.raw_customers r WHERE r.customer_id = c.customer_id
    ORDER BY r.updated_at::date DESC, to_jsonb(r)::text COLLATE "C" LIMIT 1
) r ON true
WHERE c.region IS DISTINCT FROM initcap(btrim(CASE WHEN c.change_source_row IS NOT NULL THEN h.region ELSE r.region END))
   OR c.segment IS DISTINCT FROM CASE WHEN c.change_source_row IS NOT NULL THEN h.segment ELSE r.segment END
ORDER BY check_name;

-- 5. Full-content fingerprints: compare these AND all checks before/after a rerun.
-- Include raw tables to detect any source changes between verification runs.
WITH contents AS (
    SELECT 'clean_customers' AS table_name, to_jsonb(t)::text AS record FROM public.clean_customers t
    UNION ALL SELECT 'clean_products', to_jsonb(t)::text FROM public.clean_products t
    UNION ALL SELECT 'clean_orders', to_jsonb(t)::text FROM public.clean_orders t
    UNION ALL SELECT 'clean_order_lines', to_jsonb(t)::text FROM public.clean_order_lines t
    UNION ALL SELECT 'clean_invoices', to_jsonb(t)::text FROM public.clean_invoices t
    UNION ALL SELECT 'clean_payments', to_jsonb(t)::text FROM public.clean_payments t
    UNION ALL SELECT 'rejected_records', to_jsonb(t)::text FROM public.rejected_records t
    UNION ALL SELECT 'raw_customers', to_jsonb(t)::text FROM public.raw_customers t
    UNION ALL SELECT 'raw_customer_changes', to_jsonb(t)::text FROM public.raw_customer_changes t
    UNION ALL SELECT 'raw_products', to_jsonb(t)::text FROM public.raw_products t
    UNION ALL SELECT 'raw_orders', to_jsonb(t)::text FROM public.raw_orders t
    UNION ALL SELECT 'raw_order_lines', to_jsonb(t)::text FROM public.raw_order_lines t
    UNION ALL SELECT 'raw_invoices', to_jsonb(t)::text FROM public.raw_invoices t
    UNION ALL SELECT 'raw_payments', to_jsonb(t)::text FROM public.raw_payments t
), names(table_name) AS (
    VALUES ('clean_customers'),('clean_products'),('clean_orders'),('clean_order_lines'),
           ('clean_invoices'),('clean_payments'),('rejected_records'),('raw_customers'),
           ('raw_customer_changes'),('raw_products'),('raw_orders'),('raw_order_lines'),
           ('raw_invoices'),('raw_payments')
)
SELECT n.table_name, count(c.record) AS rows,
    md5(COALESCE(string_agg(c.record, E'\n' ORDER BY c.record COLLATE "C"),'')) AS content_fingerprint
FROM names n LEFT JOIN contents c USING (table_name) GROUP BY n.table_name ORDER BY n.table_name;

COMMIT;
