/* ============================================================================
   2. SAMPLE DATA  (deterministic pseudo-random; no RAND(), so reruns match)
   ============================================================================ */

USE shop;

-- helper number sequence 1..100000
CREATE TABLE seq (n INT UNSIGNED PRIMARY KEY);
SET SESSION cte_max_recursion_depth = 100000;
INSERT INTO seq
WITH RECURSIVE g (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM g WHERE n < 100000)
SELECT n FROM g;

INSERT INTO categories (name) VALUES
 ('Electronics'),('Home & Kitchen'),('Sports'),('Books'),
 ('Beauty'),('Toys'),('Fashion'),('Garden');

INSERT INTO sellers (name, email, country, joined_at)
SELECT CONCAT('Seller ', n), CONCAT('seller', n, '@example.com'),
       ELT(1 + MOD(n, 4), 'IN', 'US', 'GB', 'DE'),
       DATE_ADD('2022-01-01', INTERVAL MOD(n * 11, 300) DAY)
FROM seq WHERE n <= 50;

-- Deterministic pseudo-random number in [0,1): same inputs always give the same output,
-- so every rerun produces identical data (RAND(seed) is NOT used: sequential seeds correlate).
CREATE FUNCTION rnd(salt VARCHAR(16), n BIGINT) RETURNS DOUBLE DETERMINISTIC NO SQL
  RETURN CONV(SUBSTRING(MD5(CONCAT(salt, ':', n)), 1, 8), 16, 10) / 4294967296;

INSERT INTO customers (name, email, country, signup_date)
SELECT CONCAT('Customer ', n), CONCAT('customer', n, '@example.com'),
       ELT(1 + MOD(n, 4), 'IN', 'US', 'GB', 'DE'),
       DATE_ADD('2023-01-01', INTERVAL FLOOR(rnd('su', n) * 700) DAY)
FROM seq WHERE n <= 5000;

INSERT INTO products (seller_id, category_id, title, description, price, stock, created_at)
SELECT 1 + FLOOR(50 * POW(rnd('ps', n), 1.4)),            -- some sellers are bigger than others
       1 + MOD(n, 8),
       CONCAT(ELT(1 + MOD(n, 6), 'Wireless','Ergonomic','Stainless','Portable','Organic','Premium'), ' ',
              ELT(1 + MOD(n DIV 6, 6), 'Headphones','Keyboard','Bottle','Speaker','Lamp','Backpack'),
              ' ', n),
       CONCAT('A ', ELT(1 + MOD(n, 6), 'wireless','ergonomic','stainless','portable','organic','premium'),
              ' item designed for everyday use. ',
              ELT(1 + MOD(n, 4), 'Lightweight and durable.', 'Comes with a two-year warranty.',
                                 'Eco-friendly packaging.', 'Best seller in its class.')),
       ROUND(5 + 495 * POW(rnd('pp', n), 2), 2),           -- many cheap items, few expensive
       FLOOR(rnd('sk', n) * 500),
       DATE_ADD('2022-06-01', INTERVAL FLOOR(rnd('pc', n) * 200) DAY)
FROM seq WHERE n <= 2000;

-- 50,000 orders.
--  * customer picked with a mild skew (some heavy buyers, many light ones)
--  * order date = signup date + exponential delay (mean ~120 days) -> retention decays over time
--  * status: 70% delivered / 15% shipped / 10% returned / 5% cancelled -> LOW-SELECTIVITY column
INSERT INTO orders (customer_id, order_date, status)
SELECT c.customer_id,
       DATE_ADD(c.signup_date, INTERVAL LEAST(600, FLOOR(-LN(1 - rnd('od', s.n)) * 120)) DAY),
       CASE WHEN rnd('st', s.n) < 0.70 THEN 'delivered'
            WHEN rnd('st', s.n) < 0.85 THEN 'shipped'
            WHEN rnd('st', s.n) < 0.95 THEN 'returned'
            ELSE 'cancelled' END
FROM seq s
JOIN customers c ON c.customer_id = 1 + FLOOR(5000 * POW(rnd('cu', s.n), 1.25))
WHERE s.n <= 50000
ORDER BY s.n;

-- 100,000 line items (2 per order). Popular products get more sales (skew toward low ids).
-- In "returned" orders, each item is returned with a seller-dependent probability (30%-100%).
INSERT INTO order_items (order_id, product_id, seller_id, quantity, unit_price, returned)
SELECT o.order_id, p.product_id, p.seller_id, 1 + FLOOR(3 * rnd('qt', s.n)), p.price,
       (o.status = 'returned' AND rnd('rt', s.n) < LEAST(1, 0.3 + p.seller_id / 60))
FROM seq s
JOIN orders   o ON o.order_id   = 1 + MOD(s.n - 1, 50000)
JOIN products p ON p.product_id = 1 + FLOOR(2000 * POW(rnd('pr', s.n), 1.5))
WHERE s.n <= 100000
ORDER BY s.n;

UPDATE orders o
JOIN (SELECT order_id, SUM(quantity * unit_price) AS t FROM order_items GROUP BY order_id) x
  ON x.order_id = o.order_id
SET o.total_amount = x.t;

-- ~10,000 review attempts (duplicates of the same customer+product are skipped by IGNORE).
-- Each product has a built-in "quality" so some products really are better rated than others.
INSERT IGNORE INTO reviews (product_id, customer_id, rating, title, body, created_at)
SELECT t.pid, t.cid,
       GREATEST(1, LEAST(5, ROUND(2.2 + 2.6 * (MOD(t.pid * 7, 10) / 9) + (rnd('rr', t.n) - 0.5) * 2.4))),
       CONCAT('Review ', t.n),
       'Sample review text.',
       DATE_ADD('2023-03-01', INTERVAL FLOOR(rnd('rd', t.n) * 900) DAY)
FROM (SELECT n,
             1 + FLOOR(2000 * POW(rnd('rp', n), 1.3)) AS pid,
             1 + FLOOR(5000 * rnd('rc', n))           AS cid
      FROM seq WHERE n <= 10000) t;

ANALYZE TABLE categories, sellers, customers, products, orders, order_items, reviews;

/* Base view reused everywhere: one row per sold line, cancelled orders excluded.
   net_revenue = 0 for returned lines. */
CREATE OR REPLACE VIEW v_sales_lines AS
SELECT oi.order_item_id, o.order_id, o.customer_id, o.order_date,
       DATE_SUB(o.order_date, INTERVAL DAYOFMONTH(o.order_date) - 1 DAY) AS order_month,
       oi.product_id, p.category_id, oi.seller_id, oi.quantity,
       oi.quantity * oi.unit_price                         AS gross_revenue,
       IF(oi.returned = 1, 0, oi.quantity * oi.unit_price) AS net_revenue,
       oi.returned
FROM order_items oi
JOIN orders   o ON o.order_id   = oi.order_id
JOIN products p ON p.product_id = oi.product_id
WHERE o.status <> 'cancelled';
