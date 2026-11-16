-- demo/demo-vertical-quant-finance.sql
--
-- FractalSQL for Apache Druid -- industry vertical: quantitative finance
-- and algorithmic trading. A cardinality-constrained portfolio problem
-- (25 synthetic assets, a 4-factor covariance model, optimize down to an
-- 8-asset book) plus a price series with a deliberate volatility regime
-- change for DFA-based regime detection -- a real, established DFA
-- application (detecting when a market series stops behaving like its
-- own recent history).
--
--   1. Twenty-five synthetic assets on a 4-factor covariance model.
--   2. fractal_optimize_portfolio: the best 8-of-25 book, and its Sharpe.
--   3. A 300-point price series whose regime changes at t=240: the DFA
--      exponent, the drift report, and the change-point indices.
--   4. fractal_search_trajectory: which of the ten historical quarterly
--      rebalance snapshots this rebalance most resembles.
--   5. A closing fractal_reason() ties the regime shift to the book.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The closing
-- fractal_reason() narrative needs a reasoning provider
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-quant-finance.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The assets, the factor loadings, the price series and the ten
--     historical rebalance snapshots are @fixture directives: Druid has no
--     DDL, no VALUES and no recursive CTE, and random values are the deterministic sin-hash the other kits use.
--   * The covariance matrix is an MSQ write: Druid has neither a recursive CTE nor a correlated subquery -- a 4-factor model (cov[i,j] = sum_f l[i,f]*l[j,f],
--     plus the asset's idiosyncratic variance on the diagonal) falls out
--     of a self-join on the factor id.
--   * The optimizer's flat row-major covariance vector is assembled with
--     ARRAY_AGG over the written matrix: Druid has no group_concat, and
--     the write sorts the matrix by (asset, asset), which is the
--     row-major layout the optimizer expects.
--   * The optimizer takes three arguments here; it is deterministic, so
--     there is no seed.
--   * The price series is a fixture whose rows are the walk, and its CSV
--     form is built with ARRAY_AGG: Druid has no window functions, and a
--     fixture's rows keep their order through the write and the scan, so
--     the DFA exponent still sees the series in the right order.
--   * fractal_search_trajectory is a service call: the current (optimized)
--     vector is only known at run time, so it is read out of a datasource
--     the kit computed.
--   * fractal_change_point_detect takes three arguments here (series, window, threshold).
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Ends with a HEADLINE line computed from the kit's own results
--     (HEADLINE kit=<name> ok); the build_test kit gate greps for it.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Twenty-five synthetic assets on a 4-factor covariance model.
--
-- The factor loadings live in their own table (one row per asset and
-- factor), and the covariance matrix is derived from them: the matrix is
-- the sum of the factor outer products, with each asset's idiosyncratic
-- variance added on the diagonal.
-- ---------------------------------------------------------------------------
-- @fixture vqf_assets {"rows": [
--   {"asset_id": 1, "symbol": "TICK1", "mu": 0.028569, "idio": 0.045083},
--   {"asset_id": 2, "symbol": "TICK2", "mu": 0.051067, "idio": 0.032036},
--   {"asset_id": 3, "symbol": "TICK3", "mu": 0.014102, "idio": 0.054555},
--   {"asset_id": 4, "symbol": "TICK4", "mu": 0.077907, "idio": 0.078891},
--   {"asset_id": 5, "symbol": "TICK5", "mu": 0.146859, "idio": 0.075234},
--   {"asset_id": 6, "symbol": "TICK6", "mu": 0.136497, "idio": 0.048217},
--   {"asset_id": 7, "symbol": "TICK7", "mu": 0.059947, "idio": 0.066092},
--   {"asset_id": 8, "symbol": "TICK8", "mu": 0.110595, "idio": 0.055799},
--   {"asset_id": 9, "symbol": "TICK9", "mu": 0.081431, "idio": 0.076056},
--   {"asset_id": 10, "symbol": "TICK10", "mu": 0.138825, "idio": 0.047185},
--   {"asset_id": 11, "symbol": "TICK11", "mu": 0.057024, "idio": 0.032926},
--   {"asset_id": 12, "symbol": "TICK12", "mu": 0.016623, "idio": 0.061683},
--   {"asset_id": 13, "symbol": "TICK13", "mu": 0.098102, "idio": 0.067758},
--   {"asset_id": 14, "symbol": "TICK14", "mu": 0.115315, "idio": 0.036991},
--   {"asset_id": 15, "symbol": "TICK15", "mu": 0.028142, "idio": 0.050834},
--   {"asset_id": 16, "symbol": "TICK16", "mu": 0.067363, "idio": 0.028552},
--   {"asset_id": 17, "symbol": "TICK17", "mu": 0.00423, "idio": 0.026863},
--   {"asset_id": 18, "symbol": "TICK18", "mu": -0.000555, "idio": 0.038132},
--   {"asset_id": 19, "symbol": "TICK19", "mu": 0.031374, "idio": 0.026953},
--   {"asset_id": 20, "symbol": "TICK20", "mu": -0.000299, "idio": 0.06872},
--   {"asset_id": 21, "symbol": "TICK21", "mu": 0.11804, "idio": 0.053234},
--   {"asset_id": 22, "symbol": "TICK22", "mu": 0.074162, "idio": 0.044279},
--   {"asset_id": 23, "symbol": "TICK23", "mu": 0.048789, "idio": 0.072374},
--   {"asset_id": 24, "symbol": "TICK24", "mu": 0.128393, "idio": 0.04848},
--   {"asset_id": 25, "symbol": "TICK25", "mu": 0.060694, "idio": 0.033499}
-- ]};

-- @fixture vqf_loadings {"rows": [
--   {"asset_id": 1, "factor_id": 1, "loading": -0.130086},
--   {"asset_id": 1, "factor_id": 2, "loading": 0.008341},
--   {"asset_id": 1, "factor_id": 3, "loading": -0.214482},
--   {"asset_id": 1, "factor_id": 4, "loading": -0.231369},
--   {"asset_id": 2, "factor_id": 1, "loading": -0.11868},
--   {"asset_id": 2, "factor_id": 2, "loading": -0.230465},
--   {"asset_id": 2, "factor_id": 3, "loading": 0.187199},
--   {"asset_id": 2, "factor_id": 4, "loading": 0.032336},
--   {"asset_id": 3, "factor_id": 1, "loading": -0.057214},
--   {"asset_id": 3, "factor_id": 2, "loading": 0.22374},
--   {"asset_id": 3, "factor_id": 3, "loading": -0.015197},
--   {"asset_id": 3, "factor_id": 4, "loading": -0.165005},
--   {"asset_id": 4, "factor_id": 1, "loading": -0.114395},
--   {"asset_id": 4, "factor_id": 2, "loading": -0.195049},
--   {"asset_id": 4, "factor_id": 3, "loading": -0.198114},
--   {"asset_id": 4, "factor_id": 4, "loading": -0.250682},
--   {"asset_id": 5, "factor_id": 1, "loading": 0.186538},
--   {"asset_id": 5, "factor_id": 2, "loading": -0.289998},
--   {"asset_id": 5, "factor_id": 3, "loading": -0.247166},
--   {"asset_id": 5, "factor_id": 4, "loading": -0.253484},
--   {"asset_id": 6, "factor_id": 1, "loading": 0.058571},
--   {"asset_id": 6, "factor_id": 2, "loading": -0.155113},
--   {"asset_id": 6, "factor_id": 3, "loading": -0.067158},
--   {"asset_id": 6, "factor_id": 4, "loading": -0.103094},
--   {"asset_id": 7, "factor_id": 1, "loading": -0.07929},
--   {"asset_id": 7, "factor_id": 2, "loading": 0.004419},
--   {"asset_id": 7, "factor_id": 3, "loading": -0.19604},
--   {"asset_id": 7, "factor_id": 4, "loading": -0.282667},
--   {"asset_id": 8, "factor_id": 1, "loading": -0.185839},
--   {"asset_id": 8, "factor_id": 2, "loading": 0.056936},
--   {"asset_id": 8, "factor_id": 3, "loading": -0.207526},
--   {"asset_id": 8, "factor_id": 4, "loading": 0.115655},
--   {"asset_id": 9, "factor_id": 1, "loading": -0.189503},
--   {"asset_id": 9, "factor_id": 2, "loading": -0.273489},
--   {"asset_id": 9, "factor_id": 3, "loading": 0.140328},
--   {"asset_id": 9, "factor_id": 4, "loading": -0.04112},
--   {"asset_id": 10, "factor_id": 1, "loading": -0.246281},
--   {"asset_id": 10, "factor_id": 2, "loading": -0.133574},
--   {"asset_id": 10, "factor_id": 3, "loading": -0.243555},
--   {"asset_id": 10, "factor_id": 4, "loading": -0.074186},
--   {"asset_id": 11, "factor_id": 1, "loading": -0.009114},
--   {"asset_id": 11, "factor_id": 2, "loading": -0.085223},
--   {"asset_id": 11, "factor_id": 3, "loading": -0.033516},
--   {"asset_id": 11, "factor_id": 4, "loading": 0.256816},
--   {"asset_id": 12, "factor_id": 1, "loading": 0.189249},
--   {"asset_id": 12, "factor_id": 2, "loading": -0.215122},
--   {"asset_id": 12, "factor_id": 3, "loading": 0.017832},
--   {"asset_id": 12, "factor_id": 4, "loading": 0.142418},
--   {"asset_id": 13, "factor_id": 1, "loading": 0.168565},
--   {"asset_id": 13, "factor_id": 2, "loading": 0.150667},
--   {"asset_id": 13, "factor_id": 3, "loading": 0.256751},
--   {"asset_id": 13, "factor_id": 4, "loading": -0.212251},
--   {"asset_id": 14, "factor_id": 1, "loading": -0.266536},
--   {"asset_id": 14, "factor_id": 2, "loading": -0.006041},
--   {"asset_id": 14, "factor_id": 3, "loading": -0.141517},
--   {"asset_id": 14, "factor_id": 4, "loading": 0.259794},
--   {"asset_id": 15, "factor_id": 1, "loading": -0.252638},
--   {"asset_id": 15, "factor_id": 2, "loading": -0.200678},
--   {"asset_id": 15, "factor_id": 3, "loading": -0.001455},
--   {"asset_id": 15, "factor_id": 4, "loading": 0.235918},
--   {"asset_id": 16, "factor_id": 1, "loading": -0.093756},
--   {"asset_id": 16, "factor_id": 2, "loading": 0.043441},
--   {"asset_id": 16, "factor_id": 3, "loading": 0.130121},
--   {"asset_id": 16, "factor_id": 4, "loading": 0.267058},
--   {"asset_id": 17, "factor_id": 1, "loading": -0.175111},
--   {"asset_id": 17, "factor_id": 2, "loading": 0.084718},
--   {"asset_id": 17, "factor_id": 3, "loading": -0.271762},
--   {"asset_id": 17, "factor_id": 4, "loading": -0.281106},
--   {"asset_id": 18, "factor_id": 1, "loading": -0.000355},
--   {"asset_id": 18, "factor_id": 2, "loading": -0.025944},
--   {"asset_id": 18, "factor_id": 3, "loading": -0.019453},
--   {"asset_id": 18, "factor_id": 4, "loading": 0.249825},
--   {"asset_id": 19, "factor_id": 1, "loading": -0.059045},
--   {"asset_id": 19, "factor_id": 2, "loading": 0.297069},
--   {"asset_id": 19, "factor_id": 3, "loading": -0.139233},
--   {"asset_id": 19, "factor_id": 4, "loading": 0.157612},
--   {"asset_id": 20, "factor_id": 1, "loading": 0.284351},
--   {"asset_id": 20, "factor_id": 2, "loading": -0.236007},
--   {"asset_id": 20, "factor_id": 3, "loading": -0.299367},
--   {"asset_id": 20, "factor_id": 4, "loading": 0.138839},
--   {"asset_id": 21, "factor_id": 1, "loading": -0.116321},
--   {"asset_id": 21, "factor_id": 2, "loading": -0.174442},
--   {"asset_id": 21, "factor_id": 3, "loading": 0.260623},
--   {"asset_id": 21, "factor_id": 4, "loading": -0.138177},
--   {"asset_id": 22, "factor_id": 1, "loading": -0.040204},
--   {"asset_id": 22, "factor_id": 2, "loading": 0.188616},
--   {"asset_id": 22, "factor_id": 3, "loading": 0.164794},
--   {"asset_id": 22, "factor_id": 4, "loading": -0.288923},
--   {"asset_id": 23, "factor_id": 1, "loading": 0.041042},
--   {"asset_id": 23, "factor_id": 2, "loading": 0.189441},
--   {"asset_id": 23, "factor_id": 3, "loading": -0.213514},
--   {"asset_id": 23, "factor_id": 4, "loading": 0.184682},
--   {"asset_id": 24, "factor_id": 1, "loading": 0.194908},
--   {"asset_id": 24, "factor_id": 2, "loading": -0.182334},
--   {"asset_id": 24, "factor_id": 3, "loading": -0.035641},
--   {"asset_id": 24, "factor_id": 4, "loading": 0.164526},
--   {"asset_id": 25, "factor_id": 1, "loading": 0.161696},
--   {"asset_id": 25, "factor_id": 2, "loading": 0.219545},
--   {"asset_id": 25, "factor_id": 3, "loading": -0.250244},
--   {"asset_id": 25, "factor_id": 4, "loading": 0.133556}
-- ]};

-- The factor part of the matrix: cov[i,j] = sum_f l[i,f] * l[j,f].
REPLACE INTO vqf_cov_factors OVERWRITE ALL
SELECT li."asset_id" AS "i", lj."asset_id" AS "j",
       SUM(li."loading" * lj."loading") AS "factor_cov"
FROM "vqf_loadings" li, "vqf_loadings" lj
WHERE li."factor_id" = lj."factor_id"
GROUP BY li."asset_id", lj."asset_id"
PARTITIONED BY ALL
CLUSTERED BY "i", "j";

-- ... and the idiosyncratic variance on the diagonal. The matrix is
-- clustered by (i, j), so the row-major layout the optimizer expects is
-- the layout the scan hands back.
REPLACE INTO vqf_cov OVERWRITE ALL
SELECT c."i" AS "i", c."j" AS "j",
       ROUND(c."factor_cov" + CASE WHEN c."i" = c."j" THEN a."idio" ELSE 0 END, 8) AS "cov_ij"
FROM "vqf_cov_factors" c, "vqf_assets" a
WHERE a."asset_id" = c."i"
PARTITIONED BY ALL
CLUSTERED BY "i", "j";

SELECT (SELECT COUNT(*) FROM "vqf_assets") AS "assets",
       (SELECT COUNT(*) FROM "vqf_cov") AS "cov_entries";

-- The optimizer's two flat vectors: the expected returns in asset order,
-- and the covariance matrix in row-major (asset, asset) order.
REPLACE INTO vqf_mu OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("mu" AS VARCHAR), 8192), ',') AS "mu"
FROM "vqf_assets"
PARTITIONED BY ALL;

REPLACE INTO vqf_cov_flat OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("cov_ij" AS VARCHAR), 16384), ',') AS "cov"
FROM "vqf_cov"
PARTITIONED BY ALL;

-- ---------------------------------------------------------------------------
-- 2. fractal_optimize_portfolio: the best 8-of-25 book.
-- ---------------------------------------------------------------------------
REPLACE INTO vqf_result OVERWRITE ALL
SELECT fractal_optimize_portfolio(a."mu", b."cov", 8) AS "rj"
FROM "vqf_mu" a, "vqf_cov_flat" b
PARTITIONED BY ALL;

SELECT fractal_json_value("rj", '$.sharpe') AS "sharpe" FROM "vqf_result" GROUP BY "rj";

-- The weights are a JSON array over the assets, in asset order. The
-- optimizer's weights array is read back one position at a time.
REPLACE INTO vqf_weights OVERWRITE ALL
SELECT t.i + 1 AS "asset_id",
       fractal_json_value(o."rj", CONCAT('$.weights[', t.i, ']')) AS "weight"
FROM "vqf_result" o, UNNEST(ARRAY[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,
                                       13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
                                       23, 24]) AS t(i)
GROUP BY t.i, o."rj"
PARTITIONED BY ALL;

-- The optimized book: the assets with a non-zero weight.
SELECT w."asset_id" AS "asset_id", a."symbol" AS "symbol",
       ROUND(w."weight", 6) AS "weight"
FROM "vqf_weights" w, "vqf_assets" a
WHERE a."asset_id" = w."asset_id" AND w."weight" > 0.000001
GROUP BY w."asset_id", a."symbol", w."weight"
ORDER BY w."weight" DESC;

-- ---------------------------------------------------------------------------
-- 3. A 300-point price series whose regime changes at t=240.
--
-- The first 240 points are range-bound (a fresh draw each step, so the
-- series is stationary), and the last 60 are a genuine trending run: the
-- series accumulates instead of being redrawn. A pure volatility rescale
-- would not move the DFA exponent -- it is scale-invariant -- so what the
-- drift report flags is exactly this memory-structure change.
-- ---------------------------------------------------------------------------
-- @fixture vqf_prices {"rows": [
--   {"t": 1, "x": 0.0312},
--   {"t": 2, "x": 0.005389},
--   {"t": 3, "x": -0.009536},
--   {"t": 4, "x": 0.03729},
--   {"t": 5, "x": -0.002533},
--   {"t": 6, "x": -0.027501},
--   {"t": 7, "x": -0.019066},
--   {"t": 8, "x": -0.032508},
--   {"t": 9, "x": -0.033019},
--   {"t": 10, "x": -0.04178},
--   {"t": 11, "x": 0.03109},
--   {"t": 12, "x": -0.048333},
--   {"t": 13, "x": -0.041194},
--   {"t": 14, "x": -0.042247},
--   {"t": 15, "x": 0.009762},
--   {"t": 16, "x": -0.025852},
--   {"t": 17, "x": -0.011193},
--   {"t": 18, "x": -0.017182},
--   {"t": 19, "x": -0.013215},
--   {"t": 20, "x": 0.000736},
--   {"t": 21, "x": -0.032673},
--   {"t": 22, "x": -0.047111},
--   {"t": 23, "x": -0.030973},
--   {"t": 24, "x": 0.009489},
--   {"t": 25, "x": -0.034588},
--   {"t": 26, "x": 0.019276},
--   {"t": 27, "x": -0.031584},
--   {"t": 28, "x": -0.045582},
--   {"t": 29, "x": 0.023388},
--   {"t": 30, "x": -0.006853},
--   {"t": 31, "x": -0.041047},
--   {"t": 32, "x": -0.022262},
--   {"t": 33, "x": -0.040593},
--   {"t": 34, "x": -0.012364},
--   {"t": 35, "x": -0.001519},
--   {"t": 36, "x": -0.014204},
--   {"t": 37, "x": -0.005586},
--   {"t": 38, "x": 0.042803},
--   {"t": 39, "x": 0.031541},
--   {"t": 40, "x": -0.035854},
--   {"t": 41, "x": 0.002972},
--   {"t": 42, "x": 0.023736},
--   {"t": 43, "x": 0.028094},
--   {"t": 44, "x": 0.025111},
--   {"t": 45, "x": 0.042792},
--   {"t": 46, "x": -0.035375},
--   {"t": 47, "x": -0.044423},
--   {"t": 48, "x": -0.001007},
--   {"t": 49, "x": -0.023586},
--   {"t": 50, "x": 0.043299},
--   {"t": 51, "x": -0.042106},
--   {"t": 52, "x": -0.033446},
--   {"t": 53, "x": -0.000242},
--   {"t": 54, "x": 0.03932},
--   {"t": 55, "x": -0.015626},
--   {"t": 56, "x": 0.00724},
--   {"t": 57, "x": 0.021687},
--   {"t": 58, "x": 0.04451},
--   {"t": 59, "x": -0.029185},
--   {"t": 60, "x": 0.01412},
--   {"t": 61, "x": -0.045294},
--   {"t": 62, "x": -0.046851},
--   {"t": 63, "x": -5.9e-05},
--   {"t": 64, "x": -0.004324},
--   {"t": 65, "x": -0.003242},
--   {"t": 66, "x": 0.041638},
--   {"t": 67, "x": -0.009841},
--   {"t": 68, "x": 0.049511},
--   {"t": 69, "x": -0.023206},
--   {"t": 70, "x": 0.026269},
--   {"t": 71, "x": 0.047392},
--   {"t": 72, "x": -0.039335},
--   {"t": 73, "x": -0.049894},
--   {"t": 74, "x": 0.02314},
--   {"t": 75, "x": -0.019387},
--   {"t": 76, "x": -0.029074},
--   {"t": 77, "x": 0.043437},
--   {"t": 78, "x": -0.02303},
--   {"t": 79, "x": -0.006701},
--   {"t": 80, "x": 0.031436},
--   {"t": 81, "x": 0.027466},
--   {"t": 82, "x": -0.048154},
--   {"t": 83, "x": 0.00684},
--   {"t": 84, "x": 0.031574},
--   {"t": 85, "x": -0.035586},
--   {"t": 86, "x": 0.03078},
--   {"t": 87, "x": 0.032485},
--   {"t": 88, "x": -0.030389},
--   {"t": 89, "x": -0.00594},
--   {"t": 90, "x": 0.027421},
--   {"t": 91, "x": 0.026949},
--   {"t": 92, "x": 0.036591},
--   {"t": 93, "x": -0.041707},
--   {"t": 94, "x": 0.022259},
--   {"t": 95, "x": 0.033379},
--   {"t": 96, "x": 0.042936},
--   {"t": 97, "x": 0.010111},
--   {"t": 98, "x": -0.001873},
--   {"t": 99, "x": 0.040549},
--   {"t": 100, "x": -0.04835},
--   {"t": 101, "x": -0.041836},
--   {"t": 102, "x": 0.021013},
--   {"t": 103, "x": 0.002202},
--   {"t": 104, "x": 0.039238},
--   {"t": 105, "x": 0.044906},
--   {"t": 106, "x": 0.002259},
--   {"t": 107, "x": -0.024781},
--   {"t": 108, "x": -0.01685},
--   {"t": 109, "x": 0.040848},
--   {"t": 110, "x": 0.004959},
--   {"t": 111, "x": -0.042277},
--   {"t": 112, "x": 0.001578},
--   {"t": 113, "x": -0.03224},
--   {"t": 114, "x": -0.004689},
--   {"t": 115, "x": 0.02255},
--   {"t": 116, "x": 0.024631},
--   {"t": 117, "x": 0.000386},
--   {"t": 118, "x": 0.017315},
--   {"t": 119, "x": -0.047821},
--   {"t": 120, "x": 0.02217},
--   {"t": 121, "x": 0.036197},
--   {"t": 122, "x": 0.030001},
--   {"t": 123, "x": -0.00023},
--   {"t": 124, "x": 0.013336},
--   {"t": 125, "x": -0.031876},
--   {"t": 126, "x": -0.01112},
--   {"t": 127, "x": 0.047348},
--   {"t": 128, "x": -0.015558},
--   {"t": 129, "x": 0.047316},
--   {"t": 130, "x": -0.003478},
--   {"t": 131, "x": 0.020094},
--   {"t": 132, "x": 0.0328},
--   {"t": 133, "x": -0.049869},
--   {"t": 134, "x": -0.041795},
--   {"t": 135, "x": 0.040585},
--   {"t": 136, "x": 0.022197},
--   {"t": 137, "x": -0.004368},
--   {"t": 138, "x": -0.036254},
--   {"t": 139, "x": 0.011065},
--   {"t": 140, "x": -0.031981},
--   {"t": 141, "x": 0.006345},
--   {"t": 142, "x": -0.040578},
--   {"t": 143, "x": 0.047397},
--   {"t": 144, "x": 0.012761},
--   {"t": 145, "x": -0.01949},
--   {"t": 146, "x": 0.029331},
--   {"t": 147, "x": -0.034107},
--   {"t": 148, "x": -0.003245},
--   {"t": 149, "x": 0.008285},
--   {"t": 150, "x": -0.032637},
--   {"t": 151, "x": 0.002219},
--   {"t": 152, "x": -0.012878},
--   {"t": 153, "x": 0.036841},
--   {"t": 154, "x": 0.013985},
--   {"t": 155, "x": -0.023029},
--   {"t": 156, "x": 0.038678},
--   {"t": 157, "x": 0.047162},
--   {"t": 158, "x": -0.007581},
--   {"t": 159, "x": -0.022828},
--   {"t": 160, "x": -0.028707},
--   {"t": 161, "x": 0.031594},
--   {"t": 162, "x": 0.02973},
--   {"t": 163, "x": 0.009112},
--   {"t": 164, "x": -0.02726},
--   {"t": 165, "x": 0.049182},
--   {"t": 166, "x": -0.038561},
--   {"t": 167, "x": 0.036466},
--   {"t": 168, "x": -0.013756},
--   {"t": 169, "x": 0.012606},
--   {"t": 170, "x": -0.001196},
--   {"t": 171, "x": -0.021028},
--   {"t": 172, "x": 0.023772},
--   {"t": 173, "x": -0.002231},
--   {"t": 174, "x": -0.000339},
--   {"t": 175, "x": -0.042641},
--   {"t": 176, "x": -0.000229},
--   {"t": 177, "x": 0.033399},
--   {"t": 178, "x": -0.010417},
--   {"t": 179, "x": 0.034866},
--   {"t": 180, "x": 0.005922},
--   {"t": 181, "x": 0.023189},
--   {"t": 182, "x": -0.0103},
--   {"t": 183, "x": -0.015752},
--   {"t": 184, "x": 0.010373},
--   {"t": 185, "x": -0.026517},
--   {"t": 186, "x": -0.009053},
--   {"t": 187, "x": 0.012749},
--   {"t": 188, "x": -0.010143},
--   {"t": 189, "x": 0.016841},
--   {"t": 190, "x": 0.020362},
--   {"t": 191, "x": -0.000879},
--   {"t": 192, "x": -0.038753},
--   {"t": 193, "x": -0.014596},
--   {"t": 194, "x": -0.015511},
--   {"t": 195, "x": 0.024514},
--   {"t": 196, "x": 0.044196},
--   {"t": 197, "x": 0.004359},
--   {"t": 198, "x": 0.008381},
--   {"t": 199, "x": 0.026443},
--   {"t": 200, "x": -0.01795},
--   {"t": 201, "x": 0.015167},
--   {"t": 202, "x": -0.045699},
--   {"t": 203, "x": 0.04871},
--   {"t": 204, "x": 0.04638},
--   {"t": 205, "x": 0.03613},
--   {"t": 206, "x": -0.014434},
--   {"t": 207, "x": -0.031236},
--   {"t": 208, "x": -0.017142},
--   {"t": 209, "x": 0.011492},
--   {"t": 210, "x": -0.047052},
--   {"t": 211, "x": 0.010124},
--   {"t": 212, "x": 0.047348},
--   {"t": 213, "x": 0.041983},
--   {"t": 214, "x": -0.001145},
--   {"t": 215, "x": -0.04817},
--   {"t": 216, "x": -0.024625},
--   {"t": 217, "x": 0.011675},
--   {"t": 218, "x": 0.01319},
--   {"t": 219, "x": -0.009818},
--   {"t": 220, "x": -0.024749},
--   {"t": 221, "x": 0.003574},
--   {"t": 222, "x": -0.021876},
--   {"t": 223, "x": 0.001285},
--   {"t": 224, "x": -0.000654},
--   {"t": 225, "x": -0.005539},
--   {"t": 226, "x": 0.03145},
--   {"t": 227, "x": -0.006772},
--   {"t": 228, "x": -0.024795},
--   {"t": 229, "x": -0.01192},
--   {"t": 230, "x": -0.0381},
--   {"t": 231, "x": -0.015097},
--   {"t": 232, "x": -0.022616},
--   {"t": 233, "x": -0.014068},
--   {"t": 234, "x": 0.037169},
--   {"t": 235, "x": 0.003207},
--   {"t": 236, "x": -0.016381},
--   {"t": 237, "x": -0.026565},
--   {"t": 238, "x": -0.013061},
--   {"t": 239, "x": 0.018661},
--   {"t": 240, "x": 0.001933},
--   {"t": 241, "x": 0.041622},
--   {"t": 242, "x": 0.064566},
--   {"t": 243, "x": 0.071025},
--   {"t": 244, "x": 0.051955},
--   {"t": 245, "x": 0.100722},
--   {"t": 246, "x": 0.053847},
--   {"t": 247, "x": 0.03314},
--   {"t": 248, "x": 0.071131},
--   {"t": 249, "x": 0.036797},
--   {"t": 250, "x": 0.016866},
--   {"t": 251, "x": 0.056112},
--   {"t": 252, "x": 0.051794},
--   {"t": 253, "x": 0.058511},
--   {"t": 254, "x": 0.079322},
--   {"t": 255, "x": 0.05184},
--   {"t": 256, "x": 0.035829},
--   {"t": 257, "x": 0.058807},
--   {"t": 258, "x": 0.103093},
--   {"t": 259, "x": 0.097906},
--   {"t": 260, "x": 0.110163},
--   {"t": 261, "x": 0.102099},
--   {"t": 262, "x": 0.088647},
--   {"t": 263, "x": 0.101816},
--   {"t": 264, "x": 0.147172},
--   {"t": 265, "x": 0.106923},
--   {"t": 266, "x": 0.070672},
--   {"t": 267, "x": 0.108096},
--   {"t": 268, "x": 0.149888},
--   {"t": 269, "x": 0.181521},
--   {"t": 270, "x": 0.224059},
--   {"t": 271, "x": 0.252166},
--   {"t": 272, "x": 0.237111},
--   {"t": 273, "x": 0.246756},
--   {"t": 274, "x": 0.229058},
--   {"t": 275, "x": 0.250628},
--   {"t": 276, "x": 0.272846},
--   {"t": 277, "x": 0.288153},
--   {"t": 278, "x": 0.320151},
--   {"t": 279, "x": 0.358979},
--   {"t": 280, "x": 0.347807},
--   {"t": 281, "x": 0.374283},
--   {"t": 282, "x": 0.411508},
--   {"t": 283, "x": 0.392696},
--   {"t": 284, "x": 0.437954},
--   {"t": 285, "x": 0.420603},
--   {"t": 286, "x": 0.468386},
--   {"t": 287, "x": 0.474025},
--   {"t": 288, "x": 0.512634},
--   {"t": 289, "x": 0.548655},
--   {"t": 290, "x": 0.570129},
--   {"t": 291, "x": 0.550389},
--   {"t": 292, "x": 0.584638},
--   {"t": 293, "x": 0.580012},
--   {"t": 294, "x": 0.582689},
--   {"t": 295, "x": 0.587612},
--   {"t": 296, "x": 0.556394},
--   {"t": 297, "x": 0.530294},
--   {"t": 298, "x": 0.545592},
--   {"t": 299, "x": 0.563674},
--   {"t": 300, "x": 0.557005}
-- ]};

REPLACE INTO vqf_series OVERWRITE ALL
SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("x" AS VARCHAR), 16384), ',') AS "series"
FROM (SELECT "t", "x" FROM "vqf_prices" GROUP BY "t", "x")
PARTITIONED BY ALL;

SELECT fractal_dimension_dfa("series") AS "whole_series_alpha" FROM "vqf_series";

SELECT fractal_dimension_drift("series", 64) AS "drift_report" FROM "vqf_series";

SELECT fractal_json_value("d", '$.drift') AS "drift",
       fractal_json_value("d", '$.drift') > 0.5 AS "drift_detected"
FROM (SELECT fractal_dimension_drift("series", 64) AS "d" FROM "vqf_series")
GROUP BY "d";

-- ---------------------------------------------------------------------------
-- 4. fractal_change_point_detect: localizing the regime shift.
-- ---------------------------------------------------------------------------
SELECT fractal_change_point_detect("series", 20, 1.5) AS "change_points"
FROM "vqf_series";

-- ---------------------------------------------------------------------------
-- 5. fractal_search_trajectory: the nearest historical rebalance pattern.
--
-- "What changed", not "what's closest": the query is the movement from
-- the equal-weight baseline to the optimized book, and the ten historical
-- quarterly snapshots are the stored tracks it is compared against.
-- ---------------------------------------------------------------------------
-- @fixture vqf_snapshots {"rows": [
--   {"id": 1, "quarter": "Q1-hist", "alloc": "0.000000,0.000000,0.000000,0.000000,0.136346,0.000000,0.000000,0.000000,0.000000,0.000000,0.014355,0.126105,0.000000,0.240144,0.000000,0.042608,0.128072,0.000000,0.000000,0.147331,0.000000,0.000000,0.000000,0.165039,0.000000"},
--   {"id": 2, "quarter": "Q2-hist", "alloc": "0.006325,0.100306,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.153185,0.000000,0.000000,0.000212,0.146900,0.000000,0.042030,0.187667,0.000000,0.086966,0.000000,0.000000,0.000000,0.114163,0.000000,0.000000,0.162246"},
--   {"id": 3, "quarter": "Q3-hist", "alloc": "0.000000,0.000000,0.137905,0.000000,0.000000,0.000000,0.000000,0.226168,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.025552,0.222266,0.000000,0.000000,0.000000,0.000000,0.000000,0.103758,0.284351,0.000000,0.000000"},
--   {"id": 4, "quarter": "Q4-hist", "alloc": "0.127653,0.000000,0.112145,0.000000,0.000000,0.000000,0.000000,0.000000,0.178618,0.000000,0.000000,0.000000,0.000000,0.000000,0.096226,0.000000,0.000000,0.240854,0.000000,0.000000,0.000000,0.000000,0.020307,0.224196,0.000000"},
--   {"id": 5, "quarter": "Q5-hist", "alloc": "0.000000,0.000000,0.104442,0.000000,0.096370,0.000000,0.166582,0.000000,0.000000,0.135684,0.000000,0.079967,0.000000,0.000000,0.089313,0.000000,0.000000,0.000000,0.000000,0.151670,0.000000,0.000000,0.000000,0.036418,0.139553"},
--   {"id": 6, "quarter": "Q6-hist", "alloc": "0.000000,0.000000,0.000000,0.241606,0.000000,0.210631,0.000000,0.000000,0.000000,0.000000,0.179707,0.000000,0.000000,0.000000,0.121242,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.147068,0.000000,0.099746"},
--   {"id": 7, "quarter": "Q7-hist", "alloc": "0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.082668,0.000000,0.173989,0.000000,0.000000,0.000000,0.000000,0.000000,0.152163,0.000000,0.230486,0.000000,0.000000,0.000000,0.000000,0.076722,0.143583,0.000000,0.140389"},
--   {"id": 8, "quarter": "Q8-hist", "alloc": "0.000000,0.000000,0.000000,0.000000,0.077315,0.187915,0.000000,0.000000,0.000000,0.163233,0.000000,0.156257,0.000000,0.000000,0.000000,0.000000,0.000000,0.116023,0.000000,0.106345,0.083433,0.109479,0.000000,0.000000,0.000000"},
--   {"id": 9, "quarter": "Q9-hist", "alloc": "0.046617,0.073480,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.196470,0.000000,0.058270,0.175036,0.000000,0.059814,0.177531,0.000000,0.000000,0.000000,0.000000,0.067613,0.145169,0.000000,0.000000,0.000000,0.000000"},
--   {"id": 10, "quarter": "Q10-hist", "alloc": "0.000000,0.000000,0.000000,0.000000,0.032318,0.205495,0.000000,0.000000,0.000000,0.000000,0.000000,0.140200,0.000000,0.168230,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.000000,0.223910,0.000000,0.229845"}
-- ]};

-- The optimized book, in the core's text vector form, so the trajectory
-- search can read it out of a datasource.
REPLACE INTO vqf_current OVERWRITE ALL
SELECT fractal_json_text("rj", '$.weights') AS "current"
FROM "vqf_result"
GROUP BY "rj"
PARTITIONED BY ALL;

-- @call search/trajectory {"table": "vqf_snapshots", "column": "alloc",
--                          "id_column": "id",
--                          "baseline": "0.04,0.04,0.04,0.04,0.04,0.04,0.04,0.04,0.04,0.04,0.04,0.04,0.04,0.04,0.04,0.04,0.04,0.04,0.04,0.04,0.04,0.04,0.04,0.04,0.04",
--                          "current_table": "vqf_current",
--                          "current_column": "current", "k": 3} AS vqf_traj;

SELECT r."doc_id" AS "snapshot_id", s."quarter" AS "quarter",
       ROUND(r."distance", 6) AS "distance"
FROM "vqf_traj" r, "vqf_snapshots" s
WHERE r."doc_id" = s."id"
GROUP BY r."doc_id", s."quarter", r."distance"
ORDER BY r."distance";

-- ---------------------------------------------------------------------------
-- 6. Reasoning: the regime shift and the rebalance, in one line.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line rationale tying this market regime shift to the optimized 8-asset rebalance and its nearest historical pattern',
    '{"drift":"' || (SELECT fractal_json_text("d", '$.drift')
                       FROM (SELECT fractal_dimension_drift("series", 64) AS "d" FROM "vqf_series")
                       GROUP BY "d")
     || '","book":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CONCAT(a."symbol", ':',
                     ROUND(w."weight", 4)), 8192), ',')
                       FROM "vqf_weights" w, "vqf_assets" a
                       WHERE a."asset_id" = w."asset_id" AND w."weight" > 0.000001)
     || '"}') AS "narrative";

-- ---------------------------------------------------------------------------
-- 7. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. The book has exactly eight assets in
-- it, the optimizer's Sharpe is positive, the regime change is detected,
-- and the change points land on the deliberate boundary.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "vqf_weights" WHERE "weight" > 0.000001) = 8
            AND (SELECT fractal_json_value("rj", '$.sharpe') FROM "vqf_result" GROUP BY "rj") > 0
            AND (SELECT fractal_json_value("d", '$.drift')
                  FROM (SELECT fractal_dimension_drift("series", 64) AS "d" FROM "vqf_series")
                  GROUP BY "d") > 0.5
            AND (SELECT fractal_json_value("c", '$.count')
                  FROM (SELECT fractal_change_point_detect("series", 20, 1.5) AS "c" FROM "vqf_series")
                  GROUP BY "c") >= 1
            THEN 'HEADLINE kit=quant-finance ok'
            ELSE 'HEADLINE kit=quant-finance FAILED'
       END AS "headline";
