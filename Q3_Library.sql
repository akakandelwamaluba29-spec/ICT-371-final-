-- ICT371 Advanced Database | Student No: 202400526
-- Question 3: Library Returns and Overdue Fines (PostgreSQL / PL/pgSQL)

DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

-- (a) Tables and seed data ------------------------------------------------------
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL,
    returned_on   DATE NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT chk_due_after_borrowed CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id         SERIAL PRIMARY KEY,
    loan_id          INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE NULL,
    new_returned_on  DATE NULL,
    changed_at       TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL,
    total_fine    NUMERIC(12,2) NOT NULL
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Introduction to Algorithms'),
    ('Clean Code');

-- Six loans: open overdue (1, 2), on-time open (3, 4), returned (5, 6)
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on) VALUES
    (1, 'Chanda Mumba',  CURRENT_DATE - 30, CURRENT_DATE - 16, NULL),               -- overdue 16 days
    (2, 'Natasha Zulu',  CURRENT_DATE - 20, CURRENT_DATE - 6,  NULL),               -- overdue 6 days
    (3, 'Peter Tembo',   CURRENT_DATE - 5,  CURRENT_DATE + 9,  NULL),               -- not yet due
    (1, 'Mwila Chola',   CURRENT_DATE - 14, CURRENT_DATE,      NULL),               -- due today: no fine
    (2, 'Esther Lungu',  CURRENT_DATE - 40, CURRENT_DATE - 26, CURRENT_DATE - 24),  -- returned late
    (3, 'Joseph Kunda',  CURRENT_DATE - 25, CURRENT_DATE - 11, CURRENT_DATE - 12);  -- returned early

-- (b) Function --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of date is required';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));   -- earlier of as-of and return
    RETURN 2 * GREATEST(v_end - v_due, 0);                    -- K2 per day, minimum 0
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure -------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date is required';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % has already been returned', p_loan_id;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrowed date %', p_returned_on, v_borrowed;
    END IF;

    -- return date and final fine are stored together in one UPDATE
    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = fn_loan_fine(p_loan_id, p_returned_on)
    WHERE loan_id = p_loan_id;
END;
$$;

-- (d) Trigger ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_loan_audit() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on, now());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_fn_loan_audit();

-- Tests
SELECT loan_id, fn_loan_fine(loan_id, CURRENT_DATE) AS fine_today FROM loans ORDER BY loan_id;
CALL pr_return_loan(4, CURRENT_DATE);        -- returned on due date: fine 0
SELECT * FROM loans WHERE loan_id = 4;
SELECT * FROM loan_audit;
-- CALL pr_return_loan(4, CURRENT_DATE);     -- fails: already returned
-- CALL pr_return_loan(99, CURRENT_DATE);    -- fails: unknown loan

-- (e) View ------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- (f) Index -----------------------------------------------------------------------
-- Partial index: only unreturned loans are indexed, so it stays small and exactly
-- matches "a given book's unreturned loans".
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;

SET enable_seqscan = off;
EXPLAIN
SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;
RESET enable_seqscan;

-- (g) Scheduled job ----------------------------------------------------------------
-- Counts loans that are unreturned as of p_as_of AND overdue (due before that date),
-- and sums their fines as of that date. Same snapshot_date is replaced on rerun.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE (returned_on IS NULL OR returned_on > p_as_of)
      AND due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
        SET overdue_count = EXCLUDED.overdue_count,
            total_fine    = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);   -- rerun: row replaced
SELECT * FROM overdue_summary;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh-overdue-daily', '10 0 * * *',
                     $$CALL pr_refresh_overdue(CURRENT_DATE)$$);
