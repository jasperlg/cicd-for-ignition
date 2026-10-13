-- expand: add the new column and backfill it from the old one
ALTER TABLE downtime_log ADD COLUMN cause TEXT;
UPDATE downtime_log SET cause = reason;
