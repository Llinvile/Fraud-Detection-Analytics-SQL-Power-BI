/*
Project: Fraud Detection Analytics
Author: Llinvile De Jongh

Description:
This SQL script performs exploratory and investigative analysis on a synthetic
financial transactions dataset to identify potential fraud patterns.

The analysis includes:
1. Data quality validation
2. Fraud pattern analysis
3. High-risk account identification
4. Time-based fraud pattern analysis
5. Fraud recoverability assessment
6. Creation of reporting views to support Power BI dashboards

Dataset: Synthetic Financial Dataset for Fraud Detection (SFD4FD)

   =====================================================
   DATA SOURCE
   =====================================================
   Main dataset table used throughout this analysis:
   SFD4FD..[SFD for Fraud Detection]

   If running this script locally, replace the table
   reference with your own dataset table name.
   =====================================================
*/




/* =====================================================
   1. DATA QUALITY & SANITY CHECKS
   ===================================================== */

-- Are there data integrity issues that could skew our analysis?

SELECT 
    type,
    COUNT(*) AS total_transactions,
    SUM(
        CASE 
            WHEN TRY_CAST(oldbalanceOrg AS DECIMAL(18,2)) 
               - TRY_CAST(amount AS DECIMAL(18,2)) 
               <> TRY_CAST(newbalanceOrig AS DECIMAL(18,2))
            THEN 1 ELSE 0 
        END
    ) AS sender_balance_mismatch,

    SUM(
        CASE 
            WHEN TRY_CAST(oldbalanceDest AS DECIMAL(18,2)) 
               + TRY_CAST(amount AS DECIMAL(18,2)) 
               <> TRY_CAST(newbalanceDest AS DECIMAL(18,2))
            THEN 1 ELSE 0 
        END
    ) AS receiver_balance_mismatch,

    AVG(TRY_CAST(amount AS DECIMAL(18,2))) AS avg_amount,
    MAX(TRY_CAST(amount AS DECIMAL(18,2))) AS max_amount

FROM SFD4FD..[SFD for Fraud Detection]
GROUP BY type
ORDER BY type;



/* =====================================================
   2. FRAUD PATTERN ANALYSIS
   ===================================================== */

-- What are the distinctive characteristics of fraudulent vs. legitimate transactions?

With FraudAnalysis as (
	Select 
		type,
		isFraud,
		isFlaggedFraud,
		COUNT(*) as transation_count,
		SUM(TRY_CAST(amount AS FLOAT)) AS total_amount,
        AVG(TRY_CAST(amount AS FLOAT)) AS avg_amount,
		AVG(CASE WHEN TRY_CAST(oldbalanceOrg AS FLOAT) = 0 THEN 1.0 ELSE 0.0 END) as zero_balance_sender_rate,
		AVG(CASE WHEN TRY_CAST(newbalanceOrig AS FLOAT) = 0 THEN 1.0 ELSE 0.0 END) as zero_balance_after_rate,
		AVG(CASE WHEN TRY_CAST(oldbalanceDest AS FLOAT) = 0 THEN 1.0 ELSE 0.0 END) as zero_balance_received_rate

	From SFD4FD..[SFD for Fraud Detection]
	GROUP by type, isFraud, isFlaggedFraud
)

Select * From FraudAnalysis
order by type, isFraud Desc;




/* =====================================================
   3. HIGH-RISK ACCOUNT IDENTIFICATION
   ===================================================== */

-- Which accounts show patterns consistent with fraud or financial distress?

Select
	nameOrig as account_id,
	COUNT(*) as transaction_count,
	SUM(CASE WHEN isFraud = 1 THEN 1 ELSE 0 END) as fraud_count,
	SUM(CASE WHEN isFraud = 1 THEN TRY_CAST(amount AS DECIMAL(18,2)) ELSE 0 END) as fraud_amount,
	AVG(TRY_CAST(amount AS DECIMAL(18,2))) as avg_transaction_size,
	MAX(TRY_CAST(step AS FLOAT)) - MIN(TRY_CAST(step AS FLOAT)) AS activity_timeframe_hours,
	
	COUNT(*) * 1.0 / NULLIF(MAX(TRY_CAST(step AS FLOAT)) - MIN(TRY_CAST(step AS FLOAT)), 0) as transactions_per_hour

From SFD4FD..[SFD for Fraud Detection]
Group by nameOrig
Having COUNT(*) > 5 -- Focus on active accounts
Order by fraud_amount DESC, transactions_per_hour DESC;




/* =====================================================
   4. TIME-BASED FRAUD PATTERNS
   ===================================================== */

-- Are there specific times when fraud is more prevalent?

Select
	step, -- Assuming step represents time intervals
	DATEPART(HOUR, DATEADD(HOUR, 
		CASE 
			WHEN ISNUMERIC(step) = 1 THEN CAST(step AS INT)
			ELSE 0 
		END, '2023-01-01')) as hour_of_day,
	
	COUNT(*) as total_transactions,
	SUM(CASE WHEN isFraud = 1 THEN 1 ELSE 0 END) as fraud_count,
	SUM(CASE WHEN isFraud = 1 THEN TRY_CAST(amount AS DECIMAL(18,2)) ELSE 0 END) as fraud_amount,
	AVG(TRY_CAST(amount AS DECIMAL(18,2))) as avg_transaction_size

From SFD4FD..[SFD for Fraud Detection]
Group by step
Order by fraud_count DESC;




/* =====================================================
   5. RECOVERABILITY ASSESSMENT
   ===================================================== */

-- Which fraudulent transactions might be recoverable based on balance patterns?

WITH CleanFraud AS (
    SELECT
        f.type,
        f.isFraud,
        f.isFlaggedFraud,
        f.nameOrig,
        f.nameDest,

        TRY_CAST(f.amount AS DECIMAL(18,2)) AS amount_clean,
        TRY_CAST(f.newbalanceOrig AS DECIMAL(18,2)) AS newbalanceOrig_clean,
        TRY_CAST(d.newbalanceDest AS DECIMAL(18,2)) AS newbalanceDest_clean

    FROM SFD4FD..[SFD for Fraud Detection] f
    LEFT JOIN SFD4FD..[SFD for Fraud Detection] d
        ON f.nameDest = d.nameOrig

    WHERE
        f.isFraud = 1
        AND TRY_CAST(f.amount AS DECIMAL(18,2)) IS NOT NULL
)

SELECT
    type,
    isFraud,
    isFlaggedFraud,

    COUNT(*) AS cases,

    SUM(amount_clean) AS total_amount_at_risk,

    -- Recovery potential indicators
    AVG(
        CASE 
            WHEN newbalanceDest_clean > amount_clean THEN 1.0 
            ELSE 0.0 
        END
    ) AS receiver_has_funds_rate,

    AVG(newbalanceOrig_clean) AS avg_sender_balance_after,

    -- Collection priority scoring
    CASE 
        WHEN type IN ('CASH_OUT', 'TRANSFER')
             AND newbalanceOrig_clean < amount_clean
        THEN 'HIGH_PRIORITY'

        WHEN type = 'CASH_IN'
        THEN 'LOW_PRIORITY'

        ELSE 'MEDIUM_PRIORITY'
    END AS collection_priority

FROM CleanFraud
GROUP BY
    type,
    isFraud,
    isFlaggedFraud,
    CASE 
        WHEN type IN ('CASH_OUT', 'TRANSFER')
             AND newbalanceOrig_clean < amount_clean
        THEN 'HIGH_PRIORITY'
        WHEN type = 'CASH_IN'
        THEN 'LOW_PRIORITY'
        ELSE 'MEDIUM_PRIORITY'
    END

ORDER BY
    collection_priority,
    total_amount_at_risk DESC;



/* =====================================================
-- 6. Operational Performance & Reporting
   ===================================================== */

-- Create a data source that joins key metrics

	-- 6.1 Create a Fraud Pattern view

		-- 6.1.1 Create the base cleaned transactions view first

ALTER VIEW dbo.BASE_CLEAN_TRANSACTIONS AS
SELECT
    type,
    isFraud,
    isFlaggedFraud,
    nameOrig,
    nameDest,

    TRY_CAST(amount AS DECIMAL(18,2)) AS amount,
    TRY_CAST(oldbalanceOrg AS DECIMAL(18,2)) AS oldbalanceOrg,
    TRY_CAST(newbalanceOrig AS DECIMAL(18,2)) AS newbalanceOrig,
    TRY_CAST(oldbalanceDest AS DECIMAL(18,2)) AS oldbalanceDest,
    TRY_CAST(newbalanceDest AS DECIMAL(18,2)) AS newbalanceDest,

    TRY_CAST(step AS FLOAT) AS step

FROM SFD4FD..[SFD for Fraud Detection]
WHERE
    TRY_CAST(amount AS DECIMAL(18,2)) IS NOT NULL
    AND TRY_CAST(step AS FLOAT) IS NOT NULL;

	--- Sanity check of BASE_CLEAN_TRANSACTIONS
SELECT *
FROM dbo.BASE_CLEAN_TRANSACTIONS;



	-- 6.2 Create the Fraud Pattern view

-- Drop the existing view if it exists
IF OBJECT_ID('dbo.FRAUD_PATTERN_ANALYSIS', 'V') IS NOT NULL
    DROP VIEW dbo.FRAUD_PATTERN_ANALYSIS;
GO

-- Create the view
CREATE VIEW dbo.FRAUD_PATTERN_ANALYSIS AS
SELECT
    type,
    isFraud,
    isFlaggedFraud,
    COUNT(*) AS transaction_count,
    SUM(amount) AS total_amount,
    AVG(amount) AS avg_amount
FROM dbo.BASE_CLEAN_TRANSACTIONS
GROUP BY type, isFraud, isFlaggedFraud;
GO


	-- Confirm FRAUD_PATTERN_ANALYSIS
SELECT * FROM dbo.FRAUD_PATTERN_ANALYSIS;




	-- 6.3 Create the High-Risk Account view

CREATE VIEW dbo.HIGH_RISK_ACCOUNT_IDENTIFICATION AS
SELECT
    nameOrig AS account_id,
    COUNT(*) AS transaction_count,

    SUM(CASE WHEN isFraud = 1 THEN 1 ELSE 0 END) AS fraud_count,

    SUM(CASE 
        WHEN isFraud = 1 
        THEN amount 
        ELSE 0 
    END) AS fraud_amount,

    AVG(amount) AS avg_transaction_size

FROM dbo.BASE_CLEAN_TRANSACTIONS
GROUP BY nameOrig;

	-- Sanity check of HIGH_RISK_ACCOUNT_IDENTIFICATION
SELECT *
FROM dbo.HIGH_RISK_ACCOUNT_IDENTIFICATION
ORDER BY fraud_amount DESC;




	-- 6.4 Create the Time-Based Fraud view

CREATE VIEW dbo.TIME_BASED_FRAUD_PATTERNS AS
SELECT
    CASE 
        WHEN TRY_CAST(step AS INT) IS NOT NULL 
        THEN CAST(TRY_CAST(step AS INT) % 24 AS INT)
        ELSE NULL 
    END AS hour_of_day,
    COUNT(*) AS total_transactions,
    SUM(CASE WHEN isFraud = 1 THEN 1 ELSE 0 END) AS fraud_count,
    SUM(CASE 
        WHEN isFraud = 1 
        THEN amount 
        ELSE 0 
    END) AS fraud_amount,
    AVG(amount) AS avg_transaction_size
FROM dbo.BASE_CLEAN_TRANSACTIONS
GROUP BY 
    CASE 
        WHEN TRY_CAST(step AS INT) IS NOT NULL 
        THEN CAST(TRY_CAST(step AS INT) % 24 AS INT)
        ELSE NULL 
    END;

	-- Sanity check of TIME_BASED_FRAUD_PATTERNS
SELECT *
FROM dbo.TIME_BASED_FRAUD_PATTERNS
ORDER BY hour_of_day;



-- UNION query
SELECT 
    'Fraud Pattern' AS metric_category,
    type,
    isFraud,
    transaction_count,
    total_amount,
    avg_amount
FROM dbo.FRAUD_PATTERN_ANALYSIS

UNION ALL

SELECT 
    'Account Risk' AS metric_category,
    account_id AS type,
    CASE WHEN fraud_count > 0 THEN 1 ELSE 0 END AS isFraud,
    transaction_count,
    fraud_amount AS total_amount,
    avg_transaction_size AS avg_amount
FROM dbo.HIGH_RISK_ACCOUNT_IDENTIFICATION

UNION ALL

SELECT 
    'Temporal Pattern' AS metric_category,
    CAST(hour_of_day AS VARCHAR) AS type,
    CASE WHEN fraud_count > 0 THEN 1 ELSE 0 END AS isFraud,
    total_transactions AS transaction_count,
    fraud_amount AS total_amount,
    avg_transaction_size AS avg_amount
FROM dbo.TIME_BASED_FRAUD_PATTERNS;
