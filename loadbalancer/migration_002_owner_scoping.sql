-- Run this once against your appdb database to add per-browser ownership
-- scoping, so /api/links and the analytics chart only show the requesting
-- browser's own links instead of every link ever created.
--
-- Existing rows (created before this migration) get owner_id = NULL, which
-- will never match a real client id, so old/test data simply stops showing
-- up anywhere rather than being deleted.

ALTER TABLE url_shortner
  ADD COLUMN owner_id VARCHAR(64) NULL,
  ADD INDEX idx_url_shortner_owner_id (owner_id);

ALTER TABLE link_click_event
  ADD COLUMN owner_id VARCHAR(64) NULL,
  ADD INDEX idx_link_click_event_owner_id (owner_id);
