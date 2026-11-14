-- Task 2 only: read-only profiling, with a consistent snapshot of all seven tables.
-- affected_rows includes source duplicates. Metrics overlap; do not sum them.
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;

WITH source_rows AS (
    SELECT 'raw_customers' AS table_name, to_jsonb(t) AS data FROM public.raw_customers t
    UNION ALL SELECT 'raw_customer_changes', to_jsonb(t) FROM public.raw_customer_changes t
    UNION ALL SELECT 'raw_products', to_jsonb(t) FROM public.raw_products t
    UNION ALL SELECT 'raw_orders', to_jsonb(t) FROM public.raw_orders t
    UNION ALL SELECT 'raw_order_lines', to_jsonb(t) FROM public.raw_order_lines t
    UNION ALL SELECT 'raw_invoices', to_jsonb(t) FROM public.raw_invoices t
    UNION ALL SELECT 'raw_payments', to_jsonb(t) FROM public.raw_payments t
), tables(table_name, key_columns) AS (
    VALUES ('raw_customers', ARRAY['customer_id']),
           ('raw_customer_changes', ARRAY['customer_id', 'effective_date']),
           ('raw_products', ARRAY['product_id']),
           ('raw_orders', ARRAY['order_id']),
           ('raw_order_lines', ARRAY['line_id']),
           ('raw_invoices', ARRAY['invoice_id']),
           ('raw_payments', ARRAY['payment_id'])
), keyed AS (
    SELECT s.*, (SELECT jsonb_agg(data -> col ORDER BY pos)
                 FROM unnest(t.key_columns) WITH ORDINALITY AS k(col, pos)) AS key_value
    FROM source_rows s JOIN tables t USING (table_name)
), key_groups AS (
    SELECT table_name, key_value, COUNT(*) AS n, COUNT(DISTINCT data) AS variants
    FROM keyed GROUP BY table_name, key_value
), fields AS (
    SELECT table_name, f.key AS column_name, f.value
    FROM source_rows CROSS JOIN LATERAL jsonb_each_text(data) f
), relationships(child, column_name, parent, parent_key) AS (
    VALUES ('raw_customer_changes', 'customer_id', 'raw_customers', 'customer_id'),
           ('raw_orders', 'customer_id', 'raw_customers', 'customer_id'),
           ('raw_order_lines', 'order_id', 'raw_orders', 'order_id'),
           ('raw_order_lines', 'product_id', 'raw_products', 'product_id'),
           ('raw_invoices', 'order_id', 'raw_orders', 'order_id'),
           ('raw_payments', 'invoice_id', 'raw_invoices', 'invoice_id')
), reference_counts AS (
    SELECT r.child, r.column_name,
           COUNT(*) FILTER (WHERE s.table_name IS NOT NULL AND NOT EXISTS (
               SELECT 1 FROM source_rows p
               WHERE p.table_name = r.parent
                 AND p.data ->> r.parent_key = s.data ->> r.column_name
           )) AS n
    FROM relationships r LEFT JOIN source_rows s ON s.table_name = r.child
    GROUP BY r.child, r.column_name
), order_dates AS (
    SELECT CASE
        WHEN NULLIF(btrim(order_date), '') IS NULL THEN 'missing'
        WHEN order_date ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN 'ISO YYYY-MM-DD'
        WHEN order_date ~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' THEN 'DD/MM/YYYY'
        ELSE 'other format'
    END AS date_format
    FROM public.raw_orders
), numeric_fields AS (
    SELECT *, CASE WHEN btrim(value) ~ '^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)$'
                   THEN btrim(value)::numeric END AS number
    FROM fields
    WHERE (table_name = 'raw_order_lines' AND column_name IN ('quantity', 'unit_price', 'discount_pct'))
       OR (table_name = 'raw_products' AND column_name = 'list_price')
), metrics AS (
    SELECT t.table_name, 'row_count' AS issue, '' AS detail, COUNT(s.table_name) AS affected_rows
    FROM tables t LEFT JOIN source_rows s USING (table_name) GROUP BY t.table_name
    UNION ALL
    SELECT t.table_name, 'duplicate_key_excess', array_to_string(t.key_columns, ', '),
           COALESCE(SUM(g.n - 1) FILTER (WHERE g.n > 1), 0)::bigint
    FROM tables t LEFT JOIN key_groups g USING (table_name) GROUP BY t.table_name, t.key_columns
    UNION ALL
    SELECT t.table_name, 'rows_in_duplicate_key_groups', array_to_string(t.key_columns, ', '),
           COALESCE(SUM(g.n) FILTER (WHERE g.n > 1), 0)::bigint
    FROM tables t LEFT JOIN key_groups g USING (table_name) GROUP BY t.table_name, t.key_columns
    UNION ALL
    SELECT t.table_name, 'rows_in_conflicting_key_groups', array_to_string(t.key_columns, ', '),
           COALESCE(SUM(g.n) FILTER (WHERE g.n > 1 AND g.variants > 1), 0)::bigint
    FROM tables t LEFT JOIN key_groups g USING (table_name) GROUP BY t.table_name, t.key_columns
    UNION ALL
    SELECT table_name, 'missing_value', column_name,
           COUNT(*) FILTER (WHERE NULLIF(btrim(value), '') IS NULL)
    FROM fields GROUP BY table_name, column_name
    UNION ALL
    SELECT child, 'missing_reference', column_name, n FROM reference_counts
    UNION ALL
    SELECT 'raw_orders', 'invalid_nonblank_status', 'after trim and lowercase', COUNT(*)
    FROM public.raw_orders
    WHERE NULLIF(btrim(status), '') IS NOT NULL
      AND lower(btrim(status)) NOT IN ('placed', 'shipped', 'delivered', 'cancelled', 'returned')
    UNION ALL
    SELECT 'raw_orders', 'status_needs_normalization', 'case or surrounding spaces', COUNT(*)
    FROM public.raw_orders WHERE status IS DISTINCT FROM lower(btrim(status))
    UNION ALL
    SELECT 'raw_orders', 'order_date_format', date_format, COUNT(*)
    FROM order_dates GROUP BY date_format
    UNION ALL
    SELECT table_name, 'invalid_numeric_text', column_name,
           COUNT(*) FILTER (WHERE NULLIF(btrim(value), '') IS NOT NULL AND number IS NULL)
    FROM numeric_fields GROUP BY table_name, column_name
    UNION ALL
    SELECT 'raw_order_lines', 'nonpositive_quantity', 'quantity <= 0', COUNT(*)
    FROM numeric_fields WHERE column_name = 'quantity' AND number <= 0
    UNION ALL
    SELECT table_name, 'negative_price', column_name, COUNT(*) FILTER (WHERE number < 0)
    FROM numeric_fields WHERE column_name IN ('unit_price', 'list_price')
    GROUP BY table_name, column_name
    UNION ALL
    SELECT 'raw_order_lines', 'discount_out_of_range', 'outside 0..100', COUNT(*)
    FROM numeric_fields WHERE column_name = 'discount_pct' AND (number < 0 OR number > 100)
    UNION ALL
    SELECT table_name, 'region_needs_normalization', 'trim and Title Case',
           COUNT(*) FILTER (WHERE value IS DISTINCT FROM initcap(btrim(value)))
    FROM fields WHERE column_name = 'region' GROUP BY table_name
    UNION ALL
    SELECT table_name, 'region_value', COALESCE(to_json(value)::text, 'SQL NULL'), COUNT(*)
    FROM fields WHERE column_name = 'region' GROUP BY table_name, value
)
SELECT table_name, issue, detail, affected_rows
FROM metrics ORDER BY table_name, issue, detail;

COMMIT;
