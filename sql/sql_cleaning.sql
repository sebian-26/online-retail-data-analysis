USE online_retail;

DROP TABLE IF EXISTS raw_all;
CREATE TABLE raw_all (
  id            INT AUTO_INCREMENT PRIMARY KEY,
  source_sheet  TINYINT       NOT NULL,   
  source_row    INT           NOT NULL,  
  invoice       VARCHAR(20)   NULL,
  stock_code    VARCHAR(50)   NULL,
  description   VARCHAR(500)  NULL,
  quantity      INT           NULL,
  invoice_date  DATETIME      NULL,
  price         DECIMAL(12,3) NULL,
  customer_id   INT UNSIGNED  NULL,
  country       VARCHAR(100)  NULL
);
 
INSERT INTO raw_all
  (source_sheet, source_row, invoice, stock_code, description, quantity,
   invoice_date, price, customer_id, country)
SELECT
  u.source_sheet,
  u.source_row,
  NULLIF(TRIM(u.invoice), ''),
  NULLIF(TRIM(u.stock_code), ''),
  NULLIF(TRIM(u.description), ''),
  CAST(NULLIF(TRIM(u.quantity), '') AS SIGNED),
  -- format dd/mm/yyyy hh:mm (e.g. 01/12/2009 07:45)
  STR_TO_DATE(NULLIF(TRIM(u.invoice_date), ''), '%d/%m/%Y %H:%i'),
  CAST(NULLIF(REPLACE(TRIM(u.price), ',', '.'), '') AS DECIMAL(12,3)),
  CAST(NULLIF(SUBSTRING_INDEX(TRIM(u.customer_id), '.', 1), '') AS UNSIGNED),
  NULLIF(TRIM(REPLACE(u.country, '\r', '')), '')
FROM (
  SELECT *, 1 AS source_sheet FROM raw_2009_2010 
  UNION ALL
  SELECT *, 2 AS source_sheet FROM raw_2010_2011 
) u;

SELECT (SELECT COUNT(*) FROM raw_all) AS rows_united,
       (SELECT COUNT(*) FROM raw_2009_2010) + (SELECT COUNT(*) FROM raw_2010_2011) AS rows_separated;
-- 1,067,371 both

-- --------------------------------------------------------------------------------------------------------------

SELECT
  SUM(invoice      IS NULL)    AS null_invoice,
  SUM(stock_code   IS NULL)    AS null_stock_code,
  SUM(description  IS NULL)    AS null_description,
  SUM(quantity     IS NULL)    AS null_quantity,
  SUM(invoice_date IS NULL)    AS null_invoice_date,
  SUM(price        IS NULL)    AS null_price,
  SUM(customer_id  IS NULL)    AS null_customer_id,
  SUM(country      IS NULL)    AS null_country,
  SUM(invoice IS NULL OR stock_code IS NULL OR description IS NULL
      OR quantity IS NULL OR invoice_date IS NULL OR price IS NULL
      OR customer_id IS NULL OR country IS NULL) AS rows_with_null
FROM raw_all;
--             descr.                         customer_id        rows_with_null
-- 0	0	4382	0	0	0	243007	   0	     243007

-- ---------------------------------------------------------------------------------------------------------------

SELECT COUNT(*) AS sheet1_rows_in_sheet2
FROM raw_all
WHERE source_sheet = 1
  AND invoice_date >= (SELECT MIN(invoice_date) FROM raw_all WHERE source_sheet = 2);
-- 22523

SET @start_sheet2 = (SELECT MIN(invoice_date) FROM raw_all WHERE source_sheet = 2);
SET @end_sheet1   = (SELECT MAX(invoice_date) FROM raw_all WHERE source_sheet = 1);
 
WITH f1 AS (
  SELECT * FROM raw_all
  WHERE source_sheet = 1 AND invoice_date >= @start_sheet2
),
f2 AS (
  SELECT * FROM raw_all
  WHERE source_sheet = 2 AND invoice_date <= @end_sheet1
)
SELECT
  (SELECT COUNT(*) FROM f1) AS common_sheet1_rows,
  (SELECT COUNT(*) FROM f2) AS common_sheet2_rows,
  (SELECT COUNT(*)
   FROM f1
   LEFT JOIN f2
     ON  f2.invoice      = f1.invoice
     AND f2.stock_code   = f1.stock_code
     AND COALESCE(f2.description, '') = COALESCE(f1.description, '')
     AND f2.quantity     = f1.quantity
     AND f2.invoice_date = f1.invoice_date
     AND f2.price        = f1.price
     AND COALESCE(f2.customer_id, 0) = COALESCE(f1.customer_id, 0)
     AND f2.country      = f1.country
   WHERE f2.id IS NULL)     AS different_common_rows;
-- different_common_rows : 0

-- ---------------------------------------------------------------------------------------------------------------

DROP TABLE IF EXISTS cleaning_log;
CREATE TABLE cleaning_log (
  step_no      INT PRIMARY KEY,
  step_name    VARCHAR(120) NOT NULL,
  rows_after   INT NOT NULL,
  rows_removed INT NOT NULL
);
 
INSERT INTO cleaning_log
SELECT 0, 'Data loading and union', COUNT(*), 0 FROM raw_all;

-- ----------------------------------------------------------------------------------------------------------------

SET @start_sheet2 = (SELECT MIN(invoice_date) FROM raw_all WHERE source_sheet = 2);
 
DROP TABLE IF EXISTS s1_no_overlap;
CREATE TABLE s1_no_overlap AS
SELECT * FROM raw_all
WHERE NOT (source_sheet = 1 AND invoice_date >= @start_sheet2);
 
INSERT INTO cleaning_log
SELECT 1, 'Removed intersection of two sheets',
       COUNT(*), (SELECT COUNT(*) FROM raw_all) - COUNT(*)
FROM s1_no_overlap;

-- -----------------------------------------------------------------------------------------------------------------

SELECT
  SUM(invoice     COLLATE utf8mb4_bin <> UPPER(invoice))     AS invoice_mod,
  SUM(stock_code  COLLATE utf8mb4_bin <> UPPER(stock_code))  AS stock_code_mod,
  SUM(description COLLATE utf8mb4_bin <> UPPER(description)) AS description_mod,
  SUM(country     COLLATE utf8mb4_bin <> UPPER(country))     AS country_mod
FROM s1_no_overlap;
-- '0', '3345', '5866', '1026455'
 
DROP TABLE IF EXISTS s2_uppercase;
CREATE TABLE s2_uppercase AS
SELECT
  id, source_sheet, source_row,
  UPPER(invoice)     AS invoice,
  UPPER(stock_code)  AS stock_code,
  UPPER(description) AS description,
  quantity, invoice_date, price, customer_id,
  UPPER(country)     AS country
FROM s1_no_overlap;
 
INSERT INTO cleaning_log
SELECT 2, 'Text to uppercase',
       COUNT(*), 0
FROM s2_uppercase;

-- ---------------------------------------------------------------------------------------------------------------------

DROP TABLE IF EXISTS s3_no_duplicates;
CREATE TABLE s3_no_duplicates (
  id            INT AUTO_INCREMENT PRIMARY KEY,
  source_sheet  TINYINT       NOT NULL,
  source_row    INT           NOT NULL,
  invoice       VARCHAR(20)   NOT NULL,
  stock_code    VARCHAR(50)   NOT NULL,
  description   VARCHAR(500)  NULL,
  quantity      INT           NOT NULL,
  invoice_date  DATETIME      NOT NULL,
  price         DECIMAL(12,3) NOT NULL,
  customer_id   INT UNSIGNED  NULL,
  country       VARCHAR(100)  NOT NULL
);
 
INSERT INTO s3_no_duplicates
  (source_sheet, source_row, invoice, stock_code, description, quantity,
   invoice_date, price, customer_id, country)
SELECT MIN(source_sheet), MIN(source_row), invoice, stock_code, description,
       quantity, invoice_date, price, customer_id, country
FROM s2_uppercase
GROUP BY invoice, stock_code, description, quantity, invoice_date, price,
         customer_id, country
ORDER BY invoice_date, MIN(source_row);
 
INSERT INTO cleaning_log
SELECT 3, 'Duplicates removed',
       COUNT(*), (SELECT rows_after FROM cleaning_log WHERE step_no = 2) - COUNT(*)
FROM s3_no_duplicates;

-- -----------------------------------------------------------------------------------------------

SELECT * FROM s3_no_duplicates WHERE price<0; 

SELECT * FROM s3_no_duplicates WHERE invoice LIKE 'A%'; 
-- 6 rows with A, all 5 negative prices are here

DROP TABLE IF EXISTS s4_valid_price;
CREATE TABLE s4_valid_price AS
SELECT * FROM s3_no_duplicates
WHERE price > 0 AND invoice NOT LIKE 'A%';
 
ALTER TABLE s4_valid_price
  ADD PRIMARY KEY (id),
  ADD INDEX idx_match (customer_id, stock_code, quantity, price, invoice_date);
  
INSERT INTO cleaning_log
SELECT 4, 'Removed rows with prices <= 0 or invoice like "A..."',
       COUNT(*), (SELECT rows_after FROM cleaning_log WHERE step_no = 3) - COUNT(*)
FROM s4_valid_price;

-- -------------------------------------------------------------------------------------------------

-- Quantity still available for each purchase (reduced by returns)
DROP TABLE IF EXISTS purchase_remaining;
CREATE TABLE purchase_remaining (
  id            INT PRIMARY KEY,
  customer_id   INT UNSIGNED,
  stock_code    VARCHAR(50),
  price         DECIMAL(12,3),
  invoice_date  DATETIME,
  qty_remaining INT NOT NULL,
  INDEX idx_match (customer_id, stock_code, price, invoice_date)
);
 
INSERT INTO purchase_remaining
SELECT id, customer_id, stock_code, price, invoice_date, quantity
FROM s4_valid_price
WHERE quantity > 0 AND invoice NOT LIKE 'C%'
  AND customer_id IS NOT NULL;      -- only known customers can have allocated returns
 
-- Each row: how much of a return was taken from which purchase
DROP TABLE IF EXISTS return_allocation;
CREATE TABLE return_allocation (
  return_id     INT NOT NULL,       -- return row
  purchase_id   INT NOT NULL,       -- purchase reduced
  qty_allocated INT NOT NULL,       -- quantity taken from that purchase
  PRIMARY KEY (return_id, purchase_id)
);
 
-- Outcome of each return: returned quantity and quantity actually allocated
DROP TABLE IF EXISTS return_result;
CREATE TABLE return_result (
  return_id     INT PRIMARY KEY,
  qty_returned  INT NOT NULL,
  qty_allocated INT NOT NULL
);
 
DROP PROCEDURE IF EXISTS allocate_returns;
DELIMITER //
CREATE PROCEDURE allocate_returns()
BEGIN
  DECLARE done      INT DEFAULT 0;
  DECLARE r_id      INT;
  DECLARE r_cust    INT UNSIGNED;
  DECLARE r_code    VARCHAR(50);
  DECLARE r_qty     INT;
  DECLARE r_price   DECIMAL(12,3);
  DECLARE r_date    DATETIME;
  DECLARE qty_left  INT;            -- quantity of the return still to allocate
  DECLARE p_id      INT;
  DECLARE p_qty     INT;
  DECLARE qty_taken INT;
 
  DECLARE cur CURSOR FOR
    -- ABS() always gives a positive quantity, even for C invoices with quantity > 0
    SELECT id, customer_id, stock_code, ABS(quantity), price, invoice_date
    FROM s4_valid_price
    WHERE (quantity < 0 OR invoice LIKE 'C%')
      AND customer_id IS NOT NULL
    ORDER BY invoice_date, id;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;
 
  -- A single transaction for the whole loop: much faster than writing
  -- every single UPDATE and INSERT to disk.
  START TRANSACTION;
  OPEN cur;
  returns_loop: LOOP
    FETCH cur INTO r_id, r_cust, r_code, r_qty, r_price, r_date;
    IF done = 1 THEN
      LEAVE returns_loop;
    END IF;
 
    SET qty_left = r_qty;
 
    -- Inner loop: consumes purchases, most recent first, until the
    -- return is covered or no purchases are left.
    purchases_loop: WHILE qty_left > 0 DO
      -- SET with a subquery (not SELECT ... INTO): when nothing is found
      -- it returns NULL without firing the NOT FOUND handler.
      SET p_id = (
        SELECT p.id
        FROM purchase_remaining p
        WHERE p.customer_id   = r_cust
          AND p.stock_code    = r_code
          AND p.price         = r_price
          AND p.invoice_date <= r_date      -- any day, but not after the return
          AND p.qty_remaining > 0
        ORDER BY p.invoice_date DESC, p.id DESC
        LIMIT 1
      );
 
      IF p_id IS NULL THEN
        LEAVE purchases_loop;               -- no purchase available
      END IF;
 
      SET p_qty     = (SELECT qty_remaining FROM purchase_remaining WHERE id = p_id);
      SET qty_taken = LEAST(qty_left, p_qty);
 
      -- The quantity goes through a session variable (@qty_taken): it
      -- works the same in MySQL and in other MySQL-compatible engines.
      SET @qty_taken = qty_taken;
      UPDATE purchase_remaining
      SET qty_remaining = qty_remaining - @qty_taken
      WHERE id = p_id;
 
      INSERT INTO return_allocation (return_id, purchase_id, qty_allocated)
      VALUES (r_id, p_id, qty_taken);
 
      SET qty_left = qty_left - qty_taken;
    END WHILE;
 
    INSERT INTO return_result (return_id, qty_returned, qty_allocated)
    VALUES (r_id, r_qty, r_qty - qty_left);
  END LOOP;
  CLOSE cur;
  COMMIT;
END //
DELIMITER ;
 
CALL allocate_returns();
 
-- Allocation summary (for the README)
-- Check: returns_total = returns_no_customer + fully_allocated
--                        + partially_allocated + not_allocated
SELECT
  (SELECT COUNT(*) FROM s4_valid_price
    WHERE quantity < 0 OR invoice LIKE 'C%')                        AS returns_total,
  (SELECT COUNT(*) FROM s4_valid_price
    WHERE invoice LIKE 'C%' AND quantity > 0)                       AS returns_c_positive_qty,
  (SELECT COUNT(*) FROM s4_valid_price
    WHERE (quantity < 0 OR invoice LIKE 'C%')
      AND customer_id IS NULL)                                      AS returns_no_customer,
  (SELECT COUNT(*) FROM return_result
    WHERE qty_allocated = qty_returned)                             AS returns_fully_allocated,
  (SELECT COUNT(*) FROM return_result
    WHERE qty_allocated > 0 AND qty_allocated < qty_returned)       AS returns_partially_allocated,
  (SELECT COUNT(*) FROM return_result
    WHERE qty_allocated = 0)                                        AS returns_not_allocated;
-- # returns_total, returns_c_positive_qty, returns_no_customer, returns_fully_allocated, returns_partially_allocated, returns_not_allocated
--      '19104',                '1',               '714',                 '15303',                 '121',                      '2966'

-- Returned units and units matched to a purchase.
-- All returns count, including those without a customer, which cannot be matched.
SELECT
  (SELECT SUM(ABS(quantity)) FROM s4_valid_price
    WHERE quantity < 0 OR invoice LIKE 'C%')                        AS units_returned,
  (SELECT SUM(qty_allocated) FROM return_result)                    AS units_matched,
  ROUND(100 * (SELECT SUM(qty_allocated) FROM return_result)
            / (SELECT SUM(ABS(quantity)) FROM s4_valid_price
                WHERE quantity < 0 OR invoice LIKE 'C%'), 1)        AS pct_matched;
-- # units_returned, units_matched, pct_matched
--      '476821',        '431953',      '90.6'

 
-- Effect on purchases
SELECT
  SUM(p.qty_remaining = 0)                                          AS purchases_fully_offset,
  SUM(p.qty_remaining > 0 AND p.qty_remaining < s.quantity)         AS purchases_reduced,
  SUM(s.quantity - p.qty_remaining)                                 AS quantity_offset,
  ROUND(SUM((s.quantity - p.qty_remaining) * s.price), 2)           AS value_offset
FROM purchase_remaining p
JOIN s4_valid_price s ON s.id = p.id;
-- # purchases_fully_offset, purchases_reduced, quantity_offset, value_offset
--          '6009',                '9124',          '431953',     '737818.36'

SELECT a.purchase_id, s.invoice, s.invoice_date, s.stock_code, s.description,
       s.customer_id, s.quantity AS original_qty, a.qty_allocated,
       ROUND(a.qty_allocated * s.price, 2) AS value_offset
FROM return_allocation a
JOIN s4_valid_price s ON s.id = a.purchase_id
ORDER BY value_offset DESC
LIMIT 10;
-- # purchase_id, invoice, invoice_date, stock_code, description, customer_id, original_qty, qty_allocated, value_offset
-- '1031555', '581483', '2011-12-09 09:15:00', '23843', 'PAPER CRAFT , LITTLE BIRDIE', '16446', '80995', '80995', '168469.60'
-- '557401', '541431', '2011-01-18 10:01:00', '23166', 'MEDIUM CERAMIC TOP STORAGE JAR', '12346', '74215', '74215', '77183.60'
-- '133500', '502263', '2010-03-23 15:22:00', 'M', 'MANUAL', '12918', '1', '1', '10953.50'

INSERT INTO cleaning_log
SELECT 5, 'Removed returns (negative quantity or C invoice)',
       COUNT(*), (SELECT rows_after FROM cleaning_log WHERE step_no = 4) - COUNT(*)
FROM s4_valid_price
WHERE quantity > 0 AND invoice NOT LIKE 'C%';

-- ----------------------------------------------------------------------------------------------------------------------------

DROP TABLE IF EXISTS s5_no_returns;
CREATE TABLE s5_no_returns AS
SELECT
  s.id, s.source_sheet, s.source_row, s.invoice, s.stock_code, s.description,
  COALESCE(p.qty_remaining, s.quantity) AS quantity,
  s.quantity                            AS original_quantity,
  s.invoice_date, s.price, s.customer_id
FROM s4_valid_price s
LEFT JOIN purchase_remaining p ON p.id = s.id   -- NULL for missing customers: quantity unchanged
WHERE s.quantity > 0
  AND s.invoice NOT LIKE 'C%'
  AND COALESCE(p.qty_remaining, s.quantity) > 0;
 
INSERT INTO cleaning_log
SELECT 6, 'Removed purchases fully offset by returns (others reduced)',
       COUNT(*), (SELECT rows_after FROM cleaning_log WHERE step_no = 5) - COUNT(*)
FROM s5_no_returns;

-- -------------------------------------------------------------------------------------------------------------------------------

SELECT stock_code,
       MIN(description) AS description,
       COUNT(*)         AS row_count,
       stock_code REGEXP '^[0-9]{5}'       AS product_rule_5_digits,
       stock_code NOT REGEXP '^[A-Z ]+$'   AS product_rule_letters_only
FROM s5_no_returns
GROUP BY stock_code
HAVING product_rule_5_digits <> product_rule_letters_only
ORDER BY row_count DESC;
-- # stock_code, description, row_count, product_rule_5_digits, product_rule_letters_only
-- 'C2', 'CARRIAGE', '262', '0', '1'
-- 'DCGS0058', 'MISO PRETTY  GUM', '30', '0', '1'
-- 'GIFT_0001_20', 'DOTCOMGIFTSHOP GIFT VOUCHER £20.00', '26', '0', '1'
-- 'TEST001', 'THIS IS A TEST PRODUCT.', '9', '0', '1'
-- 'ADJUST2', 'ADJUSTMENT BY PETER ON JUN 25 2010', '3', '0', '1'
-- 'SP1002', 'KID\'S CHALKBOARD/EASEL', '2', '0', '1'


SELECT stock_code,
       MIN(description)                 AS description,
       COUNT(*)                         AS row_count,
       ROUND(SUM(quantity * price), 2)  AS revenue,
       ROUND(MIN(price), 2)             AS min_price,
       ROUND(MAX(price), 2)             AS max_price,
       CASE WHEN stock_code REGEXP '^[A-Z ]+$' THEN 'letters only'
            ELSE 'explicit exception' END AS reason
FROM s5_no_returns
WHERE stock_code REGEXP '^[A-Z ]+$'
   OR stock_code = 'C2'
   OR stock_code LIKE 'TEST%'
   OR stock_code LIKE 'ADJUST%'
GROUP BY stock_code
ORDER BY row_count DESC;
-- # stock_code, description, row_count, revenue, min_price, max_price, reason
-- 'POST', 'POSTAGE', '1832', '122801.34', '0.50', '8142.75', 'letters only'
-- 'DOT', 'DOTCOM POSTAGE', '1415', '309854.11', '0.35', '4505.17', 'letters only'
-- 'M', 'MANUAL', '785', '266033.94', '0.06', '25111.09', 'letters only'
-- 'C2', 'CARRIAGE', '262', '13176.00', '15.00', '150.00', 'explicit exception'
-- 'ADJUST', 'ADJUSTMENT BY JOHN ON 26/01/2010 16', '36', '8897.93', '4.57', '5117.03', 'letters only'
-- 'BANK CHARGES', 'BANK CHARGES', '32', '489.24', '0.00', '39.24', 'letters only'
-- 'DCGSSGIRL', 'GIRLS PARTY BAG', '23', '295.63', '1.25', '3.36', 'letters only'
-- 'DCGSSBOY', 'BOYS PARTY BAG', '21', '251.35', '1.25', '3.36', 'letters only'
-- 'PADS', 'PADS TO MATCH ALL CUSHIONS', '17', '0.02', '0.00', '0.00', 'letters only'
-- 'TEST001', 'THIS IS A TEST PRODUCT.', '9', '211.50', '4.50', '4.50', 'explicit exception'
-- 'D', 'DISCOUNT', '5', '397.89', '1.00', '101.99', 'letters only'
-- 'S', 'SAMPLES', '3', '136.85', '30.00', '73.80', 'letters only'
-- 'ADJUST2', 'ADJUSTMENT BY PETER ON JUN 25 2010', '3', '731.05', '72.45', '358.47', 'explicit exception'
-- 'AMAZONFEE', 'AMAZON FEE', '3', '20467.80', '219.76', '13541.33', 'letters only'
-- 'TEST002', 'THIS IS A TEST PRODUCT.', '1', '1.00', '1.00', '1.00', 'explicit exception'

DROP TABLE IF EXISTS retail_clean;
CREATE TABLE retail_clean (
  id                     INT           PRIMARY KEY,
  source_sheet           TINYINT       NOT NULL,
  source_row             INT           NOT NULL,
  invoice                VARCHAR(20)   NOT NULL,
  stock_code             VARCHAR(50)   NOT NULL,
  description            VARCHAR(500)  NOT NULL,
  is_missing_description BOOLEAN       NOT NULL,
  is_product             BOOLEAN       NOT NULL,
  quantity               INT           NOT NULL,   -- quantity after returns
  original_quantity      INT           NOT NULL,   -- original quantity
  invoice_date           DATETIME      NOT NULL,
  price                  DECIMAL(12,3) NOT NULL,
  revenue                DECIMAL(14,3) NOT NULL,
  customer_id            INT UNSIGNED  NULL,
  customer_key           VARCHAR(40)   NOT NULL,
  is_missing_customer    BOOLEAN       NOT NULL,
  INDEX idx_invoice (invoice),
  INDEX idx_stock (stock_code),
  INDEX idx_customer (customer_key)
);
 
INSERT INTO retail_clean
SELECT
  id,
  source_sheet,
  source_row,
  invoice,
  stock_code,
  COALESCE(description, CONCAT('PRODUCT-', stock_code)),
  description IS NULL,
  -- product = not made only of letters/spaces (DCGS... items always
  -- count as products), minus the known exceptions
  (stock_code NOT REGEXP '^[A-Z ]+$'
     OR stock_code LIKE 'DCGS%')         -- e.g. DCGSSGIRL, DCGSSBOY party bags
    AND stock_code <> 'C2'               -- carriage
    AND stock_code NOT LIKE 'TEST%'      -- test products
    AND stock_code NOT LIKE 'ADJUST%',   -- manual adjustments (e.g. ADJUST2)
  quantity,
  original_quantity,
  invoice_date,
  price,
  quantity * price,
  customer_id,
  COALESCE(CAST(customer_id AS CHAR), CONCAT('MISSING-', invoice)),
  customer_id IS NULL
FROM s5_no_returns;
 
INSERT INTO cleaning_log
SELECT 7, 'Final table retail_clean (no rows removed)',
       COUNT(*), (SELECT rows_after FROM cleaning_log WHERE step_no = 6) - COUNT(*)
FROM retail_clean;
 
-- No line without description is left after the cleaning steps, so the
-- flag is not needed. Expected: 0
SELECT SUM(is_missing_description) AS missing_descriptions FROM retail_clean;

ALTER TABLE retail_clean DROP COLUMN is_missing_description;

-- -----------------------------------------------------------------------------------------------------------

-- Overall weight of the duplicates.
SELECT
  COUNT(*)                                          AS duplicate_groups,
  SUM(g.n - 1)                                      AS extra_rows,
  ROUND(SUM((g.n - 1) * g.quantity * g.price), 2)   AS extra_revenue,
  ROUND(MAX(t.final_revenue), 2)                    AS final_revenue,
  ROUND(100 * SUM((g.n - 1) * g.quantity * g.price) / MAX(t.final_revenue), 2)
                                                    AS max_pct_of_final_revenue
FROM (
  SELECT quantity, price, COUNT(*) AS n
  FROM s2_uppercase
  WHERE quantity > 0 AND price > 0 AND invoice NOT LIKE 'C%'
  GROUP BY source_sheet, invoice, stock_code, description, quantity,
           invoice_date, price, customer_id, country
  HAVING COUNT(*) > 1
) g
CROSS JOIN (SELECT SUM(revenue) AS final_revenue FROM retail_clean) t;
 
SELECT
  SUM(pct > 5)   AS customers_over_5pct,
  SUM(pct > 10)  AS customers_over_10pct,
  SUM(pct > 20)  AS customers_over_20pct,
  COUNT(*)       AS customers_with_duplicates,
  (SELECT COUNT(DISTINCT customer_id) FROM retail_clean) AS known_customers
FROM (
  SELECT d.customer_id, 100 * d.dup_rev / c.rev AS pct
  FROM (
    SELECT customer_id, SUM((n - 1) * quantity * price) AS dup_rev
    FROM (
      SELECT customer_id, quantity, price, COUNT(*) AS n
      FROM s2_uppercase
      WHERE quantity > 0 AND price > 0 AND invoice NOT LIKE 'C%'
        AND customer_id IS NOT NULL
      GROUP BY source_sheet, invoice, stock_code, description, quantity,
               invoice_date, price, customer_id, country
      HAVING COUNT(*) > 1
    ) g
    GROUP BY customer_id
  ) d
  JOIN (SELECT customer_id, SUM(revenue) AS rev
        FROM retail_clean WHERE customer_id IS NOT NULL
        GROUP BY customer_id) c ON c.customer_id = d.customer_id
) x;

SELECT
  COUNT(*)              AS customers_over_10pct,
  ROUND(MAX(rev), 2)    AS max_revenue_over_10pct,
  ROUND(AVG(rev), 2)    AS avg_revenue_over_10pct
FROM (
  SELECT c.rev, 100 * d.dup_rev / c.rev AS pct
  FROM (
    SELECT customer_id, SUM((n - 1) * quantity * price) AS dup_rev
    FROM (
      SELECT customer_id, quantity, price, COUNT(*) AS n
      FROM s2_uppercase
      WHERE quantity > 0 AND price > 0 AND invoice NOT LIKE 'C%'
        AND customer_id IS NOT NULL
      GROUP BY source_sheet, invoice, stock_code, description, quantity,
               invoice_date, price, customer_id, country
      HAVING COUNT(*) > 1
    ) g
    GROUP BY customer_id
  ) d
  JOIN (SELECT customer_id, SUM(revenue) AS rev
        FROM retail_clean WHERE customer_id IS NOT NULL
        GROUP BY customer_id) c ON c.customer_id = d.customer_id
) x
WHERE pct > 10;
-- Exact duplicates were treated as recording errors and removed: 11,812 rows (1.1% of the raw data). 
-- Among valid sales, the 11,741 extra copies are worth £57,481, at most 0.29% of final revenue (£19.73M). 
-- 1,580 of the 5,859 known customers had at least one duplicate.
-- For only 38 of them duplicates exceed 10% of their final revenue.
-- All of these 38 have a final revenue of at most £1,207.

-- --------------------------------------------------------------------------------------------------------------------

-- 1. Cleaning summary (for the README)
SELECT step_no, step_name, rows_after, rows_removed,
       ROUND(100 * rows_removed / (SELECT rows_after FROM cleaning_log WHERE step_no = 0), 2)
         AS pct_of_total
FROM cleaning_log
ORDER BY step_no;
-- # step_no, step_name, rows_after, rows_removed, pct_of_total
-- '0', 'Data loading and union', '1067371', '0', '0.00'
-- '1', 'Removed intersection of two sheets', '1044848', '22523', '2.11'
-- '2', 'Text to uppercase', '1044848', '0', '0.00'
-- '3', 'Duplicates removed', '1033036', '11812', '1.11'
-- '4', 'Removed rows with prices <= 0 or invoice like \"A...\"', '1027016', '6020', '0.56'
-- '5', 'Removed returns (negative quantity or C invoice)', '1007912', '19104', '1.79'
-- '6', 'Removed purchases fully offset by returns (others reduced)', '1001903', '6009', '0.56'
-- '7', 'Final table retail_clean (no rows removed)', '1001903', '0', '0.00'


-- 2. Consistency checks: all must be 0
SELECT
  SUM(quantity <= 0)          AS non_positive_quantity,
  SUM(invoice LIKE 'C%')      AS return_invoices,
  SUM(invoice LIKE 'A%')      AS adjustment_invoices,
  SUM(price <= 0)             AS non_positive_price,
  SUM(invoice_date IS NULL)   AS missing_dates,
  SUM(description IS NULL)    AS missing_descriptions,
  SUM(customer_key IS NULL)   AS missing_customer_keys
FROM retail_clean;
-- ok

-- 3. Overview
SELECT
  COUNT(*)                                            AS row_count,
  COUNT(DISTINCT invoice)                             AS invoices,
  COUNT(DISTINCT customer_id)                         AS known_customers,
  SUM(is_missing_customer)                            AS rows_without_customer,
  ROUND(100 * SUM(CASE WHEN is_missing_customer = 1 THEN revenue END) / SUM(revenue), 2)
                                                      AS pct_revenue_without_customer,
  SUM(quantity < original_quantity)                   AS rows_reduced_by_returns,
  MIN(invoice_date)                                   AS first_date,
  MAX(invoice_date)                                   AS last_date,
  ROUND(SUM(revenue), 2)                              AS total_revenue
FROM retail_clean;
-- # row_count, invoices, known_customers, rows_without_customer, pct_revenue_without_customer, rows_reduced_by_returns, first_date, last_date,    total_revenue
--   '1001903', '39750',      '5859',            '228487',                 '15.67',                 '9124',            '2009-12-01', '2011-12-09', '19727380.03'

-- Overall weight of non-product codes
SELECT is_product,
       COUNT(*) AS row_count,
       ROUND(SUM(revenue), 2) AS revenue,
       ROUND(100 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 2) AS pct_revenue
FROM retail_clean
GROUP BY is_product;
-- # is_product, row_count, revenue, pct_revenue
-- '1', '997500', '18984181.36', '96.23'
-- '0', '4403', '743198.67', '3.77'


-- -------------------------------------------------------------------------------------------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- 1. retail_export - clean sales, net of returns (date only)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS retail_export;
CREATE TABLE retail_export AS
SELECT
  invoice,
  stock_code,
  is_product,
  quantity,
  DATE(invoice_date) AS invoice_date,   -- date only, time removed
  price,
  revenue,
  customer_id,
  customer_key,
  is_missing_customer
FROM retail_clean;

-- Check: expected 1,001,903 rows and the same revenue as retail_clean
SELECT COUNT(*) AS row_count, ROUND(SUM(revenue), 2) AS total_revenue
FROM retail_export;
-- ok
-- # row_count, total_revenue
-- '1001903', '19727380.03'


-- ---------------------------------------------------------------------
-- 2. products - one description per stock code
-- A stock code can have several descriptions (typos, renamed items):
-- the most frequent one is kept, ties broken alphabetically. Source:
-- s4_valid_price (all valid lines before the returns were offset, so every
-- description ever used counts). Only the codes of retail_export are kept:
-- codes whose sales were all cancelled by returns are left out. Codes
-- without any description get PRODUCT-<code>, as in retail_clean.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS products;
CREATE TABLE products AS
WITH description_counts AS (
  SELECT stock_code, description, COUNT(*) AS n
  FROM s4_valid_price
  WHERE description IS NOT NULL
  GROUP BY stock_code, description
),
ranked AS (
  SELECT stock_code, description,
         ROW_NUMBER() OVER (PARTITION BY stock_code ORDER BY n DESC, description) AS rn,
         COUNT(*)     OVER (PARTITION BY stock_code)                          AS n_descriptions
  FROM description_counts
)
SELECT c.stock_code,
       COALESCE(r.description, CONCAT('PRODUCT-', c.stock_code)) AS description,
       COALESCE(r.n_descriptions, 0)                             AS n_descriptions
FROM (SELECT DISTINCT stock_code FROM retail_export) c
LEFT JOIN ranked r ON r.stock_code = c.stock_code AND r.rn = 1;

ALTER TABLE products ADD PRIMARY KEY (stock_code);


-- ---------------------------------------------------------------------
-- Check
-- ---------------------------------------------------------------------

-- Codes, codes with more than one description, codes with none.
-- Expected: 4,735 (= distinct codes of retail_export: 4,722 products and
-- 13 non-product codes), 600, 0
SELECT COUNT(*)                   AS codes,
       SUM(n_descriptions > 1)    AS several_descriptions,
       SUM(n_descriptions = 0)    AS no_description
FROM products;
-- ok

-- ---------------------------------------------------------------------
-- EXPORT to CSV (into the secure_file_priv folder)
-- The first SELECT writes the header row. IFNULL(customer_id, '')
-- writes an empty field instead of \N for missing customers.
-- The file must not exist yet: delete it before re-running (error 1086).
-- ---------------------------------------------------------------------
SELECT 'invoice', 'stock_code', 'is_product', 'quantity', 'invoice_date',
       'price', 'revenue', 'customer_id', 'customer_key',
       'is_missing_customer'
UNION ALL
SELECT invoice, stock_code, is_product, quantity, invoice_date,
       price, revenue, IFNULL(customer_id, ''), customer_key,
       is_missing_customer
FROM retail_export
INTO OUTFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/retail_export.csv'
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n';

-- Descriptions can contain commas and quotes: fields are enclosed in double
-- quotes, and quotes inside a description are escaped with a backslash
-- (read in pandas with escapechar="\\").
SELECT 'stock_code', 'description', 'n_descriptions'
UNION ALL
SELECT stock_code, description, n_descriptions
FROM products
INTO OUTFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/products.csv'
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n';
