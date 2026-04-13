-- Runs automatically on first container start (executed as the container superuser).
-- Enables both pgvector and Apache AGE in codeloom_dev.
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS age;
