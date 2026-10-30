/* ============================================================================
   E-COMMERCE ANALYTICS PROJECT  (MySQL 8.0+)
   Sections
     1. Schema
     2. Sample data (synthetic, deterministic)
     3. Analytics: sales trends, top sellers, customer satisfaction
     4. Cohort analysis
     5. Indexing + EXPLAIN comparisons (incl. low-selectivity demo)
     6. Views, simulated materialized view, trade-offs
     7. Window-function showcase
   Run top to bottom. Sections 5-7 assume sections 1-2 have run.
   ============================================================================ */

DROP DATABASE IF EXISTS shop;
CREATE DATABASE shop CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE shop;

/* ============================================================================
   1. SCHEMA
   ============================================================================ */

CREATE TABLE categories (
  category_id  INT UNSIGNED NOT NULL AUTO_INCREMENT,
  name         VARCHAR(80)  NOT NULL,
  parent_id    INT UNSIGNED NULL,
  PRIMARY KEY (category_id),
  UNIQUE KEY uq_category_name (name),
  CONSTRAINT fk_categories_parent FOREIGN KEY (parent_id) REFERENCES categories (category_id)
) ENGINE=InnoDB;

CREATE TABLE sellers (
  seller_id  INT UNSIGNED NOT NULL AUTO_INCREMENT,
  name       VARCHAR(120) NOT NULL,
  email      VARCHAR(255) NOT NULL,
  country    CHAR(2)      NOT NULL,
  status     ENUM('active','suspended','closed') NOT NULL DEFAULT 'active',
  joined_at  DATE         NOT NULL,
  PRIMARY KEY (seller_id),
  UNIQUE KEY uq_seller_email (email)
) ENGINE=InnoDB;

CREATE TABLE customers (
  customer_id  INT UNSIGNED NOT NULL AUTO_INCREMENT,
  name         VARCHAR(120) NOT NULL,
  email        VARCHAR(255) NOT NULL,
  country      CHAR(2)      NOT NULL,
  signup_date  DATE         NOT NULL,
  PRIMARY KEY (customer_id),
  UNIQUE KEY uq_customer_email (email)
) ENGINE=InnoDB;

CREATE TABLE products (
  product_id   INT UNSIGNED NOT NULL AUTO_INCREMENT,
  seller_id    INT UNSIGNED NOT NULL,
  category_id  INT UNSIGNED NOT NULL,
  title        VARCHAR(200) NOT NULL,
  description  TEXT         NOT NULL,
  price        DECIMAL(10,2) NOT NULL CHECK (price >= 0),
  stock        INT UNSIGNED NOT NULL DEFAULT 0,
  is_active    TINYINT(1)   NOT NULL DEFAULT 1,
  created_at   DATE         NOT NULL,
  PRIMARY KEY (product_id),
  CONSTRAINT fk_products_seller   FOREIGN KEY (seller_id)   REFERENCES sellers (seller_id),
  CONSTRAINT fk_products_category FOREIGN KEY (category_id) REFERENCES categories (category_id)
) ENGINE=InnoDB;

CREATE TABLE orders (
  order_id      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  customer_id   INT UNSIGNED NOT NULL,
  order_date    DATE         NOT NULL,
  status        ENUM('placed','shipped','delivered','returned','cancelled') NOT NULL,
  total_amount  DECIMAL(12,2) NOT NULL DEFAULT 0,
  PRIMARY KEY (order_id),
  CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES customers (customer_id)
) ENGINE=InnoDB;

CREATE TABLE order_items (
  order_item_id  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_id       BIGINT UNSIGNED NOT NULL,
  product_id     INT UNSIGNED NOT NULL,
  seller_id      INT UNSIGNED NOT NULL,          -- denormalised: seller at time of sale
  quantity       INT UNSIGNED NOT NULL CHECK (quantity > 0),
  unit_price     DECIMAL(10,2) NOT NULL,         -- price at time of sale
  returned       TINYINT(1)   NOT NULL DEFAULT 0,
  PRIMARY KEY (order_item_id),
  CONSTRAINT fk_items_order   FOREIGN KEY (order_id)   REFERENCES orders (order_id),
  CONSTRAINT fk_items_product FOREIGN KEY (product_id) REFERENCES products (product_id),
  CONSTRAINT fk_items_seller  FOREIGN KEY (seller_id)  REFERENCES sellers (seller_id)
) ENGINE=InnoDB;

CREATE TABLE reviews (
  review_id    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  product_id   INT UNSIGNED NOT NULL,
  customer_id  INT UNSIGNED NOT NULL,
  rating       TINYINT UNSIGNED NOT NULL CHECK (rating BETWEEN 1 AND 5),
  title        VARCHAR(150) NULL,
  body         TEXT NULL,
  created_at   DATE NOT NULL,
  PRIMARY KEY (review_id),
  UNIQUE KEY uq_review_once (product_id, customer_id),   -- one review per customer per product
  CONSTRAINT fk_reviews_product  FOREIGN KEY (product_id)  REFERENCES products (product_id),
  CONSTRAINT fk_reviews_customer FOREIGN KEY (customer_id) REFERENCES customers (customer_id)
) ENGINE=InnoDB;

/* ============================================================================
   2. SAMPLE DATA  (deterministic pseudo-random; no RAND(), so reruns match)
   ============================================================================ */

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

/* ============================================================================
   3. ANALYTICS
   ============================================================================ */

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

/* ============================================================================
   4. COHORT ANALYSIS
   Cohort = month of a customer's first non-cancelled purchase.
   ============================================================================ */

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

/* ============================================================================
   5. INDEXING + EXPLAIN
   Reminder: the FK on orders.customer_id / products.category_id already created
   single-column indexes named fk_orders_customer / fk_products_category.
   "BEFORE" plans ignore them to simulate a table with no useful index.
   ============================================================================ */

-- ---- 5a. orders (customer_id, order_date) -----------------------------------
-- BEFORE: no usable index -> full table scan (type=ALL, rows ~ 50,000)
EXPLAIN
SELECT order_id, order_date, total_amount
FROM orders IGNORE INDEX (fk_orders_customer)
WHERE customer_id = 1234 AND order_date BETWEEN '2024-01-01' AND '2024-06-30'
ORDER BY order_date;

-- Equality column first, range/sort column second.
CREATE INDEX idx_orders_customer_date ON orders (customer_id, order_date);

-- AFTER: type=range, key=idx_orders_customer_date, rows ~ a handful,
-- and NO "Using filesort" because the index is already ordered by order_date.
EXPLAIN
SELECT order_id, order_date, total_amount
FROM orders
WHERE customer_id = 1234 AND order_date BETWEEN '2024-01-01' AND '2024-06-30'
ORDER BY order_date;

-- Actual runtime, without vs with the index (read "actual time" in each plan; MySQL 8.0.18+)
EXPLAIN ANALYZE
SELECT order_id, order_date, total_amount
FROM orders IGNORE INDEX (idx_orders_customer_date)
WHERE customer_id = 1234 AND order_date BETWEEN '2024-01-01' AND '2024-06-30'
ORDER BY order_date;

EXPLAIN ANALYZE
SELECT order_id, order_date, total_amount
FROM orders
WHERE customer_id = 1234 AND order_date BETWEEN '2024-01-01' AND '2024-06-30'
ORDER BY order_date;

-- The composite's left prefix (customer_id) can also serve the foreign key, so MySQL silently
-- drops the old single-column FK index when the composite is created. Verify:
SHOW INDEX FROM orders;

-- ---- 5b. products (category_id, price) --------------------------------------
EXPLAIN
SELECT product_id, title, price
FROM products IGNORE INDEX (fk_products_category)
WHERE category_id = 3 AND price BETWEEN 20 AND 50
ORDER BY price;                                  -- type=ALL + Using filesort

CREATE INDEX idx_products_category_price ON products (category_id, price);

EXPLAIN
SELECT product_id, title, price
FROM products
WHERE category_id = 3 AND price BETWEEN 20 AND 50
ORDER BY price;                                  -- type=range, no filesort

EXPLAIN ANALYZE
SELECT product_id, title, price
FROM products IGNORE INDEX (idx_products_category_price)
WHERE category_id = 3 AND price BETWEEN 20 AND 50
ORDER BY price;

EXPLAIN ANALYZE
SELECT product_id, title, price
FROM products
WHERE category_id = 3 AND price BETWEEN 20 AND 50
ORDER BY price;

-- ---- 5c. FULLTEXT on title + description ------------------------------------
-- BEFORE: leading-wildcard LIKE can never use a B-tree index -> full scan
EXPLAIN
SELECT product_id, title FROM products
WHERE title LIKE '%wireless%' OR description LIKE '%wireless%';

ALTER TABLE products ADD FULLTEXT INDEX ft_products_title_desc (title, description);

-- AFTER: type=fulltext, key=ft_products_title_desc
EXPLAIN
SELECT product_id, title
FROM products
WHERE MATCH(title, description) AGAINST ('wireless headphones' IN NATURAL LANGUAGE MODE);

-- Ranked search with relevance score; BOOLEAN MODE: + required, - excluded, * prefix
SELECT product_id, title,
       MATCH(title, description) AGAINST ('wireless headphones' IN NATURAL LANGUAGE MODE) AS relevance
FROM products
WHERE MATCH(title, description) AGAINST ('+wireless -backpack ergonom*' IN BOOLEAN MODE)
ORDER BY relevance DESC
LIMIT 10;
-- Caveats: InnoDB ignores words shorter than 3 chars (innodb_ft_min_token_size) and stopwords;
-- new rows become searchable at commit; LIKE is still needed for substring matches.

-- ---- 5d. Why an index on a low-selectivity column barely helps ----------------
-- Selectivity = distinct values / rows. For status it is ~ 4/50000 = 0.0001.
SELECT COUNT(DISTINCT status) / COUNT(*) AS selectivity FROM orders;
SELECT status, COUNT(*) AS cnt, ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM orders GROUP BY status;                     -- delivered ~70%, cancelled ~4%

CREATE INDEX idx_orders_status ON orders (status);
ANALYZE TABLE orders;

-- 70% of the table. MySQL may still pick the index here (its row estimate is rough), but that
-- does not make it a good plan - compare the ACTUAL times below.
EXPLAIN SELECT order_id, total_amount FROM orders WHERE status = 'delivered';

-- Same query, once without the index (full scan) and once forcing it (MySQL 8.0.18+).
-- The index path does ~35k random lookups into the clustered index (total_amount is not in the
-- index), so it is typically SLOWER than one sequential scan. Check "actual time" in each plan.
EXPLAIN ANALYZE SELECT order_id, total_amount FROM orders IGNORE INDEX (idx_orders_status)
WHERE status = 'delivered';
EXPLAIN ANALYZE SELECT order_id, total_amount FROM orders FORCE  INDEX (idx_orders_status)
WHERE status = 'delivered';

-- ~4% of the table: now the index is worth using.
EXPLAIN SELECT order_id, total_amount FROM orders WHERE status = 'cancelled';

-- Takeaways: (1) an index pays off when it narrows to a small fraction of rows (rule of
-- thumb < ~10-20%); the optimizer's estimate can be wrong, so verify with EXPLAIN ANALYZE; (2) low-selectivity columns are useful only as the *trailing/leading
-- part of a composite* (e.g. (status, order_date)) or when queries target the rare values;
-- (3) every extra index slows INSERT/UPDATE and uses space.
DROP INDEX idx_orders_status ON orders;

/* ============================================================================
   6. VIEWS, SIMULATED MATERIALIZED VIEW
   ============================================================================ */

-- 6a. Seller performance
CREATE OR REPLACE VIEW v_seller_performance AS
SELECT s.seller_id, s.name AS seller_name,
       COALESCE(sa.total_sales, 0)        AS total_sales,       -- net of returns, excl. cancelled
       COALESCE(sa.units_sold, 0)         AS units_sold,
       rv.avg_rating,
       COALESCE(rv.review_count, 0)       AS review_count,
       COALESCE(sa.return_rate_pct, 0)    AS return_rate_pct
FROM sellers s
LEFT JOIN (
    SELECT seller_id,
           SUM(net_revenue)           AS total_sales,
           SUM(quantity)              AS units_sold,
           ROUND(100 * AVG(returned), 2) AS return_rate_pct
    FROM v_sales_lines
    GROUP BY seller_id
) sa ON sa.seller_id = s.seller_id
LEFT JOIN (                                   -- separate subquery avoids join fan-out
    SELECT p.seller_id, ROUND(AVG(r.rating), 2) AS avg_rating, COUNT(*) AS review_count
    FROM reviews r JOIN products p ON p.product_id = r.product_id
    GROUP BY p.seller_id
) rv ON rv.seller_id = s.seller_id;

SELECT * FROM v_seller_performance ORDER BY total_sales DESC LIMIT 10;

-- 6b. Customer lifetime value
CREATE OR REPLACE VIEW v_customer_ltv AS
SELECT c.customer_id, c.name, c.signup_date,
       COUNT(DISTINCT l.order_id)                                      AS orders_count,
       MIN(l.order_date)                                               AS first_order_date,
       MAX(l.order_date)                                               AS last_order_date,
       DATEDIFF(MAX(l.order_date), MIN(l.order_date))                  AS active_days,
       COALESCE(SUM(l.net_revenue), 0)                                 AS lifetime_value,
       ROUND(COALESCE(SUM(l.net_revenue) / NULLIF(COUNT(DISTINCT l.order_id), 0), 0), 2) AS avg_order_value,
       ROUND(100 * COALESCE(AVG(l.returned), 0), 2)                    AS return_rate_pct
FROM customers c
LEFT JOIN v_sales_lines l ON l.customer_id = c.customer_id
GROUP BY c.customer_id, c.name, c.signup_date;

SELECT * FROM v_customer_ltv ORDER BY lifetime_value DESC LIMIT 10;

-- 6c. Simulated materialized view: summary table + refresh procedure + scheduled event
CREATE TABLE seller_performance_summary (
  seller_id        INT UNSIGNED NOT NULL PRIMARY KEY,
  seller_name      VARCHAR(120) NOT NULL,
  total_sales      DECIMAL(14,2) NOT NULL,
  units_sold       BIGINT NOT NULL,
  avg_rating       DECIMAL(4,2) NULL,
  review_count     INT NOT NULL,
  return_rate_pct  DECIMAL(5,2) NOT NULL,
  refreshed_at     DATETIME NOT NULL,
  KEY idx_summary_sales (total_sales)
) ENGINE=InnoDB;

DELIMITER $$
CREATE PROCEDURE sp_refresh_seller_performance()
BEGIN
  -- Build off to the side, then swap with one atomic RENAME so readers never
  -- see an empty or half-filled table (TRUNCATE + INSERT would expose that gap).
  DROP TABLE IF EXISTS seller_performance_new;
  DROP TABLE IF EXISTS seller_performance_old;
  CREATE TABLE seller_performance_new LIKE seller_performance_summary;

  INSERT INTO seller_performance_new
    (seller_id, seller_name, total_sales, units_sold, avg_rating, review_count, return_rate_pct, refreshed_at)
  SELECT seller_id, seller_name, total_sales, units_sold, avg_rating, review_count, return_rate_pct, NOW()
  FROM v_seller_performance;

  RENAME TABLE seller_performance_summary TO seller_performance_old,
               seller_performance_new     TO seller_performance_summary;
  DROP TABLE seller_performance_old;
END$$
DELIMITER ;

CALL sp_refresh_seller_performance();

-- Needs the scheduler on (SET GLOBAL requires privileges; also set in my.cnf to persist)
SET GLOBAL event_scheduler = ON;
CREATE EVENT IF NOT EXISTS ev_refresh_seller_performance
  ON SCHEDULE EVERY 1 HOUR STARTS CURRENT_TIMESTAMP
  DO CALL sp_refresh_seller_performance();

-- Compare: the view recomputes from 100k lines every call; the summary just reads ~50 stored rows.
ANALYZE TABLE seller_performance_summary;
EXPLAIN SELECT * FROM v_seller_performance        ORDER BY total_sales DESC LIMIT 10;
EXPLAIN SELECT * FROM seller_performance_summary  ORDER BY total_sales DESC LIMIT 10;

/* VIEW vs SUMMARY TABLE
   +---------------------+--------------------------------------+---------------------------------------+
   |                     | View                                 | Summary table (simulated mat. view)   |
   +---------------------+--------------------------------------+---------------------------------------+
   | Freshness           | Always current                       | Stale until next refresh              |
   | Read cost           | Re-runs joins/aggregates every query | Cheap point/range read, indexable     |
   | Write cost          | None                                 | Refresh job load (full or incremental)|
   | Storage             | None                                 | Duplicates aggregated data            |
   | Indexing            | Only via underlying tables           | Index exactly what dashboards filter  |
   | Complexity          | Trivial, no maintenance              | Needs refresh logic, monitoring, swap |
   +---------------------+--------------------------------------+---------------------------------------+
   Use a view for small data, ad-hoc analysis, or when correctness-now matters.
   Use a summary table for heavy aggregations read often where "as of an hour ago" is acceptable.
   MySQL has no native materialized views. For big tables, refresh incrementally (only recent
   months) instead of rebuilding everything. */

/* ============================================================================
   7. WINDOW FUNCTIONS
   ============================================================================ */

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
