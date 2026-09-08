/*
Sakila for Microsoft SQL Server - 1500x data expansion (~5GB target).

Run this ONCE, after sql-server-sakila-schema.sql and
sql-server-sakila-insert-data.sql, against a fresh load. It is NOT
re-runnable: dbo.sakila_expansion_log is used as a marker to refuse a
second run, since a second run would expand the already-expanded data
again.

This is the same design as sql-server-sakila-expand-data-3000x.sql, just
retargeted to a smaller multiplier - use this one if 3000x/~10GB is more
than you need. Do not run both against the same database.

Expands ~1500x: country, city, address, actor, customer, film, film_actor,
film_category, inventory, rental, payment.
Left untouched (reference/operational dimensions): language, category,
store, staff - expanded rows reference their existing ids directly.

At this scale rental/payment reach ~24M rows each. RECOMMENDATIONS before
running on real hardware:
  - Set the database recovery model to SIMPLE (or take frequent log
    backups) - this script does not manage the transaction log for you.
  - Ensure ~8-10GB free disk (data + log + tempdb spill), beyond the
    final ~5GB resting size.
  - Expect real wall-clock time (tens of minutes) - this is not a quick
    script.

Strategy: snapshot each source table's original rows into a #_orig temp
table, generate a #batch_numbers temp table (1..1499, batch 0 = the
untouched originals), then for each table, loop over batch-number chunks
(100 batches per iteration) and MERGE ... OUTPUT new rows per chunk while
recording (batch_no, old_id, new_id) into a #_map temp table. Chunking
keeps each individual MERGE to ~the same per-statement row volume as a
100x run (already proven-safe scale) instead of one giant single-shot
MERGE moving tens of millions of rows. Downstream tables join their
parent's _map table on batch_no, so every FK chain inside one generated
batch is internally consistent and automatically disjoint from the
originals and every other batch - this is what keeps film_actor/
film_category's composite PKs and rental's
(rental_date, inventory_id, customer_id) unique index satisfied without
any string/date hacking.
*/

USE sakila;
GO

-- Guard: store_id/staff_id alternation below assumes exactly {1,2}.
IF EXISTS (SELECT 1 FROM store WHERE store_id NOT IN (1,2))
   OR EXISTS (SELECT 1 FROM staff WHERE staff_id NOT IN (1,2))
BEGIN
    THROW 50001, 'store/staff ids are not exactly {1,2} - the store_id/staff_id alternation formula in this script needs updating.', 1;
END
GO

-- Guard: refuse to run twice. Marker table, not a row-count heuristic,
-- so it works regardless of which multiplier was used.
IF OBJECT_ID('dbo.sakila_expansion_log') IS NULL
BEGIN
    CREATE TABLE dbo.sakila_expansion_log (
        expansion_id INT IDENTITY PRIMARY KEY,
        multiplier INT NOT NULL,
        started_at DATETIME NOT NULL DEFAULT GETDATE(),
        completed_at DATETIME NULL
    );
END
GO

IF EXISTS (SELECT 1 FROM dbo.sakila_expansion_log)
BEGIN
    THROW 50000, 'sql-server-sakila-expand-data-1500x.sql already appears to have been run (see dbo.sakila_expansion_log). Aborting to avoid double-expansion.', 1;
END
GO

INSERT INTO dbo.sakila_expansion_log (multiplier) VALUES (1500);
GO

-- #batch_numbers: 1..1499 (batch 0 = the untouched originals already in
-- the tables). Recursive CTE instead of a catalog-view cross join, so it
-- doesn't depend on how many rows sys.all_objects happens to have.
IF OBJECT_ID('tempdb..#batch_numbers') IS NOT NULL DROP TABLE #batch_numbers;
GO
DECLARE @total_batches INT = 1499;
;WITH n AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM n WHERE n < @total_batches
)
SELECT n INTO #batch_numbers FROM n
OPTION (MAXRECURSION 0);
GO

--
-- country
--
IF OBJECT_ID('tempdb..#country_orig') IS NOT NULL DROP TABLE #country_orig;
SELECT country_id, country, last_update INTO #country_orig FROM country;
GO

CREATE TABLE #country_map (batch_no INT NOT NULL, old_id INT NOT NULL, new_id INT NOT NULL, PRIMARY KEY (batch_no, old_id));
GO

DECLARE @batches INT = 1499, @chunk_size INT = 100, @chunk_start INT = 1, @chunk_end INT;
WHILE @chunk_start <= @batches
BEGIN
    SET @chunk_end = CASE WHEN @chunk_start + @chunk_size - 1 > @batches THEN @batches ELSE @chunk_start + @chunk_size - 1 END;

    MERGE INTO country AS tgt
    USING (
        SELECT bn.n AS batch_no, o.country_id AS old_id,
               LEFT(o.country + '-' + CAST(bn.n AS VARCHAR(6)), 50) AS country,
               o.last_update
        FROM #country_orig o
        CROSS JOIN #batch_numbers bn
        WHERE bn.n BETWEEN @chunk_start AND @chunk_end
    ) AS src
    ON 1 = 0
    WHEN NOT MATCHED THEN
        INSERT (country, last_update) VALUES (src.country, src.last_update)
    OUTPUT src.batch_no, src.old_id, inserted.country_id INTO #country_map (batch_no, old_id, new_id);

    SET @chunk_start = @chunk_end + 1;
END
GO

IF (SELECT COUNT(*) FROM country) <> (SELECT COUNT(*) FROM #country_orig) * 1500
    THROW 50010, 'country expansion did not produce exactly 1500x rows.', 1;
GO

--
-- city
--
IF OBJECT_ID('tempdb..#city_orig') IS NOT NULL DROP TABLE #city_orig;
SELECT city_id, city, country_id, last_update INTO #city_orig FROM city;
GO

CREATE TABLE #city_map (batch_no INT NOT NULL, old_id INT NOT NULL, new_id INT NOT NULL, PRIMARY KEY (batch_no, old_id));
GO

DECLARE @batches INT = 1499, @chunk_size INT = 100, @chunk_start INT = 1, @chunk_end INT;
WHILE @chunk_start <= @batches
BEGIN
    SET @chunk_end = CASE WHEN @chunk_start + @chunk_size - 1 > @batches THEN @batches ELSE @chunk_start + @chunk_size - 1 END;

    MERGE INTO city AS tgt
    USING (
        SELECT bn.n AS batch_no, o.city_id AS old_id,
               LEFT(o.city + '-' + CAST(bn.n AS VARCHAR(6)), 50) AS city,
               cm.new_id AS country_id,
               o.last_update
        FROM #city_orig o
        CROSS JOIN #batch_numbers bn
        JOIN #country_map cm ON cm.batch_no = bn.n AND cm.old_id = o.country_id
        WHERE bn.n BETWEEN @chunk_start AND @chunk_end
    ) AS src
    ON 1 = 0
    WHEN NOT MATCHED THEN
        INSERT (city, country_id, last_update) VALUES (src.city, src.country_id, src.last_update)
    OUTPUT src.batch_no, src.old_id, inserted.city_id INTO #city_map (batch_no, old_id, new_id);

    SET @chunk_start = @chunk_end + 1;
END
GO

IF (SELECT COUNT(*) FROM city) <> (SELECT COUNT(*) FROM #city_orig) * 1500
    THROW 50011, 'city expansion did not produce exactly 1500x rows.', 1;
GO

--
-- address
--
IF OBJECT_ID('tempdb..#address_orig') IS NOT NULL DROP TABLE #address_orig;
SELECT address_id, address, address2, district, city_id, postal_code, phone, last_update
INTO #address_orig FROM address;
GO

CREATE TABLE #address_map (batch_no INT NOT NULL, old_id INT NOT NULL, new_id INT NOT NULL, PRIMARY KEY (batch_no, old_id));
GO

DECLARE @batches INT = 1499, @chunk_size INT = 100, @chunk_start INT = 1, @chunk_end INT;
WHILE @chunk_start <= @batches
BEGIN
    SET @chunk_end = CASE WHEN @chunk_start + @chunk_size - 1 > @batches THEN @batches ELSE @chunk_start + @chunk_size - 1 END;

    MERGE INTO address AS tgt
    USING (
        SELECT bn.n AS batch_no, o.address_id AS old_id,
               LEFT(o.address + '-' + CAST(bn.n AS VARCHAR(6)), 50) AS address,
               o.address2, o.district,
               cm.new_id AS city_id,
               o.postal_code, o.phone, o.last_update
        FROM #address_orig o
        CROSS JOIN #batch_numbers bn
        JOIN #city_map cm ON cm.batch_no = bn.n AND cm.old_id = o.city_id
        WHERE bn.n BETWEEN @chunk_start AND @chunk_end
    ) AS src
    ON 1 = 0
    WHEN NOT MATCHED THEN
        INSERT (address, address2, district, city_id, postal_code, phone, last_update)
        VALUES (src.address, src.address2, src.district, src.city_id, src.postal_code, src.phone, src.last_update)
    OUTPUT src.batch_no, src.old_id, inserted.address_id INTO #address_map (batch_no, old_id, new_id);

    SET @chunk_start = @chunk_end + 1;
END
GO

IF (SELECT COUNT(*) FROM address) <> (SELECT COUNT(*) FROM #address_orig) * 1500
    THROW 50012, 'address expansion did not produce exactly 1500x rows.', 1;
GO

--
-- actor
--
IF OBJECT_ID('tempdb..#actor_orig') IS NOT NULL DROP TABLE #actor_orig;
SELECT actor_id, first_name, last_name, last_update INTO #actor_orig FROM actor;
GO

CREATE TABLE #actor_map (batch_no INT NOT NULL, old_id INT NOT NULL, new_id INT NOT NULL, PRIMARY KEY (batch_no, old_id));
GO

DECLARE @batches INT = 1499, @chunk_size INT = 100, @chunk_start INT = 1, @chunk_end INT;
WHILE @chunk_start <= @batches
BEGIN
    SET @chunk_end = CASE WHEN @chunk_start + @chunk_size - 1 > @batches THEN @batches ELSE @chunk_start + @chunk_size - 1 END;

    MERGE INTO actor AS tgt
    USING (
        SELECT bn.n AS batch_no, o.actor_id AS old_id,
               o.first_name,
               LEFT(o.last_name + '-' + CAST(bn.n AS VARCHAR(6)), 45) AS last_name,
               o.last_update
        FROM #actor_orig o
        CROSS JOIN #batch_numbers bn
        WHERE bn.n BETWEEN @chunk_start AND @chunk_end
    ) AS src
    ON 1 = 0
    WHEN NOT MATCHED THEN
        INSERT (first_name, last_name, last_update) VALUES (src.first_name, src.last_name, src.last_update)
    OUTPUT src.batch_no, src.old_id, inserted.actor_id INTO #actor_map (batch_no, old_id, new_id);

    SET @chunk_start = @chunk_end + 1;
END
GO

IF (SELECT COUNT(*) FROM actor) <> (SELECT COUNT(*) FROM #actor_orig) * 1500
    THROW 50013, 'actor expansion did not produce exactly 1500x rows.', 1;
GO

--
-- customer
--
IF OBJECT_ID('tempdb..#customer_orig') IS NOT NULL DROP TABLE #customer_orig;
SELECT customer_id, store_id, first_name, last_name, email, address_id, active, create_date, last_update
INTO #customer_orig FROM customer;
GO

CREATE TABLE #customer_map (batch_no INT NOT NULL, old_id INT NOT NULL, new_id INT NOT NULL, PRIMARY KEY (batch_no, old_id));
GO

DECLARE @batches INT = 1499, @chunk_size INT = 100, @chunk_start INT = 1, @chunk_end INT;
WHILE @chunk_start <= @batches
BEGIN
    SET @chunk_end = CASE WHEN @chunk_start + @chunk_size - 1 > @batches THEN @batches ELSE @chunk_start + @chunk_size - 1 END;

    MERGE INTO customer AS tgt
    USING (
        SELECT bn.n AS batch_no, o.customer_id AS old_id,
               ((o.store_id - 1 + bn.n) % 2) + 1 AS store_id,
               o.first_name,
               LEFT(o.last_name + '-' + CAST(bn.n AS VARCHAR(6)), 45) AS last_name,
               LEFT('gen' + CAST(bn.n AS VARCHAR(6)) + '.' + CAST(o.customer_id AS VARCHAR(6)) + '@sakila.gen', 50) AS email,
               am.new_id AS address_id,
               o.active, o.create_date, o.last_update
        FROM #customer_orig o
        CROSS JOIN #batch_numbers bn
        JOIN #address_map am ON am.batch_no = bn.n AND am.old_id = o.address_id
        WHERE bn.n BETWEEN @chunk_start AND @chunk_end
    ) AS src
    ON 1 = 0
    WHEN NOT MATCHED THEN
        INSERT (store_id, first_name, last_name, email, address_id, active, create_date, last_update)
        VALUES (src.store_id, src.first_name, src.last_name, src.email, src.address_id, src.active, src.create_date, src.last_update)
    OUTPUT src.batch_no, src.old_id, inserted.customer_id INTO #customer_map (batch_no, old_id, new_id);

    SET @chunk_start = @chunk_end + 1;
END
GO

IF (SELECT COUNT(*) FROM customer) <> (SELECT COUNT(*) FROM #customer_orig) * 1500
    THROW 50014, 'customer expansion did not produce exactly 1500x rows.', 1;
GO

--
-- film
--
IF OBJECT_ID('tempdb..#film_orig') IS NOT NULL DROP TABLE #film_orig;
SELECT film_id, title, description, release_year, language_id, original_language_id,
       rental_duration, rental_rate, length, replacement_cost, rating, special_features, last_update
INTO #film_orig FROM film;
GO

CREATE TABLE #film_map (batch_no INT NOT NULL, old_id INT NOT NULL, new_id INT NOT NULL, PRIMARY KEY (batch_no, old_id));
GO

DECLARE @batches INT = 1499, @chunk_size INT = 100, @chunk_start INT = 1, @chunk_end INT;
WHILE @chunk_start <= @batches
BEGIN
    SET @chunk_end = CASE WHEN @chunk_start + @chunk_size - 1 > @batches THEN @batches ELSE @chunk_start + @chunk_size - 1 END;

    MERGE INTO film AS tgt
    USING (
        SELECT bn.n AS batch_no, o.film_id AS old_id,
               LEFT(o.title + '-' + CAST(bn.n AS VARCHAR(6)), 255) AS title,
               o.description, o.release_year, o.language_id, o.original_language_id,
               o.rental_duration, o.rental_rate, o.length, o.replacement_cost, o.rating, o.special_features, o.last_update
        FROM #film_orig o
        CROSS JOIN #batch_numbers bn
        WHERE bn.n BETWEEN @chunk_start AND @chunk_end
    ) AS src
    ON 1 = 0
    WHEN NOT MATCHED THEN
        INSERT (title, description, release_year, language_id, original_language_id, rental_duration, rental_rate, length, replacement_cost, rating, special_features, last_update)
        VALUES (src.title, src.description, src.release_year, src.language_id, src.original_language_id, src.rental_duration, src.rental_rate, src.length, src.replacement_cost, src.rating, src.special_features, src.last_update)
    OUTPUT src.batch_no, src.old_id, inserted.film_id INTO #film_map (batch_no, old_id, new_id);

    SET @chunk_start = @chunk_end + 1;
END
GO

IF (SELECT COUNT(*) FROM film) <> (SELECT COUNT(*) FROM #film_orig) * 1500
    THROW 50015, 'film expansion did not produce exactly 1500x rows.', 1;
GO

--
-- film_actor (composite PK, no identity - plain INSERT, no map needed)
--
IF OBJECT_ID('tempdb..#film_actor_orig') IS NOT NULL DROP TABLE #film_actor_orig;
SELECT actor_id, film_id, last_update INTO #film_actor_orig FROM film_actor;
GO

DECLARE @batches INT = 1499, @chunk_size INT = 100, @chunk_start INT = 1, @chunk_end INT;
WHILE @chunk_start <= @batches
BEGIN
    SET @chunk_end = CASE WHEN @chunk_start + @chunk_size - 1 > @batches THEN @batches ELSE @chunk_start + @chunk_size - 1 END;

    INSERT INTO film_actor (actor_id, film_id, last_update)
    SELECT am.new_id, fm.new_id, o.last_update
    FROM #film_actor_orig o
    CROSS JOIN #batch_numbers bn
    JOIN #actor_map am ON am.batch_no = bn.n AND am.old_id = o.actor_id
    JOIN #film_map fm ON fm.batch_no = bn.n AND fm.old_id = o.film_id
    WHERE bn.n BETWEEN @chunk_start AND @chunk_end;

    SET @chunk_start = @chunk_end + 1;
END
GO

IF (SELECT COUNT(*) FROM film_actor) <> (SELECT COUNT(*) FROM #film_actor_orig) * 1500
    THROW 50016, 'film_actor expansion did not produce exactly 1500x rows.', 1;
GO

--
-- film_category (composite PK, no identity - plain INSERT, no map needed)
--
IF OBJECT_ID('tempdb..#film_category_orig') IS NOT NULL DROP TABLE #film_category_orig;
SELECT film_id, category_id, last_update INTO #film_category_orig FROM film_category;
GO

DECLARE @batches INT = 1499, @chunk_size INT = 100, @chunk_start INT = 1, @chunk_end INT;
WHILE @chunk_start <= @batches
BEGIN
    SET @chunk_end = CASE WHEN @chunk_start + @chunk_size - 1 > @batches THEN @batches ELSE @chunk_start + @chunk_size - 1 END;

    INSERT INTO film_category (film_id, category_id, last_update)
    SELECT fm.new_id, o.category_id, o.last_update
    FROM #film_category_orig o
    CROSS JOIN #batch_numbers bn
    JOIN #film_map fm ON fm.batch_no = bn.n AND fm.old_id = o.film_id
    WHERE bn.n BETWEEN @chunk_start AND @chunk_end;

    SET @chunk_start = @chunk_end + 1;
END
GO

IF (SELECT COUNT(*) FROM film_category) <> (SELECT COUNT(*) FROM #film_category_orig) * 1500
    THROW 50017, 'film_category expansion did not produce exactly 1500x rows.', 1;
GO

--
-- inventory
--
IF OBJECT_ID('tempdb..#inventory_orig') IS NOT NULL DROP TABLE #inventory_orig;
SELECT inventory_id, film_id, store_id, last_update INTO #inventory_orig FROM inventory;
GO

CREATE TABLE #inventory_map (batch_no INT NOT NULL, old_id INT NOT NULL, new_id INT NOT NULL, PRIMARY KEY (batch_no, old_id));
GO

DECLARE @batches INT = 1499, @chunk_size INT = 100, @chunk_start INT = 1, @chunk_end INT;
WHILE @chunk_start <= @batches
BEGIN
    SET @chunk_end = CASE WHEN @chunk_start + @chunk_size - 1 > @batches THEN @batches ELSE @chunk_start + @chunk_size - 1 END;

    MERGE INTO inventory AS tgt
    USING (
        SELECT bn.n AS batch_no, o.inventory_id AS old_id,
               fm.new_id AS film_id,
               ((o.store_id - 1 + bn.n) % 2) + 1 AS store_id,
               o.last_update
        FROM #inventory_orig o
        CROSS JOIN #batch_numbers bn
        JOIN #film_map fm ON fm.batch_no = bn.n AND fm.old_id = o.film_id
        WHERE bn.n BETWEEN @chunk_start AND @chunk_end
    ) AS src
    ON 1 = 0
    WHEN NOT MATCHED THEN
        INSERT (film_id, store_id, last_update) VALUES (src.film_id, src.store_id, src.last_update)
    OUTPUT src.batch_no, src.old_id, inserted.inventory_id INTO #inventory_map (batch_no, old_id, new_id);

    SET @chunk_start = @chunk_end + 1;
END
GO

IF (SELECT COUNT(*) FROM inventory) <> (SELECT COUNT(*) FROM #inventory_orig) * 1500
    THROW 50018, 'inventory expansion did not produce exactly 1500x rows.', 1;
GO

--
-- rental
-- unique index (rental_date, inventory_id, customer_id) is satisfied
-- automatically: inventory_id is unique per batch, so the tuple can never
-- collide with the original row or another batch's row even though
-- rental_date is copied unchanged.
--
IF OBJECT_ID('tempdb..#rental_orig') IS NOT NULL DROP TABLE #rental_orig;
SELECT rental_id, rental_date, inventory_id, customer_id, return_date, staff_id, last_update
INTO #rental_orig FROM rental;
GO

CREATE TABLE #rental_map (batch_no INT NOT NULL, old_id INT NOT NULL, new_id INT NOT NULL, PRIMARY KEY (batch_no, old_id));
GO

DECLARE @batches INT = 1499, @chunk_size INT = 100, @chunk_start INT = 1, @chunk_end INT;
WHILE @chunk_start <= @batches
BEGIN
    SET @chunk_end = CASE WHEN @chunk_start + @chunk_size - 1 > @batches THEN @batches ELSE @chunk_start + @chunk_size - 1 END;

    MERGE INTO rental AS tgt
    USING (
        SELECT bn.n AS batch_no, o.rental_id AS old_id,
               o.rental_date,
               im.new_id AS inventory_id,
               cm.new_id AS customer_id,
               o.return_date,
               ((o.staff_id - 1 + bn.n) % 2) + 1 AS staff_id,
               o.last_update
        FROM #rental_orig o
        CROSS JOIN #batch_numbers bn
        JOIN #inventory_map im ON im.batch_no = bn.n AND im.old_id = o.inventory_id
        JOIN #customer_map cm ON cm.batch_no = bn.n AND cm.old_id = o.customer_id
        WHERE bn.n BETWEEN @chunk_start AND @chunk_end
    ) AS src
    ON 1 = 0
    WHEN NOT MATCHED THEN
        INSERT (rental_date, inventory_id, customer_id, return_date, staff_id, last_update)
        VALUES (src.rental_date, src.inventory_id, src.customer_id, src.return_date, src.staff_id, src.last_update)
    OUTPUT src.batch_no, src.old_id, inserted.rental_id INTO #rental_map (batch_no, old_id, new_id);

    SET @chunk_start = @chunk_end + 1;
END
GO

IF (SELECT COUNT(*) FROM rental) <> (SELECT COUNT(*) FROM #rental_orig) * 1500
    THROW 50019, 'rental expansion did not produce exactly 1500x rows.', 1;
GO

--
-- payment (nothing FKs to payment - plain INSERT, no map needed)
--
IF OBJECT_ID('tempdb..#payment_orig') IS NOT NULL DROP TABLE #payment_orig;
SELECT payment_id, customer_id, staff_id, rental_id, amount, payment_date, last_update
INTO #payment_orig FROM payment;
GO

DECLARE @batches INT = 1499, @chunk_size INT = 100, @chunk_start INT = 1, @chunk_end INT;
WHILE @chunk_start <= @batches
BEGIN
    SET @chunk_end = CASE WHEN @chunk_start + @chunk_size - 1 > @batches THEN @batches ELSE @chunk_start + @chunk_size - 1 END;

    INSERT INTO payment (customer_id, staff_id, rental_id, amount, payment_date, last_update)
    SELECT cm.new_id,
           ((o.staff_id - 1 + bn.n) % 2) + 1,
           rm.new_id,
           o.amount, o.payment_date, o.last_update
    FROM #payment_orig o
    CROSS JOIN #batch_numbers bn
    JOIN #customer_map cm ON cm.batch_no = bn.n AND cm.old_id = o.customer_id
    LEFT JOIN #rental_map rm ON rm.batch_no = bn.n AND rm.old_id = o.rental_id
    WHERE bn.n BETWEEN @chunk_start AND @chunk_end;

    SET @chunk_start = @chunk_end + 1;
END
GO

IF (SELECT COUNT(*) FROM payment) <> (SELECT COUNT(*) FROM #payment_orig) * 1500
    THROW 50020, 'payment expansion did not produce exactly 1500x rows.', 1;
GO

--
-- FK-integrity check
--
IF EXISTS (SELECT 1 FROM city c WHERE NOT EXISTS (SELECT 1 FROM country co WHERE co.country_id = c.country_id))
    THROW 50030, 'orphaned city.country_id found after expansion.', 1;
IF EXISTS (SELECT 1 FROM address a WHERE NOT EXISTS (SELECT 1 FROM city c WHERE c.city_id = a.city_id))
    THROW 50031, 'orphaned address.city_id found after expansion.', 1;
IF EXISTS (SELECT 1 FROM customer cu WHERE NOT EXISTS (SELECT 1 FROM address a WHERE a.address_id = cu.address_id))
    THROW 50032, 'orphaned customer.address_id found after expansion.', 1;
IF EXISTS (SELECT 1 FROM film_actor fa WHERE NOT EXISTS (SELECT 1 FROM actor a WHERE a.actor_id = fa.actor_id)
                                      OR NOT EXISTS (SELECT 1 FROM film f WHERE f.film_id = fa.film_id))
    THROW 50033, 'orphaned film_actor row found after expansion.', 1;
IF EXISTS (SELECT 1 FROM film_category fc WHERE NOT EXISTS (SELECT 1 FROM film f WHERE f.film_id = fc.film_id))
    THROW 50034, 'orphaned film_category.film_id found after expansion.', 1;
IF EXISTS (SELECT 1 FROM inventory i WHERE NOT EXISTS (SELECT 1 FROM film f WHERE f.film_id = i.film_id))
    THROW 50035, 'orphaned inventory.film_id found after expansion.', 1;
IF EXISTS (SELECT 1 FROM rental r WHERE NOT EXISTS (SELECT 1 FROM inventory i WHERE i.inventory_id = r.inventory_id)
                                    OR NOT EXISTS (SELECT 1 FROM customer c WHERE c.customer_id = r.customer_id))
    THROW 50036, 'orphaned rental row found after expansion.', 1;
IF EXISTS (SELECT 1 FROM payment p WHERE NOT EXISTS (SELECT 1 FROM customer c WHERE c.customer_id = p.customer_id))
    THROW 50037, 'orphaned payment.customer_id found after expansion.', 1;
GO

-- Mark the expansion complete.
UPDATE dbo.sakila_expansion_log SET completed_at = GETDATE()
WHERE expansion_id = (SELECT MAX(expansion_id) FROM dbo.sakila_expansion_log);
GO

--
-- Summary report
--
SELECT 'country' AS tbl, COUNT(*) AS row_count FROM country
UNION ALL SELECT 'city', COUNT(*) FROM city
UNION ALL SELECT 'address', COUNT(*) FROM address
UNION ALL SELECT 'actor', COUNT(*) FROM actor
UNION ALL SELECT 'customer', COUNT(*) FROM customer
UNION ALL SELECT 'film', COUNT(*) FROM film
UNION ALL SELECT 'film_actor', COUNT(*) FROM film_actor
UNION ALL SELECT 'film_category', COUNT(*) FROM film_category
UNION ALL SELECT 'inventory', COUNT(*) FROM inventory
UNION ALL SELECT 'rental', COUNT(*) FROM rental
UNION ALL SELECT 'payment', COUNT(*) FROM payment;
GO

-- Actual on-disk size, by table (run after the load to see real numbers,
-- not just the row-count estimate from the plan doc).
SELECT
    t.name AS table_name,
    SUM(a.total_pages) * 8 / 1024 AS total_size_mb,
    SUM(a.used_pages) * 8 / 1024 AS used_size_mb,
    SUM(a.data_pages) * 8 / 1024 AS data_size_mb
FROM sys.tables t
JOIN sys.indexes i ON t.object_id = i.object_id
JOIN sys.partitions p ON i.object_id = p.object_id AND i.index_id = p.index_id
JOIN sys.allocation_units a ON p.partition_id = a.container_id
WHERE t.name IN ('country','city','address','actor','customer','film','film_actor',
                 'film_category','inventory','rental','payment','language','category',
                 'store','staff')
GROUP BY t.name
ORDER BY total_size_mb DESC;
GO

-- Cleanup (cosmetic - temp tables drop on disconnect anyway)
DROP TABLE IF EXISTS #batch_numbers, #country_orig, #country_map, #city_orig, #city_map,
    #address_orig, #address_map, #actor_orig, #actor_map, #customer_orig, #customer_map,
    #film_orig, #film_map, #film_actor_orig, #film_category_orig, #inventory_orig,
    #inventory_map, #rental_orig, #rental_map, #payment_orig;
GO
