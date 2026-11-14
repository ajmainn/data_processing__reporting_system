-- As-of balances use billed amounts, not order-line totals.
-- Due today is not yet overdue. Day 90 belongs to 61-90; 90+ means > 90.
WITH payments_as_of AS (
    SELECT invoice_id, sum(amount) AS amount
    FROM public.clean_payments
    WHERE payment_date <= DATE '2025-12-31'
    GROUP BY invoice_id
), balances AS (
    SELECT i.invoice_id, DATE '2025-12-31' - i.due_date AS days_past_due,
           i.amount - COALESCE(p.amount, 0::numeric) AS outstanding
    FROM public.clean_invoices i LEFT JOIN payments_as_of p USING (invoice_id)
    WHERE i.invoice_date <= DATE '2025-12-31'
), classified AS (
    SELECT *, CASE WHEN days_past_due <= 0 THEN 1
                   WHEN days_past_due <= 30 THEN 2
                   WHEN days_past_due <= 60 THEN 3
                   WHEN days_past_due <= 90 THEN 4
                   ELSE 5 END AS bucket_order
    FROM balances WHERE outstanding > 0
), buckets(bucket_order, aging_bucket) AS (
    VALUES (1, 'not-yet-due'), (2, '1-30'), (3, '31-60'), (4, '61-90'), (5, '90+')
)
SELECT b.aging_bucket, count(c.invoice_id) AS invoice_count,
       COALESCE(sum(c.outstanding), 0::numeric) AS outstanding_amount
FROM buckets b LEFT JOIN classified c USING (bucket_order)
GROUP BY b.bucket_order, b.aging_bucket ORDER BY b.bucket_order;
