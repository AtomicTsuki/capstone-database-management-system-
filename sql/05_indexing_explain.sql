/* ============================================================================
   5. INDEXING + EXPLAIN
   Reminder: the FK on orders.customer_id / products.category_id already created
   single-column indexes named fk_orders_customer / fk_products_category.
   "BEFORE" plans ignore them to simulate a table with no useful index.
   ============================================================================ */

USE shop;

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
