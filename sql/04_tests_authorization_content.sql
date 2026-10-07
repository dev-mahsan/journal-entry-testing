-- =============================================================
-- 04_tests_authorization_content.sql
-- Step 4: journal entry tests, part 2 (authorization + content)
-- Adds to the je_exceptions table created in Step 3
-- =============================================================

-- Makes this file safe to re-run: clear only this step's results
DELETE FROM je_exceptions WHERE test_id >= 'T08';

-- Entry-level view with the poster's details attached
CREATE OR REPLACE VIEW je_with_user AS
SELECT s.*, u.user_name, u.role, u.posting_limit_pkr, u.status
FROM je_summary s
JOIN users u ON u.user_id = s.posted_by;


-- -------------------------------------------------------------
-- T08: Self-approved (segregation of duties failure)
-- -------------------------------------------------------------
INSERT INTO je_exceptions
SELECT 'T08', 'Self-approved entry', je_id,
       user_name || ' (' || posted_by || ') posted and approved own entry'
FROM je_with_user
WHERE approved_by = posted_by;

-- -------------------------------------------------------------
-- T09: Manual entry with no approver
-- -------------------------------------------------------------
INSERT INTO je_exceptions
SELECT 'T09', 'Manual entry not approved', je_id,
       'Posted by ' || user_name || ', PKR ' || total_debit || ', no approver recorded'
FROM je_with_user
WHERE source = 'Manual'
  AND approved_by IS NULL;

-- -------------------------------------------------------------
-- T10: Above the poster's limit
-- -------------------------------------------------------------
INSERT INTO je_exceptions
SELECT 'T10', 'Above posting limit', je_id,
       'PKR ' || total_debit || ' vs limit ' || posting_limit_pkr || ' (' || role || ')'
FROM je_with_user
WHERE total_debit > posting_limit_pkr;

-- -------------------------------------------------------------
-- T11: Just below the limit (95% to 100%), a sign of splitting
--      or sizing entries to avoid extra approval
-- -------------------------------------------------------------
INSERT INTO je_exceptions
SELECT 'T11', 'Just below posting limit', je_id,
       'PKR ' || total_debit || ' is '
       || ROUND(total_debit / posting_limit_pkr * 100, 1) || '% of limit ' || posting_limit_pkr
FROM je_with_user
WHERE total_debit >= posting_limit_pkr * 0.95
  AND total_debit <  posting_limit_pkr;

-- -------------------------------------------------------------
-- T12: Posted by a terminated user
--      (in a real audit, compare to the HR termination date)
-- -------------------------------------------------------------
INSERT INTO je_exceptions
SELECT 'T12', 'Posted by terminated user', je_id,
       user_name || ' (' || posted_by || ') is marked Terminated; posted on ' || posting_date
FROM je_with_user
WHERE status = 'Terminated';

-- -------------------------------------------------------------
-- T13: Round amounts (multiples of 10,000, at least 50,000)
--      Real transactions rarely land on round numbers; estimates
--      and made-up figures often do
-- -------------------------------------------------------------
INSERT INTO je_exceptions
SELECT 'T13', 'Round amount', je_id,
       'PKR ' || total_debit
FROM je_summary
WHERE total_debit >= 50000
  AND MOD(total_debit, 10000) = 0;

-- -------------------------------------------------------------
-- T14: Vague or suspicious descriptions
--      \m and \M mean "start/end of a whole word", so "adj" won't
--      match words like "adjacent"
-- -------------------------------------------------------------
INSERT INTO je_exceptions
SELECT DISTINCT 'T14', 'Suspicious description', je_id,
       'Description: "' || description || '"'
FROM journal_entries
WHERE description_key ~ '\m(adj|adjustment|misc|reverse|plug|override|urgent|tbd|correction)\M';

-- -------------------------------------------------------------
-- T15: Revenue account debited
--      Revenue normally only gets credited; a debit reduces revenue
--      and should go through returns/discounts, not a direct entry
-- -------------------------------------------------------------
INSERT INTO je_exceptions
SELECT DISTINCT 'T15', 'Revenue account debited', j.je_id,
       'Debit of PKR ' || j.debit || ' to ' || j.account_name || ': ' || j.description
FROM journal_entries j
JOIN chart_of_accounts c ON c.account_code = j.account_code
WHERE c.account_type = 'Revenue'
  AND j.debit > 0;


-- -------------------------------------------------------------
-- Final results across all 15 tests
-- -------------------------------------------------------------

-- 1. Entries flagged per test
SELECT test_id, test_name, COUNT(DISTINCT je_id) AS entries_flagged
FROM je_exceptions
GROUP BY test_id, test_name
ORDER BY test_id;

-- 2. Overall coverage: how much of the ledger was flagged
SELECT
    (SELECT COUNT(*) FROM je_summary)                    AS total_entries_tested,
    (SELECT COUNT(DISTINCT je_id) FROM je_exceptions)    AS entries_flagged,
    ROUND((SELECT COUNT(DISTINCT je_id) FROM je_exceptions) * 100.0
          / (SELECT COUNT(*) FROM je_summary), 1)        AS pct_flagged;

-- 3. Risk ranking: entries failing several tests come first
CREATE OR REPLACE VIEW je_risk_ranking AS
SELECT e.je_id,
       s.posting_date,
       s.posted_by,
       s.total_debit                                  AS amount_pkr,
       s.description,
       COUNT(DISTINCT e.test_id)                      AS tests_failed,
       STRING_AGG(e.test_id, ', ' ORDER BY e.test_id) AS which_tests
FROM je_exceptions e
JOIN je_summary s ON s.je_id = e.je_id
GROUP BY e.je_id, s.posting_date, s.posted_by, s.total_debit, s.description;

SELECT *
FROM je_risk_ranking
WHERE tests_failed > 1
ORDER BY tests_failed DESC, amount_pkr DESC;

-- 4. Export the deliverables for the audit team (needs an "output" folder)
\copy (SELECT * FROM je_risk_ranking ORDER BY tests_failed DESC, amount_pkr DESC) TO 'output/je_risk_ranking.csv' WITH (FORMAT csv, HEADER true)
\copy (SELECT * FROM je_exceptions ORDER BY test_id, je_id) TO 'output/je_exceptions_detail.csv' WITH (FORMAT csv, HEADER true)
