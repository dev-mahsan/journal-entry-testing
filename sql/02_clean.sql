-- =============================================================
-- 02_clean.sql
-- Step 2: build clean, properly typed tables from the staging data
-- Staging tables are left untouched so we can always compare back
-- =============================================================

-- -------------------------------------------------------------
-- Users: standardise IDs, make the limit a number
-- -------------------------------------------------------------
DROP TABLE IF EXISTS users CASCADE;
CREATE TABLE users AS
SELECT
    UPPER(TRIM(user_id))              AS user_id,
    TRIM(user_name)                   AS user_name,
    TRIM(role)                        AS role,
    posting_limit_pkr::NUMERIC(15,2)  AS posting_limit_pkr,
    TRIM(status)                      AS status
FROM stg_users;

ALTER TABLE users ADD PRIMARY KEY (user_id);

-- -------------------------------------------------------------
-- Chart of accounts
-- -------------------------------------------------------------
DROP TABLE IF EXISTS chart_of_accounts CASCADE;
CREATE TABLE chart_of_accounts AS
SELECT
    account_code::INT   AS account_code,
    TRIM(account_name)  AS account_name,
    TRIM(account_type)  AS account_type
FROM stg_chart_of_accounts;

ALTER TABLE chart_of_accounts ADD PRIMARY KEY (account_code);

-- -------------------------------------------------------------
-- Journal entries: this is where the three fixes happen
-- -------------------------------------------------------------
-- CASCADE also drops the views built on this table in Steps 3-4.
-- Without it the DROP fails, the old table survives, and a re-run
-- silently keeps stale data. Steps 3 and 4 recreate the views.
DROP TABLE IF EXISTS journal_entries CASCADE;
CREATE TABLE journal_entries AS
SELECT
    je_id,
    line_no::INT AS line_no,

    -- Fix 1: two date formats in the export. Convert each one properly.
    CASE
        WHEN posting_date ~ '^\d{2}/\d{2}/\d{4}$' THEN TO_DATE(posting_date, 'DD/MM/YYYY')
        ELSE TO_DATE(posting_date, 'YYYY-MM-DD')
    END AS posting_date,

    entry_timestamp::TIMESTAMP AS entry_timestamp,
    account_code::INT          AS account_code,
    account_name,

    -- Fix 2: strip stray spaces. Original wording is kept as-is,
    -- and description_key gives us a lowercase version for matching/grouping
    TRIM(description)          AS description,
    LOWER(TRIM(description))   AS description_key,

    -- Blank debit/credit become 0 so we can do arithmetic
    COALESCE(debit::NUMERIC(15,2), 0)   AS debit,
    COALESCE(credit::NUMERIC(15,2), 0)  AS credit,

    -- Fix 3: user IDs in uppercase so they match the users table
    UPPER(TRIM(posted_by))                   AS posted_by,
    NULLIF(UPPER(TRIM(approved_by)), '')     AS approved_by,

    TRIM(source) AS source
FROM stg_journal_entries;

ALTER TABLE journal_entries ADD PRIMARY KEY (je_id, line_no);


-- -------------------------------------------------------------
-- Validation: prove the cleaning worked and nothing was lost
-- -------------------------------------------------------------

-- V1. Row counts must match staging exactly (expect 4852 = 4852)
SELECT
    (SELECT COUNT(*) FROM stg_journal_entries) AS staging_rows,
    (SELECT COUNT(*) FROM journal_entries)     AS clean_rows;

-- V2. No dates failed to convert (expect 0)
SELECT COUNT(*) AS null_dates
FROM journal_entries
WHERE posting_date IS NULL;

-- V3. User IDs are now consistent (expect 6 rows, all uppercase)
SELECT posted_by, COUNT(*)
FROM journal_entries
GROUP BY posted_by
ORDER BY posted_by;

-- V4. Every poster exists in the users table (expect 0)
SELECT COUNT(*) AS unknown_users
FROM journal_entries j
LEFT JOIN users u ON u.user_id = j.posted_by
WHERE u.user_id IS NULL;

-- V5. Every account exists in the chart of accounts (expect 0)
SELECT COUNT(*) AS unknown_accounts
FROM journal_entries j
LEFT JOIN chart_of_accounts c ON c.account_code = j.account_code
WHERE c.account_code IS NULL;

-- V6. No leftover padded descriptions (expect 0)
SELECT COUNT(*) AS padded_descriptions
FROM journal_entries
WHERE description <> TRIM(description);

-- V7. Control totals: total debits vs total credits for the whole ledger
--     In a healthy ledger these are equal. Note the result for Step 3.
SELECT
    SUM(debit)                AS total_debits,
    SUM(credit)               AS total_credits,
    SUM(debit) - SUM(credit)  AS difference
FROM journal_entries;
