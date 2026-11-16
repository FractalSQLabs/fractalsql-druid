-- demo/demo-vertical-avionics-fault-prediction.sql
--
-- FractalSQL for Apache Druid -- industry vertical: aerospace, avionics
-- and flight-path fault prediction across a fleet. A DOMAIN kit built on
-- one installed agent, fractal_agent_track_anomaly, which generalises
-- directly from the maritime-defense kit's 2D tracks to 3D flight paths:
-- same agent, same contract (trajectory deviation search plus a
-- heading-change exponent), closing with a reasoned classification of
-- the deviation.
--
--   1. A twelve-aircraft fleet: planned path vs. current state in 3D.
--   2. The heading-change series: a steady transit against AC-09's
--      erratic stretch, and the exponent each one carries.
--   3. AC-09's baseline-to-current trajectory search.
--   4. fractal_agent_track_anomaly: the same reading, as one document.
--   5. Reasoning: the classification of the deviation.
--
-- Prerequisites: the extension is loaded on the Druid cluster. The
-- agent's rationale and the closing classification need a reasoning
-- provider (docs/reasoning-setup.md); every other step runs with no
-- model.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-avionics-fault-prediction.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The fleet and the two heading series are fixtures: Druid has no
--     DDL, no row-source literal and no recursive CTE, and a set of
--     rows has no SQL form there. The integer generator is the deterministic sin-hash the other kits use, so the kit is reproducible.
--   * The heading series is a fixture whose rows carry the walk itself: Druid has
--     no window functions, and a fixture's rows keep their order
--     through the write and the scan.
--   * The trajectory search and the agent are service calls: an agent
--     reads a table and reasons about it, and a Druid SQL function can
--     do neither. The agent is handed the heading series as text, which
--     is the shape it takes on this host.
--   * The closing narrative is a fractal_reason() call over a JSON
--     context the kit assembles from its own result rows.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * AC-09 carries a stuck control surface: its path has drifted far
--     off plan and its heading changes become erratic for a stretch of
--     the flight.
--   * The flight-path vector is [x_km, y_km, altitude_km] in CSV TEXT.
--   * The trajectory search's doc_id is the fleet row's own id, so the
--     result joins straight back to the fleet.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. A twelve-aircraft fleet: planned path vs. current state in 3D.
--
-- Eleven are on plan to within small offsets; AC-09 has drifted far off
-- plan (laterally and vertically).
-- ---------------------------------------------------------------------------
-- @fixture afp_flights {"rows": [
--   {"id": 1, "flight": "AC-01", "baseline": "0.250,0.420,0.800", "current": "0.254,0.423,0.798"},
--   {"id": 2, "flight": "AC-02", "baseline": "0.300,0.440,0.800", "current": "0.308,0.440,0.796"},
--   {"id": 3, "flight": "AC-03", "baseline": "0.350,0.460,0.800", "current": "0.350,0.463,0.800"},
--   {"id": 4, "flight": "AC-04", "baseline": "0.400,0.400,0.800", "current": "0.404,0.400,0.798"},
--   {"id": 5, "flight": "AC-05", "baseline": "0.450,0.420,0.800", "current": "0.458,0.423,0.796"},
--   {"id": 6, "flight": "AC-06", "baseline": "0.500,0.440,0.800", "current": "0.500,0.440,0.800"},
--   {"id": 7, "flight": "AC-07", "baseline": "0.550,0.460,0.800", "current": "0.554,0.463,0.798"},
--   {"id": 8, "flight": "AC-08", "baseline": "0.600,0.400,0.800", "current": "0.608,0.400,0.796"},
--   {"id": 9, "flight": "AC-09", "baseline": "0.650,0.420,0.800", "current": "0.900,1.400,0.350"},
--   {"id": 10, "flight": "AC-10", "baseline": "0.700,0.440,0.800", "current": "0.704,0.440,0.798"},
--   {"id": 11, "flight": "AC-11", "baseline": "0.750,0.460,0.800", "current": "0.758,0.463,0.796"},
--   {"id": 12, "flight": "AC-12", "baseline": "0.800,0.400,0.800", "current": "0.800,0.400,0.800"}
-- ]};

SELECT "flight", "baseline", "current" FROM "afp_flights"
WHERE "flight" IN ('AC-01', 'AC-09');

-- How far off plan each aircraft is.
-- ---------------------------------------------------------------------------
REPLACE INTO afp_offplan OVERWRITE ALL
SELECT "flight",
       fractal_vector_l2_distance("baseline", "current") AS "off_plan_km"
FROM "afp_flights"
GROUP BY "flight", "baseline", "current"
PARTITIONED BY ALL;

SELECT "flight", ROUND("off_plan_km", 3) AS "off_plan_km" FROM "afp_offplan"
GROUP BY "flight", "off_plan_km" ORDER BY "flight";

-- ---------------------------------------------------------------------------
-- 2. The heading-change series: a steady transit (small noise) against
-- AC-09's erratic stretch (large swings between samples 60 and 90).
--
-- The walks are fixtures: Druid has no window functions, and a fixture's
-- rows keep their order, so the exponent still sees the walk in the
-- right order.
-- ---------------------------------------------------------------------------
-- @fixture afp_walk_steady {"rows": [
--   {"t": 1, "s": -0.005127},
--   {"t": 2, "s": -0.003938},
--   {"t": 3, "s": 0.010207},
--   {"t": 4, "s": 0.019843},
--   {"t": 5, "s": 0.010214},
--   {"t": 6, "s": 0.02507},
--   {"t": 7, "s": 0.03455},
--   {"t": 8, "s": 0.032805},
--   {"t": 9, "s": 0.045611},
--   {"t": 10, "s": 0.043637},
--   {"t": 11, "s": 0.047963},
--   {"t": 12, "s": 0.042642},
--   {"t": 13, "s": 0.050453},
--   {"t": 14, "s": 0.052134},
--   {"t": 15, "s": 0.05696},
--   {"t": 16, "s": 0.054541},
--   {"t": 17, "s": 0.043614},
--   {"t": 18, "s": 0.038528},
--   {"t": 19, "s": 0.038387},
--   {"t": 20, "s": 0.023397},
--   {"t": 21, "s": 0.013254},
--   {"t": 22, "s": 0.01086},
--   {"t": 23, "s": 0.025412},
--   {"t": 24, "s": 0.032115},
--   {"t": 25, "s": 0.025686},
--   {"t": 26, "s": 0.023227},
--   {"t": 27, "s": 0.014245},
--   {"t": 28, "s": 0.016522},
--   {"t": 29, "s": 0.030968},
--   {"t": 30, "s": 0.043585},
--   {"t": 31, "s": 0.042693},
--   {"t": 32, "s": 0.05074},
--   {"t": 33, "s": 0.053639},
--   {"t": 34, "s": 0.066667},
--   {"t": 35, "s": 0.06526},
--   {"t": 36, "s": 0.056723},
--   {"t": 37, "s": 0.062564},
--   {"t": 38, "s": 0.071443},
--   {"t": 39, "s": 0.064939},
--   {"t": 40, "s": 0.065356},
--   {"t": 41, "s": 0.054632},
--   {"t": 42, "s": 0.043063},
--   {"t": 43, "s": 0.037129},
--   {"t": 44, "s": 0.025606},
--   {"t": 45, "s": 0.034966},
--   {"t": 46, "s": 0.036583},
--   {"t": 47, "s": 0.033722},
--   {"t": 48, "s": 0.044909},
--   {"t": 49, "s": 0.044149},
--   {"t": 50, "s": 0.035899},
--   {"t": 51, "s": 0.030179},
--   {"t": 52, "s": 0.020427},
--   {"t": 53, "s": 0.010521},
--   {"t": 54, "s": -0.002013},
--   {"t": 55, "s": 0.007314},
--   {"t": 56, "s": -0.007186},
--   {"t": 57, "s": -0.019544},
--   {"t": 58, "s": -0.032218},
--   {"t": 59, "s": -0.02929},
--   {"t": 60, "s": -0.037046},
--   {"t": 61, "s": -0.040403},
--   {"t": 62, "s": -0.045558},
--   {"t": 63, "s": -0.049523},
--   {"t": 64, "s": -0.049302},
--   {"t": 65, "s": -0.059104},
--   {"t": 66, "s": -0.073237},
--   {"t": 67, "s": -0.082529},
--   {"t": 68, "s": -0.079682},
--   {"t": 69, "s": -0.090058},
--   {"t": 70, "s": -0.084276},
--   {"t": 71, "s": -0.093751},
--   {"t": 72, "s": -0.107425},
--   {"t": 73, "s": -0.100409},
--   {"t": 74, "s": -0.102465},
--   {"t": 75, "s": -0.114779},
--   {"t": 76, "s": -0.121458},
--   {"t": 77, "s": -0.133635},
--   {"t": 78, "s": -0.137345},
--   {"t": 79, "s": -0.1378},
--   {"t": 80, "s": -0.142062},
--   {"t": 81, "s": -0.143737},
--   {"t": 82, "s": -0.130897},
--   {"t": 83, "s": -0.121434},
--   {"t": 84, "s": -0.13219},
--   {"t": 85, "s": -0.131299},
--   {"t": 86, "s": -0.124178},
--   {"t": 87, "s": -0.11575},
--   {"t": 88, "s": -0.108216},
--   {"t": 89, "s": -0.095379},
--   {"t": 90, "s": -0.105991},
--   {"t": 91, "s": -0.119318},
--   {"t": 92, "s": -0.11962},
--   {"t": 93, "s": -0.126696},
--   {"t": 94, "s": -0.113706},
--   {"t": 95, "s": -0.126338},
--   {"t": 96, "s": -0.136372},
--   {"t": 97, "s": -0.136445},
--   {"t": 98, "s": -0.124649},
--   {"t": 99, "s": -0.129337},
--   {"t": 100, "s": -0.127165},
--   {"t": 101, "s": -0.120658},
--   {"t": 102, "s": -0.107306},
--   {"t": 103, "s": -0.116061},
--   {"t": 104, "s": -0.111825},
--   {"t": 105, "s": -0.125413},
--   {"t": 106, "s": -0.139469},
--   {"t": 107, "s": -0.139486},
--   {"t": 108, "s": -0.140784},
--   {"t": 109, "s": -0.141756},
--   {"t": 110, "s": -0.129265},
--   {"t": 111, "s": -0.132217},
--   {"t": 112, "s": -0.117364},
--   {"t": 113, "s": -0.124325},
--   {"t": 114, "s": -0.116445},
--   {"t": 115, "s": -0.102227},
--   {"t": 116, "s": -0.114028},
--   {"t": 117, "s": -0.128996},
--   {"t": 118, "s": -0.122054},
--   {"t": 119, "s": -0.12787},
--   {"t": 120, "s": -0.136592}
-- ]};

-- @fixture afp_walk_erratic {"rows": [
--   {"t": 1, "s": 0.007811},
--   {"t": 2, "s": 0.009492},
--   {"t": 3, "s": 0.014319},
--   {"t": 4, "s": 0.011899},
--   {"t": 5, "s": 0.000972},
--   {"t": 6, "s": -0.004114},
--   {"t": 7, "s": -0.004255},
--   {"t": 8, "s": -0.019245},
--   {"t": 9, "s": -0.029388},
--   {"t": 10, "s": -0.031782},
--   {"t": 11, "s": -0.01723},
--   {"t": 12, "s": -0.010527},
--   {"t": 13, "s": -0.016956},
--   {"t": 14, "s": -0.019415},
--   {"t": 15, "s": -0.028397},
--   {"t": 16, "s": -0.026119},
--   {"t": 17, "s": -0.011674},
--   {"t": 18, "s": 0.000943},
--   {"t": 19, "s": 5.1e-05},
--   {"t": 20, "s": 0.008098},
--   {"t": 21, "s": 0.010997},
--   {"t": 22, "s": 0.024025},
--   {"t": 23, "s": 0.022618},
--   {"t": 24, "s": 0.014081},
--   {"t": 25, "s": 0.019922},
--   {"t": 26, "s": 0.028801},
--   {"t": 27, "s": 0.022297},
--   {"t": 28, "s": 0.022714},
--   {"t": 29, "s": 0.01199},
--   {"t": 30, "s": 0.000421},
--   {"t": 31, "s": -0.005513},
--   {"t": 32, "s": -0.017036},
--   {"t": 33, "s": -0.007676},
--   {"t": 34, "s": -0.006059},
--   {"t": 35, "s": -0.00892},
--   {"t": 36, "s": 0.002267},
--   {"t": 37, "s": 0.001507},
--   {"t": 38, "s": -0.006743},
--   {"t": 39, "s": -0.012463},
--   {"t": 40, "s": -0.022215},
--   {"t": 41, "s": -0.032121},
--   {"t": 42, "s": -0.044655},
--   {"t": 43, "s": -0.035328},
--   {"t": 44, "s": -0.049828},
--   {"t": 45, "s": -0.062186},
--   {"t": 46, "s": -0.07486},
--   {"t": 47, "s": -0.071932},
--   {"t": 48, "s": -0.079687},
--   {"t": 49, "s": -0.083045},
--   {"t": 50, "s": -0.0882},
--   {"t": 51, "s": -0.092165},
--   {"t": 52, "s": -0.091944},
--   {"t": 53, "s": -0.101746},
--   {"t": 54, "s": -0.115879},
--   {"t": 55, "s": -0.125171},
--   {"t": 56, "s": -0.122324},
--   {"t": 57, "s": -0.1327},
--   {"t": 58, "s": -0.126918},
--   {"t": 59, "s": -0.136393},
--   {"t": 60, "s": -0.295928},
--   {"t": 61, "s": -0.21407},
--   {"t": 62, "s": -0.238057},
--   {"t": 63, "s": -0.381721},
--   {"t": 64, "s": -0.459639},
--   {"t": 65, "s": -0.601713},
--   {"t": 66, "s": -0.644988},
--   {"t": 67, "s": -0.650304},
--   {"t": 68, "s": -0.700018},
--   {"t": 69, "s": -0.719569},
--   {"t": 70, "s": -0.56976},
--   {"t": 71, "s": -0.459365},
--   {"t": 72, "s": -0.584853},
--   {"t": 73, "s": -0.57445},
--   {"t": 74, "s": -0.491373},
--   {"t": 75, "s": -0.393044},
--   {"t": 76, "s": -0.305155},
--   {"t": 77, "s": -0.155383},
--   {"t": 78, "s": -0.279196},
--   {"t": 79, "s": -0.434676},
--   {"t": 80, "s": -0.438199},
--   {"t": 81, "s": -0.520751},
--   {"t": 82, "s": -0.369205},
--   {"t": 83, "s": -0.516577},
--   {"t": 84, "s": -0.633639},
--   {"t": 85, "s": -0.634488},
--   {"t": 86, "s": -0.496869},
--   {"t": 87, "s": -0.551559},
--   {"t": 88, "s": -0.526219},
--   {"t": 89, "s": -0.450315},
--   {"t": 90, "s": -0.294531},
--   {"t": 91, "s": -0.303287},
--   {"t": 92, "s": -0.299051},
--   {"t": 93, "s": -0.312639},
--   {"t": 94, "s": -0.326695},
--   {"t": 95, "s": -0.326712},
--   {"t": 96, "s": -0.328009},
--   {"t": 97, "s": -0.328982},
--   {"t": 98, "s": -0.316491},
--   {"t": 99, "s": -0.319443},
--   {"t": 100, "s": -0.30459},
--   {"t": 101, "s": -0.311551},
--   {"t": 102, "s": -0.303671},
--   {"t": 103, "s": -0.289453},
--   {"t": 104, "s": -0.301254},
--   {"t": 105, "s": -0.316222},
--   {"t": 106, "s": -0.30928},
--   {"t": 107, "s": -0.315096},
--   {"t": 108, "s": -0.323818},
--   {"t": 109, "s": -0.310787},
--   {"t": 110, "s": -0.317696},
--   {"t": 111, "s": -0.319706},
--   {"t": 112, "s": -0.310275},
--   {"t": 113, "s": -0.302035},
--   {"t": 114, "s": -0.316482},
--   {"t": 115, "s": -0.31443},
--   {"t": 116, "s": -0.304957},
--   {"t": 117, "s": -0.315633},
--   {"t": 118, "s": -0.306399},
--   {"t": 119, "s": -0.296654},
--   {"t": 120, "s": -0.30577}
-- ]};

-- The exponent and the excursion each series carries.
REPLACE INTO afp_stats_steady OVERWRITE ALL
SELECT fractal_dimension_dfa(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("s" AS VARCHAR), 16384), ',')) AS "alpha",
       MAX("s") - MIN("s") AS "excursion"
FROM "afp_walk_steady"
PARTITIONED BY ALL;

REPLACE INTO afp_stats_erratic OVERWRITE ALL
SELECT fractal_dimension_dfa(
           ARRAY_TO_STRING(ARRAY_AGG(CAST("s" AS VARCHAR), 16384), ',')) AS "alpha",
       MAX("s") - MIN("s") AS "excursion"
FROM "afp_walk_erratic"
PARTITIONED BY ALL;

SELECT "alpha", "excursion" FROM "afp_stats_steady";
SELECT "alpha", "excursion" FROM "afp_stats_erratic";

-- ---------------------------------------------------------------------------
-- 3. AC-09's baseline-to-current trajectory search.
--
-- The baseline and the current vector are read out of a datasource,
-- because they are computed.
-- ---------------------------------------------------------------------------
REPLACE INTO afp_ac09 OVERWRITE ALL
SELECT "baseline", "current" FROM "afp_flights" WHERE "flight" = 'AC-09'
PARTITIONED BY ALL;

-- @call search/trajectory {"table": "afp_flights", "column": "current", "id_column": "id",
--                         "baseline_table": "afp_ac09", "baseline_column": "baseline",
--                         "current_table": "afp_ac09", "current_column": "current",
--                         "k": 5} AS afp_traj;

SELECT r."doc_id" AS "id", f."flight" AS "flight", ROUND(r."distance", 4) AS "distance"
FROM "afp_traj" r, "afp_flights" f
WHERE r."doc_id" = f."id";

-- ---------------------------------------------------------------------------
-- 4. fractal_agent_track_anomaly: the nearest fleet aircraft, the
-- trajectory distance, the heading exponent and a rationale.
-- ---------------------------------------------------------------------------
-- @call agent/track_anomaly {"track_table": "afp_flights", "emb_col": "current",
--                           "baseline_vec_table": "afp_ac09", "baseline_vec_column": "baseline",
--                           "current_vec_table": "afp_ac09", "current_vec_column": "current",
--                           "heading_series_table": "afp_walk_erratic", "heading_series_column": "s",
--                           "heading_series": "0.007811,0.009492,0.014319,0.011899,0.000972,-0.004114,-0.004255,-0.019245,-0.029388,-0.031782,-0.017230,-0.010527,-0.016956,-0.019415,-0.028397,-0.026119,-0.011674,0.000943,0.000051,0.008098,0.010997,0.024025,0.022618,0.014081,0.019922,0.028801,0.022297,0.022714,0.011990,0.000421,-0.005513,-0.017036,-0.007676,-0.006059,-0.008920,0.002267,0.001507,-0.006743,-0.012463,-0.022215,-0.032121,-0.044655,-0.035328,-0.049828,-0.062186,-0.074860,-0.071932,-0.079687,-0.083045,-0.088200,-0.092165,-0.091944,-0.101746,-0.115879,-0.125171,-0.122324,-0.132700,-0.126918,-0.136393,-0.295928,-0.214070,-0.238057,-0.381721,-0.459639,-0.601713,-0.644988,-0.650304,-0.700018,-0.719569,-0.569760,-0.459365,-0.584853,-0.574450,-0.491373,-0.393044,-0.305155,-0.155383,-0.279196,-0.434676,-0.438199,-0.520751,-0.369205,-0.516577,-0.633639,-0.634488,-0.496869,-0.551559,-0.526219,-0.450315,-0.294531,-0.303287,-0.299051,-0.312639,-0.326695,-0.326712,-0.328009,-0.328982,-0.316491,-0.319443,-0.304590,-0.311551,-0.303671,-0.289453,-0.301254,-0.316222,-0.309280,-0.315096,-0.323818,-0.310787,-0.317696,-0.319706,-0.310275,-0.302035,-0.316482,-0.314430,-0.304957,-0.315633,-0.306399,-0.296654,-0.305770",
--                           "k": 5};

-- ---------------------------------------------------------------------------
-- 5. Reasoning: the classification of the deviation.
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line classification of this flight-path deviation: sensor fault, control-surface fault, or weather',
    '{"off_plan_flight":"' || (SELECT "flight" FROM "afp_offplan"
                                WHERE "off_plan_km" > 1.0 GROUP BY "flight")
     || '","dfa_steady":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("alpha" AS VARCHAR), 8192), ',')
                                 FROM "afp_stats_steady")
     || '","dfa_erratic":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("alpha" AS VARCHAR), 8192), ',')
                                   FROM "afp_stats_erratic")
     || '","trajectory":"' || (SELECT ARRAY_TO_STRING(ARRAY_AGG(CAST("distance" AS VARCHAR), 8192), ',')
                                FROM "afp_traj")
     || '"}') AS "classification";

-- ---------------------------------------------------------------------------
-- 6. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds. AC-09 is the only aircraft far off
-- plan, its heading walk swings far harder than a steady transit, and
-- the trajectory search returned its five nearest fleet neighbours.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT COUNT(*) FROM "afp_offplan" WHERE "off_plan_km" > 1.0) = 1
            AND (SELECT COUNT(*) FROM "afp_flights") = 12
            AND (SELECT "excursion" FROM "afp_stats_erratic")
                > 2 * (SELECT "excursion" FROM "afp_stats_steady")
            AND (SELECT COUNT(*) FROM "afp_traj") = 5
            THEN 'HEADLINE kit=avionics-fault-prediction ok'
            ELSE 'HEADLINE kit=avionics-fault-prediction FAILED'
       END AS "headline";
