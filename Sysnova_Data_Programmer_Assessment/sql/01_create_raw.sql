-- Keep every source field as text, including blanks and duplicate keys.
BEGIN;

CREATE TABLE IF NOT EXISTS public.raw_customers (
    customer_id text,
    customer_name text,
    region text,
    segment text,
    credit_limit text,
    email text,
    created_at text,
    updated_at text
);

CREATE TABLE IF NOT EXISTS public.raw_customer_changes (
    customer_id text,
    effective_date text,
    region text,
    segment text
);

CREATE TABLE IF NOT EXISTS public.raw_products (
    product_id text,
    sku text,
    product_name text,
    category text,
    list_price text,
    uom text
);

CREATE TABLE IF NOT EXISTS public.raw_orders (
    order_id text,
    customer_id text,
    order_date text,
    status text,
    channel text
);

CREATE TABLE IF NOT EXISTS public.raw_order_lines (
    line_id text,
    order_id text,
    product_id text,
    quantity text,
    unit_price text,
    discount_pct text
);

CREATE TABLE IF NOT EXISTS public.raw_invoices (
    invoice_id text,
    order_id text,
    invoice_date text,
    due_date text,
    amount text
);

CREATE TABLE IF NOT EXISTS public.raw_payments (
    payment_id text,
    invoice_id text,
    payment_date text,
    amount text,
    method text
);

COMMIT;
