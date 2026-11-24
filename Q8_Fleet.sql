-- ICT371 Advanced Database | Student No: 202400526
-- Question 8: Transport Fleet Maintenance (PostgreSQL / PL/pgSQL)

DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

-- (a) Tables ------------------------------------------------------------------
CREATE TABLE vehicles (
    vehicle_id             SERIAL PRIMARY KEY,
    registration           VARCHAR(15) NOT NULL UNIQUE,
    current_odometer       INTEGER NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer  INTEGER NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INTEGER NOT NULL CHECK (end_odometer >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INTEGER NOT NULL,
    flagged_on       DATE NOT NULL
);

-- Three vehicles with different service positions
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('BAK 1234', 10000,  4000),   -- 6000 km since service: due
    ('BAL 5678', 12000, 10000),   -- 2000 km since service: not due
    ('BAM 9012',  8000,  3000);   -- exactly 5000 km: due

-- (d) Trigger (installed before trips are added) -------------------------------
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer() RETURNS TRIGGER AS $$
DECLARE
    v_current INTEGER;
BEGIN
    IF NEW.start_odometer IS NULL OR NEW.end_odometer IS NULL
       OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end (%) must be greater than start (%)',
                        NEW.end_odometer, NEW.start_odometer;
    END IF;

    SELECT current_odometer INTO v_current
    FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Start odometer % does not match current odometer % for vehicle %',
                        NEW.start_odometer, v_current, NEW.vehicle_id;
    END IF;

    UPDATE vehicles SET current_odometer = NEW.end_odometer   -- done once, here only
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer();

-- (b) Function -----------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN AS $$
DECLARE
    v_current INTEGER;
    v_service INTEGER;
BEGIN
    SELECT current_odometer, last_service_odometer INTO v_current, v_service
    FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_current - v_service) >= 5000;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure ----------------------------------------------------------------
-- Does NOT touch vehicles.current_odometer; the trigger does that.
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INTEGER, p_trip_on DATE, p_start INTEGER, p_end INTEGER)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date, start and end odometer are required';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'End odometer (%) must be greater than start odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- (a) Six trips through the procedure, each starting at the vehicle's current odometer
CALL pr_record_trip(1, CURRENT_DATE - 6, 10000, 10120);
CALL pr_record_trip(1, CURRENT_DATE - 3, 10120, 10300);
CALL pr_record_trip(2, CURRENT_DATE - 5, 12000, 12150);
CALL pr_record_trip(2, CURRENT_DATE - 2, 12150, 12300);
CALL pr_record_trip(3, CURRENT_DATE - 4,  8000,  8050);
CALL pr_record_trip(3, CURRENT_DATE - 1,  8050,  8200);

SELECT vehicle_id, registration, current_odometer, fn_service_due(vehicle_id) AS due FROM vehicles ORDER BY 1;
-- CALL pr_record_trip(2, CURRENT_DATE, 9999, 10100);   -- fails: start does not match odometer
-- CALL pr_record_trip(2, CURRENT_DATE, 12300, 12300);  -- fails: end not greater than start
-- SELECT fn_service_due(99);                           -- fails: unknown vehicle

-- (e) View -----------------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due;

-- (f) Index ----------------------------------------------------------------------
-- (vehicle_id, trip_on): equality on the vehicle, then a range on the date, giving a
-- single ordered index range scan for one vehicle's trips in a period.
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);

SET enable_seqscan = off;
EXPLAIN
SELECT * FROM trips
WHERE vehicle_id = 1 AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job ----------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    -- one alert per due vehicle: insert new, refresh km on existing (keep first flagged date)
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT v.vehicle_id, v.current_odometer - v.last_service_odometer, CURRENT_DATE
    FROM vehicles v
    WHERE fn_service_due(v.vehicle_id)
    ON CONFLICT (vehicle_id) DO UPDATE
        SET km_since_service = EXCLUDED.km_since_service;

    -- remove alerts for vehicles that are no longer due (e.g. after a service)
    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (
        SELECT 1 FROM vehicles v
        WHERE v.vehicle_id = sa.vehicle_id AND fn_service_due(v.vehicle_id)
    );
END;
$$;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;

-- Servicing vehicle 1 clears its alert on the next run
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 1;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh-service-alerts-weekly', '0 6 * * 1',
                     $$CALL pr_refresh_service_alerts()$$);
