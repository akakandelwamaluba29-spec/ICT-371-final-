-- ICT371 Advanced Database | Student No: 202400526
-- Question 4: Clinic Appointment Scheduling (PostgreSQL / PL/pgSQL)

DROP TABLE IF EXISTS clinic_summary, appointments, doctors, patients CASCADE;

-- (a) Tables ------------------------------------------------------------------
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL,
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT chk_status CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED')),
    CONSTRAINT chk_slot   CHECK (slot_time IN ('09:00', '10:00', '11:00', '12:00'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL,
    attended_count  INTEGER NOT NULL,
    cancelled_count INTEGER NOT NULL
);

INSERT INTO patients (full_name) VALUES ('Alice Mwale'), ('Brian Sakala'), ('Chipo Daka');
INSERT INTO doctors  (full_name) VALUES ('Dr. Banda'), ('Dr. Phiri'), ('Dr. Zimba');

-- (d) Trigger (installed before the seed data so every row is checked) --------
CREATE OR REPLACE FUNCTION trg_fn_check_clash() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        IF EXISTS (
            SELECT 1 FROM appointments a
            WHERE a.doctor_id       = NEW.doctor_id
              AND a.appointment_day = NEW.appointment_day
              AND a.slot_time       = NEW.slot_time
              AND a.status         <> 'CANCELLED'
              AND a.appointment_id IS DISTINCT FROM NEW.appointment_id  -- exclude the row being changed
        ) THEN
            RAISE EXCEPTION 'Clash: doctor % already has a booking on % at %',
                            NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_appointment_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_clash();

-- (a) Six appointments, no slot clashes
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE - 2, '09:00', 'ATTENDED'),
    (2, 1, CURRENT_DATE - 2, '10:00', 'CANCELLED'),
    (3, 2, CURRENT_DATE - 1, '09:00', 'ATTENDED'),
    (1, 2, CURRENT_DATE,     '10:00', 'BOOKED'),
    (2, 3, CURRENT_DATE,     '11:00', 'BOOKED'),
    (3, 1, CURRENT_DATE + 1, '12:00', 'BOOKED');

-- (b) Function -----------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count          -- COUNT returns 0 when the day has no bookings
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure ------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INTEGER, p_doctor_id INTEGER,
                                                p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is in the past', p_day;
    END IF;

    IF p_slot IS NULL OR p_slot NOT IN ('09:00', '10:00', '11:00', '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot: % (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
    END IF;

    -- the trigger rejects any clash with a non-cancelled appointment
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- Tests
CALL pr_book_appointment(2, 2, CURRENT_DATE + 2, '09:00');
SELECT fn_daily_load(1, CURRENT_DATE - 2) AS dr_banda_load;   -- 1 (cancelled one not counted)
SELECT fn_daily_load(3, CURRENT_DATE + 30) AS empty_day;      -- 0
-- CALL pr_book_appointment(1, 2, CURRENT_DATE + 2, '09:00'); -- fails: clash
-- CALL pr_book_appointment(1, 2, CURRENT_DATE - 1, '09:00'); -- fails: past date
-- CALL pr_book_appointment(1, 2, CURRENT_DATE + 3, '13:00'); -- fails: unsupported slot

-- (e) View -----------------------------------------------------------------------
-- Only the names and slot are exposed; no patient IDs or other patient data.
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time;

-- (f) Index ----------------------------------------------------------------------
-- Non-unique composite index on (appointment_day, doctor_id): the same columns the
-- clash trigger, the daily load function and the daily reports filter on.
CREATE INDEX idx_appt_day_doctor ON appointments (appointment_day, doctor_id);

SET enable_seqscan = off;
EXPLAIN
SELECT * FROM appointments
WHERE appointment_day = CURRENT_DATE AND doctor_id = 2;
RESET enable_seqscan;

-- (g) Scheduled job ----------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
        SET booked_count    = EXCLUDED.booked_count,
            attended_count  = EXCLUDED.attended_count,
            cancelled_count = EXCLUDED.cancelled_count;   -- replaces on rerun
END;
$$;

CALL pr_refresh_clinic_summary(CURRENT_DATE - 2);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 2);   -- rerun: still one row
SELECT * FROM clinic_summary;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh-clinic-summary-daily', '0 1 * * *',
                     $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);
