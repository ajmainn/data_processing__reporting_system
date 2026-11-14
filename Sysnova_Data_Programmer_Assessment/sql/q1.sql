-- Include zero-revenue months between the first and last clean order month.
-- First month and months following zero revenue have undefined growth (NULL).
WITH monthly AS (
    SELECT date_trunc('month', o.order_date)::date AS month, sum(l.net_amount) AS revenue
    FROM public.clean_orders o
    JOIN public.clean_order_lines l ON l.order_id = o.order_id
    WHERE o.status = 'delivered'
    GROUP BY 1
), months AS (
    SELECT generate_series(date_trunc('month', min(order_date))::timestamp,
                           date_trunc('month', max(order_date))::timestamp,
                           interval '1 month')::date AS month
    FROM public.clean_orders
), amounts AS (
    SELECT m.month, COALESCE(r.revenue, 0::numeric) AS recognized_revenue
    FROM months m LEFT JOIN monthly r USING (month)
), previous AS (
    SELECT *, lag(recognized_revenue) OVER (ORDER BY month) AS previous_revenue
    FROM amounts
)
SELECT month, recognized_revenue,
    round(100 * (recognized_revenue - previous_revenue) / NULLIF(previous_revenue, 0), 2) AS mom_growth_pct
FROM previous ORDER BY month;
