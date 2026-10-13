ALTER TABLE downtime_log ADD COLUMN reason TEXT;
UPDATE downtime_log SET reason = cause;
