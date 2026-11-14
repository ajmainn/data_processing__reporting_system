-- Exactly three per current region where at least three customers have revenue.
-- Revenue ties are broken by customer_id using a fixed collation.
WITH customer_revenue AS (
    SELECT c.region, c.customer_id, c.customer_name, sum(l.net_amount) AS recognized_revenue
    FROM public.clean_customers c
    JOIN public.clean_orders o ON o.customer_id = c.customer_id
    JOIN public.clean_order_lines l ON l.order_id = o.order_id
    WHERE o.status = 'delivered'
      AND o.order_date >= DATE '2025-01-01'
      AND o.order_date < DATE '2026-01-01'
    GROUP BY c.region, c.customer_id, c.customer_name
), ranked AS (
    SELECT *, row_number() OVER (
        PARTITION BY region ORDER BY recognized_revenue DESC, customer_id COLLATE "C"
    ) AS customer_rank
    FROM customer_revenue
)
SELECT region, customer_rank, customer_id, customer_name, recognized_revenue
FROM ranked WHERE customer_rank <= 3
ORDER BY region COLLATE "C", customer_rank, customer_id COLLATE "C";
