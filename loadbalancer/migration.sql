-- Run this once against your appdb database before starting the app with the
-- new click-tracking code. spring.jpa.hibernate.ddl-auto=none means Hibernate
-- will not create or alter tables for you.
--
-- Assumes Spring's default naming strategy, which maps the UrlShortner entity
-- to a table named `url_shortner` with columns `id`, `original_url`,
-- `short_url`. If your existing table uses different names, adjust below to
-- match before running.

ALTER TABLE url_shortner
  ADD COLUMN click_count BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN created_at DATETIME NULL;

CREATE TABLE link_click_event (
  id BIGINT NOT NULL AUTO_INCREMENT,
  code VARCHAR(64) NOT NULL,
  clicked_at DATETIME NOT NULL,
  PRIMARY KEY (id),
  KEY idx_link_click_event_code (code),
  KEY idx_link_click_event_clicked_at (clicked_at)
);
