-- =============================================================
-- 03_tests_integrity_timing.sql
-- Step 3: journal entry tests, part 1 (integrity + timing)
-- Every exception goes into one table: je_exceptions
-- =============================================================

-- One row per journal entry: makes entry-level tests much simpler
CREATE OR REPLACE VIEW je_summary AS
SELECT
    je_id,
    MIN(posting_date)     AS posting_date,
    MIN(entry_timestamp)  AS entry_timestamp,
    MIN(posted_by)        AS posted_by,
    MIN(approved_by)      AS approved_by,
    MIN(source)           AS source,
    MIN(description)      AS description,
    COUNT(*)              AS line_count,
    SUM(debit)            AS total_debit,
    SUM(credit)           AS total_credit
FROM journal_entries
GROUP BY je_id;

-- The exceptions register: every test writes its findings here
DROP TABLE IF EXISTS je_exceptions CASCADE;
CREATE TABLE je_exceptions (
    test_id    TEXT,
    test_name  TEXT,
    je_id      TEXT,
    detail     TEXT
);

-- Public holidays in FY 2025-26 (reference table for T04)
DROP TABLE IF EXISTS public_holidays;
CREATE TABLE public_holidays (holiday_date DATE PRIMARY KEY, holiday_name TEXT);
INSERT INTO public_holidays VALUES
    ('2025-08-14', 'Independence Day'),
    ('2025-12-25', 'Quaid-e-Azam Day'),
    ('2026-02-05', 'Kashmir Solidarity Day'),
    ('2026-03-21', 'Eid ul-Fitr'),
    ('2026-03-23', 'Pakistan Day'),
    ('2026-05-01', 'Labour Day'),
    ('2026-05-28', 'Youm-e-Takbeer');


-- -------------------------------------------------------------
-- T01: Unbalanced entries (debits must equal credits)
-- -------------------------------------------------------------
INSERT INTO je_exceptions
SELECT 'T01', 'Unbalanced entry', je_id,
       'Debits ' || total_debit || ' vs credits ' || total_credit
       || ' (difference ' || (total_debit - total_credit) || ')'
FROM je_summary
WHERE total_debit <> total_credit;

-- -------------------------------------------------------------
-- T02: Duplicate entries (same date, accounts and amounts, different ID)
-- -------------------------------------------------------------
INSERT INTO je_exceptions
WITH signatures AS (
    SELECT je_id,
           posting_date,
           STRING_AGG(account_code || ':' || debit || ':' || credit, '|' ORDER BY line_no) AS signature
    FROM journal_entries
    GROUP BY je_id, posting_date
),
matched AS (
    SELECT je_id,
           COUNT(*) OVER (PARTITION BY posting_date, signature) AS copies
    FROM signatures
)
SELECT 'T02', 'Possible duplicate', je_id,
       'Identical to ' || (copies - 1) || ' other entry on the same date'
FROM matched
WHERE copies > 1;

-- -------------------------------------------------------------
-- T03: Posted on a weekend (ISODOW: 6 = Saturday, 7 = Sunday)
-- -------------------------------------------------------------
INSERT INTO je_exceptions
SELECT 'T03', 'Weekend posting', je_id,
       'Posted on ' || TRIM(TO_CHAR(posting_date, 'Day')) || ' ' || posting_date
FROM je_summary
WHERE EXTRACT(ISODOW FROM posting_date) IN (6, 7);

-- -------------------------------------------------------------
-- T04: Posted on a public holiday
-- -------------------------------------------------------------
INSERT INTO je_exceptions
SELECT 'T04', 'Holiday posting', s.je_id,
       'Posted on ' || h.holiday_name || ' (' || s.posting_date || ')'
FROM je_summary s
JOIN public_holidays h ON h.holiday_date = s.posting_date;

-- -------------------------------------------------------------
-- T05: Entered outside business hours (before 7am or from 9pm)
-- -------------------------------------------------------------
INSERT INTO je_exceptions
SELECT 'T05', 'After-hours entry', je_id,
       'Entered at ' || TO_CHAR(entry_timestamp, 'HH24:MI')
FROM je_summary
WHERE EXTRACT(HOUR FROM entry_timestamp) < 7
   OR EXTRACT(HOUR FROM entry_timestamp) >= 21;

-- -------------------------------------------------------------
-- T06: Backdated (entered more than 30 days after its posting date)
-- -------------------------------------------------------------
INSERT INTO je_exceptions
SELECT 'T06', 'Backdated entry', je_id,
       'Entered ' || (entry_timestamp::DATE - posting_date)
       || ' days after posting date ' || posting_date
FROM je_summary
WHERE entry_timestamp::DATE - posting_date > 30;

-- -------------------------------------------------------------
-- T07: Large manual entries in the last week of the financial year
--      Threshold: PKR 500,000 (the accountants' posting limit)
-- -------------------------------------------------------------
INSERT INTO je_exceptions
SELECT 'T07', 'Large year-end manual entry', je_id,
       'PKR ' || total_debit || ' on ' || posting_date || ': ' || description
FROM je_summary
WHERE source = 'Manual'
  AND posting_date BETWEEN '2026-06-24' AND '2026-06-30'
  AND total_debit >= 500000;


-- -------------------------------------------------------------
-- Results
-- -------------------------------------------------------------

-- Summary: how many entries each test flagged
SELECT test_id, test_name, COUNT(DISTINCT je_id) AS entries_flagged
FROM je_exceptions
GROUP BY test_id, test_name
ORDER BY test_id;

-- T01 detail: do the unbalanced entries explain the 15,038.55 from Step 2?
SELECT SUM(total_debit - total_credit) AS total_imbalance
FROM je_summary
WHERE total_debit <> total_credit;

-- Entries caught by more than one test are the highest risk
SELECT je_id,
       COUNT(DISTINCT test_id)                         AS tests_failed,
       STRING_AGG(test_id, ', ' ORDER BY test_id)      AS which_tests
FROM je_exceptions
GROUP BY je_id
HAVING COUNT(DISTINCT test_id) > 1
ORDER BY tests_failed DESC, je_id;
