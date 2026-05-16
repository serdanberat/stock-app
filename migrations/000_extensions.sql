-- Migration 000_extensions.sql
-- PostgreSQL extensions required by the schema.
-- Idempotent: safe to run multiple times.

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";    -- UUID generation
CREATE EXTENSION IF NOT EXISTS "pgcrypto";     -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS pg_trgm;        -- Trigram text search
CREATE EXTENSION IF NOT EXISTS btree_gist;     -- EXCLUDE constraints (variant_prices)
CREATE EXTENSION IF NOT EXISTS citext;         -- Case-insensitive text (users.email)
