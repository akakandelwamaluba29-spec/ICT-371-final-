-- ICT371 Advanced Database | Student No: 202400526
-- Question 9: Farmer Cooperative Maize Deliveries (PostgreSQL / PL/pgSQL)

DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

-- (a) Tables ------------------------------------------------------------------
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20) NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL,
    unit_rate    NUMERIC(10,2) NOT NULL,     -- both filled in by the trigger
    total_value  NUMERIC(14,2) NOT NULL,
    delivered_on DATE NOT NULL,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(14,2) NOT NULL,
    total_value   NUMERIC(14,2) NOT NULL
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Lewis Mwanza'),
    ('F002', 'Beatrice Kasonde'),
    ('F003', 'Patrick Lubinda');

-- (b) Function -----------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade VARCHAR)
RETURNS NUMERIC AS $$
DECLARE
    v_rate NUMERIC;
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade is required';
    END IF;

    v_rate := CASE UPPER(p_grade) WHEN 'A' THEN 5 WHEN 'B' THEN 4 WHEN 'C' THEN 3 END;
    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
    END IF;
    RETURN v_rate;
END;
$$ LANGUAGE plpgsql;

-- (d) Trigger ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_price_delivery() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_price_delivery
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_price_delivery();

-- (c) Procedure ----------------------------------------------------------------
-- Inserts only the basic fields; the trigger supplies unit_rate and total_value.
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INTEGER, p_grade VARCHAR, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date is required';
    END IF;
    PERFORM fn_maize_rate(p_grade);     -- rejects NULL or unsupported grades early

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, UPPER(p_grade), p_weight, p_date, FALSE);
END;
$$;

-- (a) Six deliveries (all grades, both payment states), loaded after the trigger exists
CALL pr_receive_delivery(1, 'A', 200, CURRENT_DATE - 2);
CALL pr_receive_delivery(1, 'B', 150, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'C', 300, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'A', 100, CURRENT_DATE);
-- direct SQL follows the same pricing rule via the trigger (these two are already paid)
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
VALUES (3, 'B', 250, 0, 0, CURRENT_DATE - 2, TRUE),
       (3, 'C',  80, 0, 0, CURRENT_DATE - 1, TRUE);   -- 0 placeholders are overwritten by the trigger

SELECT delivery_id, farmer_id, grade, weight_kg, unit_rate, total_value, is_paid FROM deliveries ORDER BY 1;
SELECT fn_maize_rate('A') AS a, fn_maize_rate('B') AS b, fn_maize_rate('C') AS c;
-- SELECT fn_maize_rate('D');                           -- fails: unsupported grade
-- CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE); -- fails: unknown farmer
-- CALL pr_receive_delivery(1, 'A', -5, CURRENT_DATE);  -- fails: invalid weight

-- (e) View -----------------------------------------------------------------------
-- The unpaid filter is in the JOIN condition so farmers with no unpaid deliveries
-- still appear, with a total of zero.
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       COALESCE(SUM(d.total_value), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;

-- (f) Index ----------------------------------------------------------------------
-- (farmer_id, delivered_on): equality on the farmer then a date range.
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

SET enable_seqscan = off;
EXPLAIN
SELECT * FROM deliveries
WHERE farmer_id = 1 AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job ----------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
    FROM deliveries WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
        SET total_weight = EXCLUDED.total_weight,
            total_value  = EXCLUDED.total_value;   -- replaces, never adds again
END;
$$;

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);   -- rerun: same totals
SELECT * FROM daily_purchases;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh-purchases-daily', '30 1 * * *',
                     $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$);
