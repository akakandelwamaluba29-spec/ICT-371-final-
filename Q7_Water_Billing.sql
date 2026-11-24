-- ICT371 Advanced Database | Student No: 202400526
-- Question 7: Water Meter Readings and Billing (PostgreSQL / PL/pgSQL)

DROP TABLE IF EXISTS receivable_snapshot, bills, readings, customers CASCADE;

-- (a) Tables ------------------------------------------------------------------
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL,
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT chk_reading_month_start CHECK (EXTRACT(DAY FROM reading_month) = 1),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE NOT NULL,
    CONSTRAINT chk_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL
);

INSERT INTO customers (full_name) VALUES ('Moses Kapambwe'), ('Agnes Sinkala'), ('Felix Musonda');

-- (d) Trigger (installed before readings are loaded) ------------------------------
CREATE OR REPLACE FUNCTION trg_fn_check_reading() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;      -- raising aborts the statement, so a bad reading is never stored
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_reading
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_reading();

-- Six readings: units used = 0, 10, 15, 25, 10, 0
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-09-01', 100, 100),   --  0 units
    (1, DATE '2026-10-01', 100, 110),   -- 10 units
    (2, DATE '2026-09-01',  50,  65),   -- 15 units
    (2, DATE '2026-10-01',  65,  90),   -- 25 units
    (3, DATE '2026-09-01',  10,  20),   -- 10 units
    (3, DATE '2026-10-01',  20,  20);   --  0 units

-- (b) Function -----------------------------------------------------------------
-- First 10 units at K5, units above 10 at K8.
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2) AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption: %', p_units;
    END IF;

    IF p_units <= 10 THEN
        RETURN ROUND(p_units * 5, 2);
    END IF;
    RETURN ROUND(10 * 5 + (p_units - 10) * 8, 2);
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure ----------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_prev NUMERIC(10,2);
    v_curr NUMERIC(10,2);
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date is required';
    END IF;

    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings WHERE reading_id = p_reading_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, fn_water_charge(v_curr - v_prev), 0, p_due_on);
END;
$$;

-- Bills for all six readings (some already past due so the overdue view has data)
CALL pr_generate_bill(1, CURRENT_DATE - 40);
CALL pr_generate_bill(2, CURRENT_DATE - 10);
CALL pr_generate_bill(3, CURRENT_DATE - 40);
CALL pr_generate_bill(4, CURRENT_DATE - 10);
CALL pr_generate_bill(5, CURRENT_DATE + 10);
CALL pr_generate_bill(6, CURRENT_DATE + 10);

UPDATE bills SET amount_paid = 40 WHERE bill_id = 3;      -- partly paid (charge is 90)
UPDATE bills SET amount_paid = charge WHERE bill_id = 4;  -- fully paid

SELECT fn_water_charge(0) AS zero, fn_water_charge(10) AS ten, fn_water_charge(15) AS fifteen;  -- 0, 50, 90
-- CALL pr_generate_bill(1, CURRENT_DATE);                -- fails: already billed
-- CALL pr_generate_bill(99, CURRENT_DATE);               -- fails: unknown reading
-- INSERT INTO readings VALUES (DEFAULT, 1, DATE '2026-11-01', 110, 100);  -- fails: trigger

-- (e) View ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name, b.due_on, b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills;

-- (f) Index --------------------------------------------------------------------
-- Partial index on due_on covering only unpaid bills: overdue searches are
-- date-based and only touch unpaid rows, so fully paid bills are kept out.
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;

SET enable_seqscan = off;
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE amount_paid < charge AND due_on < CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM bills
    WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
        SET total_due = EXCLUDED.total_due;   -- same date is replaced, not added
END;
$$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();   -- rerun: same total
SELECT * FROM receivable_snapshot;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh-receivables-daily', '30 0 * * *',
                     $$CALL pr_refresh_receivables()$$);
