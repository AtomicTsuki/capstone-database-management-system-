/* ============================================================================
   6. VIEWS, SIMULATED MATERIALIZED VIEW
   ============================================================================ */

USE shop;

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
