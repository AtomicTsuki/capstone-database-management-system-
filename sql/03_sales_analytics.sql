/* ============================================================================
   3. ANALYTICS
   ============================================================================ */

USE shop;

-- 3a. Monthly sales trend
SELECT order_month,
       COUNT(DISTINCT order_id)                                   AS orders,
       SUM(quantity)                                              AS units,
       ROUND(SUM(net_revenue), 2)                                 AS net_revenue,
       ROUND(SUM(net_revenue) / COUNT(DISTINCT order_id), 2)      AS revenue_per_order
FROM v_sales_lines
GROUP BY order_month
ORDER BY order_month;

-- 3b. Top 10 products by net revenue
SELECT p.product_id, p.title, c.name AS category,
       SUM(l.quantity)               AS units_sold,
       ROUND(SUM(l.net_revenue), 2)  AS net_revenue,
       ROUND(100 * AVG(l.returned), 1) AS return_rate_pct
FROM v_sales_lines l
JOIN products   p ON p.product_id  = l.product_id
JOIN categories c ON c.category_id = p.category_id
GROUP BY p.product_id, p.title, c.name
ORDER BY net_revenue DESC
LIMIT 10;

-- 3c. Customer satisfaction per product
--   positive% = share of 4-5 stars, negative% = share of 1-2 stars
--   satisfaction_index = positive% - negative%   (NPS-style, range -100..100)
--   bayes_rating shrinks products with few reviews toward the global mean
--   (m = 10 pseudo-reviews), so one lucky 5-star review can't top the chart.
SELECT p.product_id, p.title,
       COUNT(*)                                             AS review_count,
       ROUND(AVG(r.rating), 2)                              AS avg_rating,
       ROUND(100 * AVG(r.rating >= 4), 1)                   AS positive_pct,
       ROUND(100 * AVG(r.rating <= 2), 1)                   AS negative_pct,
       ROUND(100 * (AVG(r.rating >= 4) - AVG(r.rating <= 2)), 1) AS satisfaction_index,
       ROUND((COUNT(*) / (COUNT(*) + 10)) * AVG(r.rating)
             + (10 / (COUNT(*) + 10)) * g.global_avg, 2)    AS bayes_rating
FROM reviews r
JOIN products p ON p.product_id = r.product_id
CROSS JOIN (SELECT AVG(rating) AS global_avg FROM reviews) g
GROUP BY p.product_id, p.title, g.global_avg
HAVING COUNT(*) >= 3
ORDER BY bayes_rating DESC
LIMIT 15;

-- 3d. Satisfaction by category
SELECT c.name AS category,
       COUNT(*) AS reviews,
       ROUND(AVG(r.rating), 2) AS avg_rating,
       ROUND(100 * AVG(r.rating >= 4), 1) AS positive_pct
FROM reviews r
JOIN products p   ON p.product_id  = r.product_id
JOIN categories c ON c.category_id = p.category_id
GROUP BY c.name
ORDER BY avg_rating DESC;
