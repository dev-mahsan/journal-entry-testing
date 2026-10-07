-- =============================================================
-- 01_load_and_explore.sql
-- Step 1: load raw CSVs into staging tables and profile the data
-- Run in psql (the \copy lines need psql, not pgAdmin's query tool)
-- =============================================================

-- Staging tables keep everything as TEXT on purpose.
-- Raw data is messy; if we force types now, bad rows fail to load
-- and we never get to see what was wrong with them.

DROP TABLE IF EXISTS stg_journal_entries;
CREATE TABLE stg_journal_entries (
    je_id            TEXT,
    line_no          TEXT,
    posting_date     TEXT,
    entry_timestamp  TEXT,
    account_code     TEXT,
    account_name     TEXT,
    description      TEXT,
    debit            TEXT,
    credit           TEXT,
    posted_by        TEXT,
    approved_by      TEXT,
    source           TEXT
);

DROP TABLE IF EXISTS stg_users;
CREATE TABLE stg_users (
    user_id            TEXT,
    user_name          TEXT,
    role               TEXT,
    posting_limit_pkr  TEXT,
    status             TEXT
);

DROP TABLE IF EXISTS stg_chart_of_accounts;
CREATE TABLE stg_chart_of_accounts (
    account_code  TEXT,
    account_name  TEXT,
    account_type  TEXT
);

-- Change the paths to wherever you saved the CSVs
\copy stg_journal_entries   FROM 'data/raw/journal_entries.csv'   WITH (FORMAT csv, HEADER true)
\copy stg_users             FROM 'data/raw/users.csv'             WITH (FORMAT csv, HEADER true)
\copy stg_chart_of_accounts FROM 'data/raw/chart_of_accounts.csv' WITH (FORMAT csv, HEADER true)


-- -------------------------------------------------------------
-- Profiling: understand the data before testing anything
-- -------------------------------------------------------------

-- 1. Completeness: how many lines and how many journal entries?
SELECT COUNT(*) AS total_lines,
       COUNT(DISTINCT je_id) AS total_entries
FROM stg_journal_entries;

-- 2. Date format: anything that isn't YYYY-MM-DD?
SELECT posting_date, COUNT(*)
FROM stg_journal_entries
WHERE posting_date !~ '^\d{4}-\d{2}-\d{2}$'
GROUP BY posting_date;

-- 3. User IDs: inconsistent casing will break joins to the users table
SELECT posted_by, COUNT(*)
FROM stg_journal_entries
GROUP BY posted_by
ORDER BY posted_by;

-- 4. Descriptions with extra spaces (usually comes with odd casing too)
SELECT description, COUNT(*)
FROM stg_journal_entries
WHERE description <> TRIM(description)
GROUP BY description;

-- 5. Each line should have exactly one of debit / credit filled in
--    (\copy turns empty CSV fields into NULL, hence IS NULL instead of = '')
SELECT
    SUM(CASE WHEN debit IS NULL AND credit IS NULL THEN 1 ELSE 0 END)         AS both_empty,
    SUM(CASE WHEN debit IS NOT NULL AND credit IS NOT NULL THEN 1 ELSE 0 END) AS both_filled
FROM stg_journal_entries;

-- 6. Approval pattern by source (system entries aren't expected to have approvers)
SELECT source,
       COUNT(*) AS lines,
       SUM(CASE WHEN COALESCE(approved_by, '') = '' THEN 1 ELSE 0 END) AS no_approver
FROM stg_journal_entries
GROUP BY source;

-- 7. Period covered
SELECT MIN(posting_date), MAX(posting_date)
FROM stg_journal_entries
WHERE posting_date ~ '^\d{4}-\d{2}-\d{2}$';
