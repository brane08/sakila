/*
Sakila for PostgreSQL - 500x data expansion (~3-4GB target).

Run this ONCE, after postgres-sakila-schema.sql and
postgres-sakila-insert-data.sql (or postgres-sakila-insert-data-using-copy.sql),
against a fresh load. It is NOT re-runnable: sakila_expansion_log is used
as a marker to refuse a second run, since a second run would expand the
already-expanded data again.

Expands ~500x: country, city, address, actor, customer, film, film_actor,
film_category, inventory, rental, payment.
Left untouched (reference/operational dimensions): language, category,
store, staff - expanded rows reference their existing ids directly.

At this scale rental/payment reach ~8M rows each. RECOMMENDATIONS before
running on real hardware:
  - Expect real wall-clock time (several to tens of minutes depending on
    hardware) - this is not a quick script.
  - Ensure a few GB of free disk beyond the final resting size (WAL +
    index build during the run).
  - Consider running with autocommit off in one session so a failure
    partway through can be rolled back cleanly (the guard/log table makes
    a clean re-run safe either way).

Strategy differs from the SQL Server sibling scripts because of Postgres
specifics:
  - Postgres has no MERGE...OUTPUT INTO correlation trick this old
    (pre-15) reliably across all supported versions, and INSERT...RETURNING
    row order is not guaranteed to line up with the source SELECT's row
    order. Instead, ids are generated up front with nextval() directly
    into a _map(batch_no, old_id, new_id) table via a plain INSERT...SELECT
    (one nextval() call per output row, so batch_no/old_id/new_id always
    land together on the same row - order-independent, no RETURNING
    needed), then the actual data INSERT joins _orig to _map by old_id.
  - Chunking uses a DO $$ ... $$ block per table with a loop over
    batch-number ranges and dynamic SQL (EXECUTE ... USING), since
    Postgres doesn't have SQL Server's GO-batch-separator restriction but
    still benefits from bounding each statement's row volume.
  - payment is PARTITIONED BY RULE into payment_p2007_01..06 by
    payment_date range. Since payment_date is copied unchanged from the
    original rows, generated rows are routed the same way the originals
    are: if your data's payment_date values fall in Jan-Jun 2007, the
    existing payment_insert_p2007_0X rules route both original and
    generated rows into the matching monthly child table; if they don't
    (e.g. some Sakila sample loads use 2005/2006 dates), no rule matches
    and rows land in the base payment table instead - which is exactly
    what already happens to the original rows in that case. Either way
    no special-casing is needed beyond a plain INSERT INTO payment, and
    COUNT(*) FROM payment includes inherited child rows automatically.
  - film.fulltext (tsvector, NOT NULL) is populated by the
    film_fulltext_trigger BEFORE INSERT trigger from title/description,
    so it is omitted from the film INSERT column list entirely.
  - mpaa_rating (enum), the year domain, and special_features (text[])
    are just copied through unchanged from the original row per batch -
    no type-specific handling needed since we don't touch those columns.
*/

\set ON_ERROR_STOP on

-- Guard: store_id/staff_id alternation below assumes exactly {1,2}.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM store WHERE store_id NOT IN (1,2))
       OR EXISTS (SELECT 1 FROM staff WHERE staff_id NOT IN (1,2)) THEN
        RAISE EXCEPTION 'store/staff ids are not exactly {1,2} - the store_id/staff_id alternation formula in this script needs updating.';
    END IF;
END $$;

-- Guard: refuse to run twice. Marker table, not a row-count heuristic,
-- so it works regardless of which multiplier was used.
CREATE TABLE IF NOT EXISTS sakila_expansion_log (
    expansion_id SERIAL PRIMARY KEY,
    multiplier INT NOT NULL,
    started_at TIMESTAMP NOT NULL DEFAULT now(),
    completed_at TIMESTAMP NULL
);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM sakila_expansion_log) THEN
        RAISE EXCEPTION 'postgres-sakila-expand-data.sql already appears to have been run (see sakila_expansion_log). Aborting to avoid double-expansion.';
    END IF;
END $$;

INSERT INTO sakila_expansion_log (multiplier) VALUES (500);

-- batch_numbers: 1..499 (batch 0 = the untouched originals already in the
-- tables).
DROP TABLE IF EXISTS batch_numbers;
CREATE TEMP TABLE batch_numbers AS SELECT generate_series(1, 499) AS n;

--
-- country
--
DROP TABLE IF EXISTS country_orig;
CREATE TEMP TABLE country_orig AS SELECT country_id, country, last_update FROM country;

DROP TABLE IF EXISTS country_map;
CREATE TEMP TABLE country_map (batch_no INT NOT NULL, old_id INT NOT NULL, new_id INT NOT NULL, PRIMARY KEY (batch_no, old_id));

INSERT INTO country_map (batch_no, old_id, new_id)
SELECT bn.n, o.country_id, nextval('country_country_id_seq')
FROM country_orig o CROSS JOIN batch_numbers bn;

DO $$
DECLARE
    chunk_size INT := 100;
    chunk_start INT := 1;
    chunk_end INT;
BEGIN
    WHILE chunk_start <= 499 LOOP
        chunk_end := LEAST(chunk_start + chunk_size - 1, 499);

        INSERT INTO country (country_id, country, last_update)
        SELECT m.new_id, LEFT(o.country || '-' || m.batch_no::text, 50), o.last_update
        FROM country_orig o
        JOIN country_map m ON m.old_id = o.country_id
        WHERE m.batch_no BETWEEN chunk_start AND chunk_end;

        chunk_start := chunk_end + 1;
    END LOOP;
END $$;

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM country) <> (SELECT COUNT(*) FROM country_orig) * 500 THEN
        RAISE EXCEPTION 'country expansion did not produce exactly 500x rows.';
    END IF;
END $$;

--
-- city
--
DROP TABLE IF EXISTS city_orig;
CREATE TEMP TABLE city_orig AS SELECT city_id, city, country_id, last_update FROM city;

DROP TABLE IF EXISTS city_map;
CREATE TEMP TABLE city_map (batch_no INT NOT NULL, old_id INT NOT NULL, new_id INT NOT NULL, PRIMARY KEY (batch_no, old_id));

INSERT INTO city_map (batch_no, old_id, new_id)
SELECT bn.n, o.city_id, nextval('city_city_id_seq')
FROM city_orig o CROSS JOIN batch_numbers bn;

DO $$
DECLARE
    chunk_size INT := 100;
    chunk_start INT := 1;
    chunk_end INT;
BEGIN
    WHILE chunk_start <= 499 LOOP
        chunk_end := LEAST(chunk_start + chunk_size - 1, 499);

        INSERT INTO city (city_id, city, country_id, last_update)
        SELECT m.new_id, LEFT(o.city || '-' || m.batch_no::text, 50), cm.new_id, o.last_update
        FROM city_orig o
        JOIN city_map m ON m.old_id = o.city_id AND m.batch_no BETWEEN chunk_start AND chunk_end
        JOIN country_map cm ON cm.batch_no = m.batch_no AND cm.old_id = o.country_id;

        chunk_start := chunk_end + 1;
    END LOOP;
END $$;

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM city) <> (SELECT COUNT(*) FROM city_orig) * 500 THEN
        RAISE EXCEPTION 'city expansion did not produce exactly 500x rows.';
    END IF;
END $$;

--
-- address
--
DROP TABLE IF EXISTS address_orig;
CREATE TEMP TABLE address_orig AS
SELECT address_id, address, address2, district, city_id, postal_code, phone, last_update FROM address;

DROP TABLE IF EXISTS address_map;
CREATE TEMP TABLE address_map (batch_no INT NOT NULL, old_id INT NOT NULL, new_id INT NOT NULL, PRIMARY KEY (batch_no, old_id));

INSERT INTO address_map (batch_no, old_id, new_id)
SELECT bn.n, o.address_id, nextval('address_address_id_seq')
FROM address_orig o CROSS JOIN batch_numbers bn;

DO $$
DECLARE
    chunk_size INT := 100;
    chunk_start INT := 1;
    chunk_end INT;
BEGIN
    WHILE chunk_start <= 499 LOOP
        chunk_end := LEAST(chunk_start + chunk_size - 1, 499);

        INSERT INTO address (address_id, address, address2, district, city_id, postal_code, phone, last_update)
        SELECT m.new_id, LEFT(o.address || '-' || m.batch_no::text, 50), o.address2, o.district,
               cm.new_id, o.postal_code, o.phone, o.last_update
        FROM address_orig o
        JOIN address_map m ON m.old_id = o.address_id AND m.batch_no BETWEEN chunk_start AND chunk_end
        JOIN city_map cm ON cm.batch_no = m.batch_no AND cm.old_id = o.city_id;

        chunk_start := chunk_end + 1;
    END LOOP;
END $$;

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM address) <> (SELECT COUNT(*) FROM address_orig) * 500 THEN
        RAISE EXCEPTION 'address expansion did not produce exactly 500x rows.';
    END IF;
END $$;

--
-- actor
--
DROP TABLE IF EXISTS actor_orig;
CREATE TEMP TABLE actor_orig AS SELECT actor_id, first_name, last_name, last_update FROM actor;

DROP TABLE IF EXISTS actor_map;
CREATE TEMP TABLE actor_map (batch_no INT NOT NULL, old_id INT NOT NULL, new_id INT NOT NULL, PRIMARY KEY (batch_no, old_id));

INSERT INTO actor_map (batch_no, old_id, new_id)
SELECT bn.n, o.actor_id, nextval('actor_actor_id_seq')
FROM actor_orig o CROSS JOIN batch_numbers bn;

DO $$
DECLARE
    chunk_size INT := 100;
    chunk_start INT := 1;
    chunk_end INT;
BEGIN
    WHILE chunk_start <= 499 LOOP
        chunk_end := LEAST(chunk_start + chunk_size - 1, 499);

        INSERT INTO actor (actor_id, first_name, last_name, last_update)
        SELECT m.new_id, o.first_name, LEFT(o.last_name || '-' || m.batch_no::text, 45), o.last_update
        FROM actor_orig o
        JOIN actor_map m ON m.old_id = o.actor_id
        WHERE m.batch_no BETWEEN chunk_start AND chunk_end;

        chunk_start := chunk_end + 1;
    END LOOP;
END $$;

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM actor) <> (SELECT COUNT(*) FROM actor_orig) * 500 THEN
        RAISE EXCEPTION 'actor expansion did not produce exactly 500x rows.';
    END IF;
END $$;

--
-- customer
--
DROP TABLE IF EXISTS customer_orig;
CREATE TEMP TABLE customer_orig AS
SELECT customer_id, store_id, first_name, last_name, email, address_id, activebool, create_date, last_update, active
FROM customer;

DROP TABLE IF EXISTS customer_map;
CREATE TEMP TABLE customer_map (batch_no INT NOT NULL, old_id INT NOT NULL, new_id INT NOT NULL, PRIMARY KEY (batch_no, old_id));

INSERT INTO customer_map (batch_no, old_id, new_id)
SELECT bn.n, o.customer_id, nextval('customer_customer_id_seq')
FROM customer_orig o CROSS JOIN batch_numbers bn;

DO $$
DECLARE
    chunk_size INT := 100;
    chunk_start INT := 1;
    chunk_end INT;
BEGIN
    WHILE chunk_start <= 499 LOOP
        chunk_end := LEAST(chunk_start + chunk_size - 1, 499);

        INSERT INTO customer (customer_id, store_id, first_name, last_name, email, address_id, activebool, create_date, last_update, active)
        SELECT m.new_id,
               ((o.store_id - 1 + m.batch_no) % 2) + 1,
               o.first_name,
               LEFT(o.last_name || '-' || m.batch_no::text, 45),
               LEFT('gen' || m.batch_no::text || '.' || o.customer_id::text || '@sakila.gen', 50),
               am.new_id,
               o.activebool, o.create_date, o.last_update, o.active
        FROM customer_orig o
        JOIN customer_map m ON m.old_id = o.customer_id AND m.batch_no BETWEEN chunk_start AND chunk_end
        JOIN address_map am ON am.batch_no = m.batch_no AND am.old_id = o.address_id;

        chunk_start := chunk_end + 1;
    END LOOP;
END $$;

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM customer) <> (SELECT COUNT(*) FROM customer_orig) * 500 THEN
        RAISE EXCEPTION 'customer expansion did not produce exactly 500x rows.';
    END IF;
END $$;

--
-- film
-- fulltext is omitted from the column list - film_fulltext_trigger
-- (BEFORE INSERT) populates it from title/description automatically.
--
DROP TABLE IF EXISTS film_orig;
CREATE TEMP TABLE film_orig AS
SELECT film_id, title, description, release_year, language_id, original_language_id,
       rental_duration, rental_rate, length, replacement_cost, rating, special_features, last_update
FROM film;

DROP TABLE IF EXISTS film_map;
CREATE TEMP TABLE film_map (batch_no INT NOT NULL, old_id INT NOT NULL, new_id INT NOT NULL, PRIMARY KEY (batch_no, old_id));

INSERT INTO film_map (batch_no, old_id, new_id)
SELECT bn.n, o.film_id, nextval('film_film_id_seq')
FROM film_orig o CROSS JOIN batch_numbers bn;

DO $$
DECLARE
    chunk_size INT := 100;
    chunk_start INT := 1;
    chunk_end INT;
BEGIN
    WHILE chunk_start <= 499 LOOP
        chunk_end := LEAST(chunk_start + chunk_size - 1, 499);

        INSERT INTO film (film_id, title, description, release_year, language_id, original_language_id,
                           rental_duration, rental_rate, length, replacement_cost, rating, special_features, last_update)
        SELECT m.new_id, LEFT(o.title || '-' || m.batch_no::text, 255), o.description, o.release_year,
               o.language_id, o.original_language_id, o.rental_duration, o.rental_rate, o.length,
               o.replacement_cost, o.rating, o.special_features, o.last_update
        FROM film_orig o
        JOIN film_map m ON m.old_id = o.film_id
        WHERE m.batch_no BETWEEN chunk_start AND chunk_end;

        chunk_start := chunk_end + 1;
    END LOOP;
END $$;

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM film) <> (SELECT COUNT(*) FROM film_orig) * 500 THEN
        RAISE EXCEPTION 'film expansion did not produce exactly 500x rows.';
    END IF;
END $$;

--
-- film_actor (composite PK, no identity - plain INSERT, no map needed)
--
DROP TABLE IF EXISTS film_actor_orig;
CREATE TEMP TABLE film_actor_orig AS SELECT actor_id, film_id, last_update FROM film_actor;

DO $$
DECLARE
    chunk_size INT := 100;
    chunk_start INT := 1;
    chunk_end INT;
BEGIN
    WHILE chunk_start <= 499 LOOP
        chunk_end := LEAST(chunk_start + chunk_size - 1, 499);

        INSERT INTO film_actor (actor_id, film_id, last_update)
        SELECT am.new_id, fm.new_id, o.last_update
        FROM film_actor_orig o
        CROSS JOIN batch_numbers bn
        JOIN actor_map am ON am.batch_no = bn.n AND am.old_id = o.actor_id
        JOIN film_map fm ON fm.batch_no = bn.n AND fm.old_id = o.film_id
        WHERE bn.n BETWEEN chunk_start AND chunk_end;

        chunk_start := chunk_end + 1;
    END LOOP;
END $$;

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM film_actor) <> (SELECT COUNT(*) FROM film_actor_orig) * 500 THEN
        RAISE EXCEPTION 'film_actor expansion did not produce exactly 500x rows.';
    END IF;
END $$;

--
-- film_category (composite PK, no identity - plain INSERT, no map needed)
--
DROP TABLE IF EXISTS film_category_orig;
CREATE TEMP TABLE film_category_orig AS SELECT film_id, category_id, last_update FROM film_category;

DO $$
DECLARE
    chunk_size INT := 100;
    chunk_start INT := 1;
    chunk_end INT;
BEGIN
    WHILE chunk_start <= 499 LOOP
        chunk_end := LEAST(chunk_start + chunk_size - 1, 499);

        INSERT INTO film_category (film_id, category_id, last_update)
        SELECT fm.new_id, o.category_id, o.last_update
        FROM film_category_orig o
        CROSS JOIN batch_numbers bn
        JOIN film_map fm ON fm.batch_no = bn.n AND fm.old_id = o.film_id
        WHERE bn.n BETWEEN chunk_start AND chunk_end;

        chunk_start := chunk_end + 1;
    END LOOP;
END $$;

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM film_category) <> (SELECT COUNT(*) FROM film_category_orig) * 500 THEN
        RAISE EXCEPTION 'film_category expansion did not produce exactly 500x rows.';
    END IF;
END $$;

--
-- inventory
--
DROP TABLE IF EXISTS inventory_orig;
CREATE TEMP TABLE inventory_orig AS SELECT inventory_id, film_id, store_id, last_update FROM inventory;

DROP TABLE IF EXISTS inventory_map;
CREATE TEMP TABLE inventory_map (batch_no INT NOT NULL, old_id INT NOT NULL, new_id INT NOT NULL, PRIMARY KEY (batch_no, old_id));

INSERT INTO inventory_map (batch_no, old_id, new_id)
SELECT bn.n, o.inventory_id, nextval('inventory_inventory_id_seq')
FROM inventory_orig o CROSS JOIN batch_numbers bn;

DO $$
DECLARE
    chunk_size INT := 100;
    chunk_start INT := 1;
    chunk_end INT;
BEGIN
    WHILE chunk_start <= 499 LOOP
        chunk_end := LEAST(chunk_start + chunk_size - 1, 499);

        INSERT INTO inventory (inventory_id, film_id, store_id, last_update)
        SELECT m.new_id, fm.new_id, ((o.store_id - 1 + m.batch_no) % 2) + 1, o.last_update
        FROM inventory_orig o
        JOIN inventory_map m ON m.old_id = o.inventory_id AND m.batch_no BETWEEN chunk_start AND chunk_end
        JOIN film_map fm ON fm.batch_no = m.batch_no AND fm.old_id = o.film_id;

        chunk_start := chunk_end + 1;
    END LOOP;
END $$;

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM inventory) <> (SELECT COUNT(*) FROM inventory_orig) * 500 THEN
        RAISE EXCEPTION 'inventory expansion did not produce exactly 500x rows.';
    END IF;
END $$;

--
-- rental
-- unique index (rental_date, inventory_id, customer_id) is satisfied
-- automatically: inventory_id is unique per batch, so the tuple can never
-- collide with the original row or another batch's row even though
-- rental_date is copied unchanged.
--
DROP TABLE IF EXISTS rental_orig;
CREATE TEMP TABLE rental_orig AS
SELECT rental_id, rental_date, inventory_id, customer_id, return_date, staff_id, last_update FROM rental;

DROP TABLE IF EXISTS rental_map;
CREATE TEMP TABLE rental_map (batch_no INT NOT NULL, old_id INT NOT NULL, new_id INT NOT NULL, PRIMARY KEY (batch_no, old_id));

INSERT INTO rental_map (batch_no, old_id, new_id)
SELECT bn.n, o.rental_id, nextval('rental_rental_id_seq')
FROM rental_orig o CROSS JOIN batch_numbers bn;

DO $$
DECLARE
    chunk_size INT := 100;
    chunk_start INT := 1;
    chunk_end INT;
BEGIN
    WHILE chunk_start <= 499 LOOP
        chunk_end := LEAST(chunk_start + chunk_size - 1, 499);

        INSERT INTO rental (rental_id, rental_date, inventory_id, customer_id, return_date, staff_id, last_update)
        SELECT m.new_id, o.rental_date, im.new_id, cm.new_id, o.return_date,
               ((o.staff_id - 1 + m.batch_no) % 2) + 1, o.last_update
        FROM rental_orig o
        JOIN rental_map m ON m.old_id = o.rental_id AND m.batch_no BETWEEN chunk_start AND chunk_end
        JOIN inventory_map im ON im.batch_no = m.batch_no AND im.old_id = o.inventory_id
        JOIN customer_map cm ON cm.batch_no = m.batch_no AND cm.old_id = o.customer_id;

        chunk_start := chunk_end + 1;
    END LOOP;
END $$;

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM rental) <> (SELECT COUNT(*) FROM rental_orig) * 500 THEN
        RAISE EXCEPTION 'rental expansion did not produce exactly 500x rows.';
    END IF;
END $$;

--
-- payment
-- Nothing FKs to payment - plain INSERT, no map needed. payment_date is
-- copied unchanged, so generated rows are routed by the existing
-- payment_insert_p2007_0X RULEs exactly the same way the original rows
-- are (into a payment_p2007_0X child if payment_date falls in Jan-Jun
-- 2007, otherwise into the base payment table).
--
DROP TABLE IF EXISTS payment_orig;
CREATE TEMP TABLE payment_orig AS
SELECT payment_id, customer_id, staff_id, rental_id, amount, payment_date FROM payment;

DO $$
DECLARE
    chunk_size INT := 100;
    chunk_start INT := 1;
    chunk_end INT;
BEGIN
    WHILE chunk_start <= 499 LOOP
        chunk_end := LEAST(chunk_start + chunk_size - 1, 499);

        INSERT INTO payment (customer_id, staff_id, rental_id, amount, payment_date)
        SELECT cm.new_id,
               ((o.staff_id - 1 + bn.n) % 2) + 1,
               rm.new_id,
               o.amount, o.payment_date
        FROM payment_orig o
        CROSS JOIN batch_numbers bn
        JOIN customer_map cm ON cm.batch_no = bn.n AND cm.old_id = o.customer_id
        JOIN rental_map rm ON rm.batch_no = bn.n AND rm.old_id = o.rental_id
        WHERE bn.n BETWEEN chunk_start AND chunk_end;

        chunk_start := chunk_end + 1;
    END LOOP;
END $$;

DO $$
BEGIN
    IF (SELECT COUNT(*) FROM payment) <> (SELECT COUNT(*) FROM payment_orig) * 500 THEN
        RAISE EXCEPTION 'payment expansion did not produce exactly 500x rows.';
    END IF;
END $$;

--
-- FK-integrity check
--
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM city c WHERE NOT EXISTS (SELECT 1 FROM country co WHERE co.country_id = c.country_id)) THEN
        RAISE EXCEPTION 'orphaned city.country_id found after expansion.';
    END IF;
    IF EXISTS (SELECT 1 FROM address a WHERE NOT EXISTS (SELECT 1 FROM city c WHERE c.city_id = a.city_id)) THEN
        RAISE EXCEPTION 'orphaned address.city_id found after expansion.';
    END IF;
    IF EXISTS (SELECT 1 FROM customer cu WHERE NOT EXISTS (SELECT 1 FROM address a WHERE a.address_id = cu.address_id)) THEN
        RAISE EXCEPTION 'orphaned customer.address_id found after expansion.';
    END IF;
    IF EXISTS (SELECT 1 FROM film_actor fa WHERE NOT EXISTS (SELECT 1 FROM actor a WHERE a.actor_id = fa.actor_id)
                                          OR NOT EXISTS (SELECT 1 FROM film f WHERE f.film_id = fa.film_id)) THEN
        RAISE EXCEPTION 'orphaned film_actor row found after expansion.';
    END IF;
    IF EXISTS (SELECT 1 FROM film_category fc WHERE NOT EXISTS (SELECT 1 FROM film f WHERE f.film_id = fc.film_id)) THEN
        RAISE EXCEPTION 'orphaned film_category.film_id found after expansion.';
    END IF;
    IF EXISTS (SELECT 1 FROM inventory i WHERE NOT EXISTS (SELECT 1 FROM film f WHERE f.film_id = i.film_id)) THEN
        RAISE EXCEPTION 'orphaned inventory.film_id found after expansion.';
    END IF;
    IF EXISTS (SELECT 1 FROM rental r WHERE NOT EXISTS (SELECT 1 FROM inventory i WHERE i.inventory_id = r.inventory_id)
                                        OR NOT EXISTS (SELECT 1 FROM customer c WHERE c.customer_id = r.customer_id)) THEN
        RAISE EXCEPTION 'orphaned rental row found after expansion.';
    END IF;
    IF EXISTS (SELECT 1 FROM payment p WHERE NOT EXISTS (SELECT 1 FROM customer c WHERE c.customer_id = p.customer_id)) THEN
        RAISE EXCEPTION 'orphaned payment.customer_id found after expansion.';
    END IF;
END $$;

-- Mark the expansion complete.
UPDATE sakila_expansion_log SET completed_at = now()
WHERE expansion_id = (SELECT MAX(expansion_id) FROM sakila_expansion_log);

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

-- Actual on-disk size, by table (run after the load to see real numbers,
-- not just the row-count estimate from the plan doc). pg_total_relation_size
-- includes indexes and TOAST; payment is summed across its partition
-- children too.
SELECT relname AS table_name,
       pg_size_pretty(pg_total_relation_size(oid)) AS total_size
FROM pg_class
WHERE relname IN ('country','city','address','actor','customer','film','film_actor',
                   'film_category','inventory','rental','payment',
                   'payment_p2007_01','payment_p2007_02','payment_p2007_03',
                   'payment_p2007_04','payment_p2007_05','payment_p2007_06',
                   'language','category','store','staff')
  AND relkind = 'r'
ORDER BY pg_total_relation_size(oid) DESC;

-- Cleanup (cosmetic - TEMP tables drop on session end anyway)
DROP TABLE IF EXISTS batch_numbers, country_orig, country_map, city_orig, city_map,
    address_orig, address_map, actor_orig, actor_map, customer_orig, customer_map,
    film_orig, film_map, film_actor_orig, film_category_orig, inventory_orig,
    inventory_map, rental_orig, rental_map, payment_orig;
