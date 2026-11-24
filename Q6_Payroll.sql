-- ICT371 Advanced Database | Student No: 202400526
-- Question 6: Monthly Payroll Processing (PostgreSQL / PL/pgSQL)

DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

-- (a) Tables ------------------------------------------------------------------
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL,
    net_pay     NUMERIC(12,2) NOT NULL,
    CONSTRAINT chk_pay_month_start CHECK (EXTRACT(DAY FROM pay_month) = 1),
    CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Alice Tembo',   8000.00, 1500.00, 1200.00, TRUE),
    ('Bwalya Mumba',  6000.00, 1000.00,  900.00, TRUE),
    ('Charles Zulu',  5000.00,  500.00,  700.00, TRUE),
    ('Dorothy Banda', 7000.00, 1200.00, 1000.00, TRUE);   -- becomes inactive later

-- (b) Function -----------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC AS $$
DECLARE
    v_basic NUMERIC(12,2);
    v_allow NUMERIC(12,2);
    v_ded   NUMERIC(12,2);
    v_net   NUMERIC(12,2);
BEGIN
    SELECT basic_salary, allowance, deduction INTO v_basic, v_allow, v_ded
    FROM employees WHERE employee_id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;

    v_net := v_basic + v_allow - v_ded;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;
    RETURN v_net;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure ----------------------------------------------------------------
-- A failure inside the loop aborts the whole CALL, so no partial month is stored.
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'p_month must be the first day of a month (got %)', p_month;
    END IF;

    FOR rec IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active = TRUE
        ORDER BY employee_id
    LOOP
        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month,
                rec.basic_salary + rec.allowance,
                fn_net_pay(rec.employee_id))          -- raises on an invalid calculation
        ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing rows stay unchanged
    END LOOP;
END;
$$;

-- (d) Trigger ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_salary_audit() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary, now());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- (a) Two payroll months (first day of month), then one employee becomes inactive
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');
CALL pr_process_payroll(DATE '2026-10-01');   -- rerun: nothing duplicated or changed

UPDATE employees SET active = FALSE WHERE employee_id = 4;           -- no audit row
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;      -- audit row
UPDATE employees SET allowance = 1600 WHERE employee_id = 1;         -- no audit row

SELECT fn_net_pay(1) AS alice_net;
SELECT * FROM salary_audit;
-- CALL pr_process_payroll(DATE '2026-11-15');   -- fails: not a month start
-- SELECT fn_net_pay(99);                        -- fails: unknown employee

-- (e) View ---------------------------------------------------------------------
-- Inner join to employees without filtering on active keeps inactive employees' history.
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- (f) Index --------------------------------------------------------------------
-- The unique index on (employee_id, pay_month) leads with employee_id, so it cannot
-- serve a search on pay_month alone. This index on pay_month does not duplicate it.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

SET enable_seqscan = off;
EXPLAIN
SELECT * FROM payroll WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------------
-- 02:00 on day 1 of each month, passing the first date of the previous month.
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('process-payroll-monthly', '0 2 1 * *',
    $$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);

-- Inspect the job and its run history
SELECT jobid, jobname, schedule, command, active FROM cron.job;
SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
ORDER BY start_time DESC;
