-- ICT371 Advanced Database | Student No: 202400526
-- Question 10: Scholarship Application Assessment (PostgreSQL / PL/pgSQL)

DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

-- (a) Tables ------------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE NOT NULL,
    status             VARCHAR(10) NOT NULL DEFAULT 'PENDING',
    CONSTRAINT chk_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
    ('202400301', 'Mutinta Hamusonde'),
    ('202400302', 'Joseph Kalaba'),
    ('202400303', 'Patience Simfukwe');

-- Six PENDING applications: qualifying, non-qualifying and boundary cases
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
    (1, 18, 3000.00, 70.00, CURRENT_DATE - 12),   -- qualifies (all three at the boundary)
    (1, 25, 2000.00, 85.00, CURRENT_DATE - 10),   -- qualifies (upper age boundary)
    (2, 17, 1000.00, 90.00, CURRENT_DATE - 8),    -- too young
    (2, 22, 3000.01, 80.00, CURRENT_DATE - 6),    -- income just over limit
    (3, 26, 1500.00, 75.00, CURRENT_DATE - 4),    -- too old
    (3, 20, 2500.00, 69.99, CURRENT_DATE - 2);    -- mark just under limit

-- (b) Function -----------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INTEGER, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark are all required';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive (got %)', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative (got %)', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100 (got %)', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark >= 70;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure ----------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_app applications%ROWTYPE;
BEGIN
    SELECT * INTO v_app FROM applications
    WHERE application_id = p_application_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application % does not exist', p_application_id;
    END IF;
    IF v_app.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status: %)',
                        p_application_id, v_app.status;
    END IF;

    UPDATE applications
    SET status = CASE
            WHEN fn_scholarship_eligible(v_app.age_at_application,
                                         v_app.monthly_income,
                                         v_app.average_mark)
            THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

-- (d) Trigger ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_decision_audit() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, now());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

-- Tests
SELECT fn_scholarship_eligible(18, 3000, 70)    AS all_boundaries_ok,   -- true
       fn_scholarship_eligible(25, 3000, 70)    AS age_25_ok,           -- true
       fn_scholarship_eligible(26, 1000, 90)    AS too_old,             -- false
       fn_scholarship_eligible(20, 3000.01, 90) AS income_over,         -- false
       fn_scholarship_eligible(20, 1000, 69.99) AS mark_under;          -- false
-- SELECT fn_scholarship_eligible(NULL, 1000, 80);   -- fails: NULL input
-- SELECT fn_scholarship_eligible(20, 1000, 101);    -- fails: mark out of range

CALL pr_assess_application(1);
SELECT application_id, status FROM applications ORDER BY 1;
SELECT * FROM decision_audit;
-- CALL pr_assess_application(1);    -- fails: already assessed
-- CALL pr_assess_application(99);   -- fails: unknown application

-- (e) View -----------------------------------------------------------------------
-- Household income is deliberately left out.
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) Index ----------------------------------------------------------------------
-- (status, submitted_on): equality on status then a range on submitted_on.
CREATE INDEX idx_app_status_submitted ON applications (status, submitted_on);

SET enable_seqscan = off;
EXPLAIN
SELECT * FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job ----------------------------------------------------------------
-- Only PENDING rows are selected, so completed applications are never reassessed and
-- no duplicate audit rows appear on a rerun.
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT application_id FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

CALL pr_assess_pending();
CALL pr_assess_pending();   -- rerun: nothing pending, so nothing happens
SELECT * FROM v_approved_applicants;
SELECT * FROM decision_audit ORDER BY audit_id;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('assess-pending-weekly', '0 8 * * 1',
                     $$CALL pr_assess_pending()$$);
