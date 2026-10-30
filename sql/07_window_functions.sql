/* ============================================================================
   7. WINDOW FUNCTIONS
   ============================================================================ */

USE shop;

-- 7a. Top 3 products per category by revenue  (RANK)
WITH product_revenue AS (
  SELECT l.category_id, l.product_id, SUM(l.net_revenue) AS revenue
  FROM v_sales_lines l
  GROUP BY l.category_id, l.product_id
), ranked AS (
  SELECT category_id, product_id, revenue,
         RANK() OVER (PARTITION BY category_id ORDER BY revenue DESC) AS rnk
  FROM product_revenue
)
SELECT c.name AS category, p.title, ROUND(r.revenue, 2) AS revenue, r.rnk
FROM ranked r
JOIN products   p ON p.product_id  = r.product_id
JOIN categories c ON c.category_id = r.category_id
WHERE r.rnk <= 3
ORDER BY c.name, r.rnk;
-- RANK() gives ties the same rank, so a category can return >3 rows. Use ROW_NUMBER()
-- for exactly 3, or DENSE_RANK() to avoid gaps after ties.

-- 7b. Month-over-month growth (LAG)
WITH monthly AS (
  SELECT order_month, SUM(net_revenue) AS revenue
  FROM v_sales_lines GROUP BY order_month
)
SELECT order_month,
       ROUND(revenue, 2) AS revenue,
       ROUND(LAG(revenue) OVER (ORDER BY order_month), 2) AS prev_month_revenue,
       ROUND(100 * (revenue - LAG(revenue) OVER (ORDER BY order_month))
             / NULLIF(LAG(revenue) OVER (ORDER BY order_month), 0), 1) AS mom_growth_pct
FROM monthly
ORDER BY order_month;

-- 7c. 3-month moving average of revenue
-- ROWS counts physical rows, so it is only correct when no month is missing.
-- Our data has every month; for gappy data use RANGE BETWEEN INTERVAL 2 MONTH PRECEDING AND CURRENT ROW.
WITH monthly AS (
  SELECT order_month, SUM(net_revenue) AS revenue
  FROM v_sales_lines GROUP BY order_month
)
SELECT order_month,
       ROUND(revenue, 2) AS revenue,
       ROUND(AVG(revenue) OVER w, 2) AS moving_avg_3m,
       COUNT(*)           OVER w     AS months_in_window      -- 1,2 = warm-up; 3 = full window
FROM monthly
WINDOW w AS (ORDER BY order_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
ORDER BY order_month;

-- 7d. First-purchase cohort per customer (MIN OVER PARTITION BY)
SELECT DISTINCT customer_id,
       MIN(order_date) OVER (PARTITION BY customer_id)                      AS first_purchase_date,
       DATE_FORMAT(MIN(order_date) OVER (PARTITION BY customer_id), '%Y-%m') AS cohort
FROM orders
WHERE status <> 'cancelled'
ORDER BY customer_id
LIMIT 20;

-- 7e. Spending quartiles (NTILE) - quartile 1 = top spenders
WITH spend AS (
  SELECT customer_id, SUM(net_revenue) AS total_spend
  FROM v_sales_lines GROUP BY customer_id
), q AS (
  SELECT customer_id, total_spend,
         NTILE(4) OVER (ORDER BY total_spend DESC) AS spend_quartile
  FROM spend
)
SELECT spend_quartile,
       COUNT(*)                         AS customers,
       ROUND(MIN(total_spend), 2)       AS min_spend,
       ROUND(MAX(total_spend), 2)       AS max_spend,
       ROUND(AVG(total_spend), 2)       AS avg_spend,
       ROUND(100 * SUM(total_spend) / SUM(SUM(total_spend)) OVER (), 1) AS pct_of_revenue
FROM q
GROUP BY spend_quartile
ORDER BY spend_quartile;
