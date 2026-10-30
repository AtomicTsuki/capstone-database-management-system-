/* ============================================================================
   4. COHORT ANALYSIS
   Cohort = month of a customer's first non-cancelled purchase.
   ============================================================================ */

USE shop;

CREATE OR REPLACE VIEW v_customer_cohort_activity AS
SELECT customer_id, order_month, cohort_month,
       TIMESTAMPDIFF(MONTH, cohort_month, order_month) AS month_offset,
       revenue
FROM (
  SELECT customer_id, order_month, revenue,
         MIN(order_month) OVER (PARTITION BY customer_id) AS cohort_month
  FROM (
    SELECT customer_id, order_month, SUM(net_revenue) AS revenue
    FROM v_sales_lines
    GROUP BY customer_id, order_month
  ) m
) x;

-- 4a. Retention matrix (long form): % of cohort still buying N months later
SELECT cohort_month, month_offset, active_customers,
       ROUND(100 * active_customers /
             FIRST_VALUE(active_customers) OVER (PARTITION BY cohort_month ORDER BY month_offset), 1)
         AS retention_pct
FROM (
  SELECT cohort_month, month_offset, COUNT(*) AS active_customers
  FROM v_customer_cohort_activity
  GROUP BY cohort_month, month_offset
) r
ORDER BY cohort_month, month_offset;

-- 4b. Retention matrix (pivoted, first 6 months) - ready for a heatmap
SELECT cohort_month,
       MAX(CASE WHEN month_offset = 0 THEN active END) AS cohort_size,
       ROUND(100 * MAX(CASE WHEN month_offset = 1 THEN active END) / MAX(CASE WHEN month_offset = 0 THEN active END), 1) AS m1,
       ROUND(100 * MAX(CASE WHEN month_offset = 2 THEN active END) / MAX(CASE WHEN month_offset = 0 THEN active END), 1) AS m2,
       ROUND(100 * MAX(CASE WHEN month_offset = 3 THEN active END) / MAX(CASE WHEN month_offset = 0 THEN active END), 1) AS m3,
       ROUND(100 * MAX(CASE WHEN month_offset = 4 THEN active END) / MAX(CASE WHEN month_offset = 0 THEN active END), 1) AS m4,
       ROUND(100 * MAX(CASE WHEN month_offset = 5 THEN active END) / MAX(CASE WHEN month_offset = 0 THEN active END), 1) AS m5,
       ROUND(100 * MAX(CASE WHEN month_offset = 6 THEN active END) / MAX(CASE WHEN month_offset = 0 THEN active END), 1) AS m6
FROM (
  SELECT cohort_month, month_offset, COUNT(*) AS active
  FROM v_customer_cohort_activity
  GROUP BY cohort_month, month_offset
) t
GROUP BY cohort_month
ORDER BY cohort_month;

-- 4c. Cumulative revenue per customer by cohort age (how fast does a cohort pay back?)
WITH sizes AS (
  SELECT cohort_month, COUNT(*) AS cohort_size
  FROM v_customer_cohort_activity WHERE month_offset = 0 GROUP BY cohort_month
), rev AS (
  SELECT cohort_month, month_offset, SUM(revenue) AS revenue
  FROM v_customer_cohort_activity GROUP BY cohort_month, month_offset
)
SELECT r.cohort_month, r.month_offset,
       ROUND(SUM(r.revenue) OVER (PARTITION BY r.cohort_month ORDER BY r.month_offset) / s.cohort_size, 2)
         AS cumulative_revenue_per_customer
FROM rev r JOIN sizes s USING (cohort_month)
ORDER BY r.cohort_month, r.month_offset;

-- 4d. Days from first to second order, by cohort (is a re-engagement nudge needed?)
WITH ranked AS (
  SELECT customer_id, order_date,
         DATE_SUB(MIN(order_date) OVER (PARTITION BY customer_id),
                  INTERVAL DAYOFMONTH(MIN(order_date) OVER (PARTITION BY customer_id)) - 1 DAY) AS cohort_month,
         ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date, order_id) AS rn,
         LAG(order_date) OVER (PARTITION BY customer_id ORDER BY order_date, order_id) AS prev_date
  FROM orders WHERE status <> 'cancelled'
)
SELECT cohort_month,
       COUNT(*)                                  AS repeat_buyers,
       ROUND(AVG(DATEDIFF(order_date, prev_date)), 1) AS avg_days_to_second_order
FROM ranked WHERE rn = 2
GROUP BY cohort_month
ORDER BY cohort_month;

/* Marketing reading guide
   - Steep drop at m1 -> fix onboarding / send a 2nd-purchase offer in days 7-21.
   - Cohorts with higher m3 retention -> find what acquisition channel/campaign they came from, buy more of it.
   - Cumulative revenue per customer flattening -> time win-back campaigns near the flattening month.
   - 4d tells you *when* to nudge: target roughly the average gap, before it lapses. */
