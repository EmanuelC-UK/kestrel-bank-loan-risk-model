-- =====================================================================
-- Kestrel Bank — Business Loan Risk Model
-- Master query (BigQuery Standard SQL)
--
-- Runs the full pipeline in order:
--   1. Sample   2. Clean   3. Risk features   4. Check
--   5. Backtest by threshold   6. Score distribution
--
-- Project: skilful-answer-498915-k5 (dataset: Project_1).
--
-- WARNING: sections 1-3 rebuild tables (section 1 draws a new random
-- sample). Do not re-run them on a live project unless you intend to
-- replace the data. Sections 4-6 only read, so they are safe to run.
--
-- Input tables (loaded outside SQL, from Companies House):
--   raw_basic_company_data   Free Company Data bulk file (all UK companies)
--   officers_output          officer appointments/resignations, pulled per company via the API
--   filing_history_output    insolvency filings, pulled per company via the API
--   charges_output           registered charges, pulled per company via the API
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. SAMPLE: 5,000 failed + 5,000 active companies
--    Note: RAND() draws a new sample on every run, so a re-run will give
--    slightly different figures from the ones reported. The saved
--    sample_companies table is the reference.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE `skilful-answer-498915-k5.Project_1.sample_companies` AS
WITH distressed AS (
  SELECT *, 'failed' AS outcome_label
  FROM `skilful-answer-498915-k5.Project_1.raw_basic_company_data`
  WHERE TRIM(CompanyStatus) IN ('Liquidation', 'Voluntary Arrangement', 'RECEIVERSHIP',
                                'ADMINISTRATIVE RECEIVER', 'ADMINISTRATION ORDER')
     OR TRIM(CompanyStatus) LIKE 'In Administration%'
  -- Failed sample as built: Liquidation 4,771 | In Administration (incl. variants) 174 |
  -- Voluntary Arrangement 24 | Receivership 18 | Administrative Receiver 7 | Administration Order 6
  ORDER BY RAND()
  LIMIT 5000
),
active AS (
  SELECT *, 'active' AS outcome_label
  FROM `skilful-answer-498915-k5.Project_1.raw_basic_company_data`
  WHERE TRIM(CompanyStatus) = 'Active'
  ORDER BY RAND()
  LIMIT 5000
)
SELECT * FROM distressed
UNION ALL
SELECT * FROM active;


-- ---------------------------------------------------------------------
-- 2. CLEAN: remove non-standard entity types (partnerships, overseas
--    entities and similar). Sample goes from 10,000 to 9,844.
-- ---------------------------------------------------------------------
DELETE FROM `skilful-answer-498915-k5.Project_1.sample_companies`
WHERE SUBSTR(CompanyNumber, 1, 2) IN ('LP', 'SL', 'OE', 'CE', 'CS', 'IP', 'RS', 'NF', 'SG');


-- ---------------------------------------------------------------------
-- 3. RISK FEATURES: one row per company
--    reference_dates : earliest insolvency filing, else snapshot date
--    resignations    : director resignations in the 12 months before it
--    charges         : total and outstanding charges as of it
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE `skilful-answer-498915-k5.Project_1.company_risk_features` AS
WITH reference_dates AS (
  SELECT
    s.CompanyNumber AS company_number,
    s.CompanyName AS company_name,
    s.outcome_label,
    s.Accounts_NextDueDate,
    s.ConfStmtNextDueDate,
    COALESCE(fh.first_filing_date, DATE('2026-09-01')) AS reference_date
  FROM `skilful-answer-498915-k5.Project_1.sample_companies` s
  LEFT JOIN (
    SELECT company_number, MIN(filing_date) AS first_filing_date
    FROM `skilful-answer-498915-k5.Project_1.filing_history_output`
    GROUP BY company_number
  ) fh ON fh.company_number = s.CompanyNumber
),
resignations AS (
  SELECT r.company_number, COUNT(o.resigned_on) AS director_resigned_in_window
  FROM reference_dates r
  LEFT JOIN `skilful-answer-498915-k5.Project_1.officers_output` o
    ON o.company_number = r.company_number
    AND o.resigned_on BETWEEN DATE_SUB(r.reference_date, INTERVAL 12 MONTH) AND r.reference_date
  GROUP BY r.company_number
),
charges AS (
  SELECT
    r.company_number,
    COUNTIF(c.created_on <= r.reference_date) AS total_charges_as_of_ref,
    COUNTIF(c.created_on <= r.reference_date
            AND (c.satisfied_on IS NULL OR c.satisfied_on > r.reference_date)) AS outstanding_charges_as_of_ref
  FROM reference_dates r
  LEFT JOIN `skilful-answer-498915-k5.Project_1.charges_output` c
    ON c.company_number = r.company_number
  GROUP BY r.company_number
)
SELECT
  r.company_number,
  r.company_name,
  r.outcome_label,
  r.reference_date,
  IFNULL(res.director_resigned_in_window, 0) AS director_resigned_in_window,
  (IFNULL(r.Accounts_NextDueDate < r.reference_date, FALSE)
   OR IFNULL(r.ConfStmtNextDueDate < r.reference_date, FALSE)) AS filing_overdue_at_ref,
  IFNULL(ch.total_charges_as_of_ref, 0) AS total_charges_as_of_ref,
  IFNULL(ch.outstanding_charges_as_of_ref, 0) AS outstanding_charges_as_of_ref
FROM reference_dates r
LEFT JOIN resignations res ON res.company_number = r.company_number
LEFT JOIN charges ch ON ch.company_number = r.company_number;


-- ---------------------------------------------------------------------
-- 4. CHECK: 9,844 rows; failed companies score higher on every signal
--    Reported: active 4,844 / failed 5,000
--    avg resignations 0.13 / 0.29, overdue 5.9% / 47.4%,
--    avg total charges 0.64 / 1.35, avg outstanding charges 0.33 / 0.74
-- ---------------------------------------------------------------------
SELECT
  outcome_label,
  COUNT(*) AS companies,
  ROUND(AVG(director_resigned_in_window), 2) AS avg_resignations,
  ROUND(AVG(IF(filing_overdue_at_ref, 1, 0)), 3) AS share_overdue,
  ROUND(AVG(total_charges_as_of_ref), 2) AS avg_total_charges,
  ROUND(AVG(outstanding_charges_as_of_ref), 2) AS avg_outstanding_charges
FROM `skilful-answer-498915-k5.Project_1.company_risk_features`
GROUP BY outcome_label;


-- ---------------------------------------------------------------------
-- 5. BACKTEST: 0-3 risk score, one point each for
--    a director resignation, an overdue filing, an outstanding charge.
--    Detection rate = share of failed companies flagged.
--    False-positive rate = share of active companies wrongly flagged.
--    Reported: >=1: 69.6% / 24.2%   >=2: 20.1% / 2.3%   >=3: 2.1% / 0.1%
-- ---------------------------------------------------------------------
WITH scored AS (
  SELECT
    company_number,
    outcome_label,
    IF(director_resigned_in_window >= 1, 1, 0)
      + IF(filing_overdue_at_ref, 1, 0)
      + IF(outstanding_charges_as_of_ref >= 1, 1, 0) AS risk_score
  FROM `skilful-answer-498915-k5.Project_1.company_risk_features`
)
SELECT
  threshold,
  ROUND(COUNTIF(outcome_label = 'failed' AND risk_score >= threshold)
        / COUNTIF(outcome_label = 'failed'), 3) AS detection_rate,
  ROUND(COUNTIF(outcome_label = 'active' AND risk_score >= threshold)
        / COUNTIF(outcome_label = 'active'), 3) AS false_positive_rate
FROM scored, UNNEST([0, 1, 2, 3]) AS threshold
GROUP BY threshold
ORDER BY threshold;


-- ---------------------------------------------------------------------
-- 6. SCORE DISTRIBUTION: share of each group at each score
--    Reported (active / failed):
--    0: 75.8% / 30.4%   1: 21.9% / 49.5%   2: 2.2% / 18.0%   3: 0.1% / 2.1%
-- ---------------------------------------------------------------------
WITH scored AS (
  SELECT
    company_number,
    outcome_label,
    IF(director_resigned_in_window >= 1, 1, 0)
      + IF(filing_overdue_at_ref, 1, 0)
      + IF(outstanding_charges_as_of_ref >= 1, 1, 0) AS risk_score
  FROM `skilful-answer-498915-k5.Project_1.company_risk_features`
)
SELECT
  risk_score,
  ROUND(COUNTIF(outcome_label = 'active')
        / (SELECT COUNTIF(outcome_label = 'active') FROM scored), 3) AS share_of_active,
  ROUND(COUNTIF(outcome_label = 'failed')
        / (SELECT COUNTIF(outcome_label = 'failed') FROM scored), 3) AS share_of_failed
FROM scored
GROUP BY risk_score
ORDER BY risk_score;
