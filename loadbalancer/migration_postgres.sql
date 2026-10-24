-- PostgreSQL migration: creates all tables and indexes from scratch.
-- Run this once against your PostgreSQL database before starting the app.
-- Combines the base schema + migration 001 (click tracking) + migration 002 (owner scoping).

CREATE TABLE IF NOT EXISTS url_shortner (
  id           BIGSERIAL     PRIMARY KEY,
  original_url VARCHAR(2048),
  short_url    VARCHAR(255),
  click_count  BIGINT        NOT NULL DEFAULT 0,
  created_at   TIMESTAMP     NULL,
  owner_id     VARCHAR(64)   NULL
);

CREATE INDEX IF NOT EXISTS idx_url_shortner_owner_id
  ON url_shortner(owner_id);

CREATE TABLE IF NOT EXISTS link_click_event (
  id         BIGSERIAL    PRIMARY KEY,
  code       VARCHAR(64)  NOT NULL,
  clicked_at TIMESTAMP    NOT NULL,
  owner_id   VARCHAR(64)  NULL
);

CREATE INDEX IF NOT EXISTS idx_link_click_event_code
  ON link_click_event(code);

CREATE INDEX IF NOT EXISTS idx_link_click_event_clicked_at
  ON link_click_event(clicked_at);

CREATE INDEX IF NOT EXISTS idx_link_click_event_owner_id
  ON link_click_event(owner_id);
