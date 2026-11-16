-- demo/demo-vertical-rf-spectrum-sensing.sql
--
-- FractalSQL for Apache Druid -- industry vertical: RF spectrum sensing.
--
-- Three channels x 256 samples of received level.  CH-A is a beacon (a
-- period-8 tone plus a little noise) that is JAMMED from sample 161: the
-- tone is replaced by wideband noise.  CH-B is steady noise (an empty
-- channel).  CH-C is a steady period-16 telemetry carrier.
--
-- Calibration: a pure tone reads about 0.2-0.4 after the Hann taper,
-- white noise about 0.9 (a noise periodogram is itself randomly
-- distributed, so it does not reach 1.0).  Window 32 / hop 16 gives
-- 15 frames per channel; boundary indices are FRAME indices, so
-- sample position = frame_index * hop.
--
-- Run:
--   python3 demo/run_demo.py --file demo/demo-vertical-rf-spectrum-sensing.sql
--
-- ===========================================================================
-- Notes on how this runs on Druid
-- ===========================================================================
--
--   * The fixture is an MSQ write, not CREATE TABLE + INSERT, and each
--     channel is ONE row whose samples are an ARRAY column -- the shape
--     the fractal_* functions read.
--   * The noise is a deterministic hash of the sample index rather than a linear-congruential generator: an LCG is recursive and Druid has no recursive CTE. The hash is still
--     pseudo-random and still reproducible from run to run, which is
--     what the kit's claims rest on -- the claims are structural (a
--     jammed channel loses its order, a clean one does not), not tied
--     to particular noise values.
--   * fractal_json_value instead of json_extract: Druid's JSON_VALUE
--     reads a COMPLEX column, not a JSON string.
--
-- Safe to re-run: the fixture replaces the datasource's data.

-- ---------------------------------------------------------------------------
-- 0. Sanity check: extension loaded?
-- ---------------------------------------------------------------------------
SELECT fractal_edition(), fractal_version();

-- ---------------------------------------------------------------------------
-- 1. Capture: 3 channels x 256 samples.
--
-- The noise is the classic sin-hash of the sample index: a deterministic
-- pseudo-random value in [0, 1).
-- ---------------------------------------------------------------------------
REPLACE INTO rfs_capture OVERWRITE ALL
SELECT x.channel,
       -- ARRAY_AGG's size guardrail defaults to 1024 bytes; a
       -- 256-sample series is 2048.
       ARRAY_AGG(x.level, 8192) AS levels
FROM (
    SELECT s.channel,
           s.g AS seq,
           CASE s.channel
               WHEN 'CH-A' THEN CASE WHEN s.g <= 160
                                     THEN SIN(2 * 3.141592653589793 * s.g / 8.0) + 0.1 * n
                                     ELSE 1.2 * n
                                END
               WHEN 'CH-B' THEN 1.2 * n
               ELSE SIN(2 * 3.141592653589793 * s.g / 16.0) + 0.1 * n
           END AS level
    FROM (
        -- The noise: a deterministic pseudo-random value in [0, 1) from
        -- the sample index. It is computed here, in its own level, so
        -- the level expression above can use it.
        SELECT c.channel,
               t.g,
               SIN(t.g * 12.9898) * 43758.5453
                   - FLOOR(SIN(t.g * 12.9898) * 43758.5453) AS n
        FROM UNNEST(ARRAY['CH-A', 'CH-B', 'CH-C']) AS c(channel)
        CROSS JOIN UNNEST(ARRAY[
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
        17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
        33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48,
        49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64,
        65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80,
        81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96,
        97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110,
        111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124,
        125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138,
        139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152,
        153, 154, 155, 156, 157, 158, 159, 160, 161, 162, 163, 164, 165, 166,
        167, 168, 169, 170, 171, 172, 173, 174, 175, 176, 177, 178, 179, 180,
        181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191, 192, 193, 194,
        195, 196, 197, 198, 199, 200, 201, 202, 203, 204, 205, 206, 207, 208,
        209, 210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221, 222,
        223, 224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236,
        237, 238, 239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250,
        251, 252, 253, 254, 255, 256]) AS t(g)
    ) s
) x
GROUP BY x.channel
PARTITIONED BY ALL;

SELECT "channel", ARRAY_LENGTH("levels") AS "samples"
FROM "rfs_capture"
GROUP BY "channel", "levels"
ORDER BY "channel";

-- ---------------------------------------------------------------------------
-- 2. Which frequencies dominate each channel (periodogram).  freq is
-- cycles per sample; 1/freq is samples per cycle.  CH-A is polluted by
-- its jammed second half but still shows the 1/8 beacon; CH-B has no
-- dominant line; CH-C is the 1/16 carrier.
-- ---------------------------------------------------------------------------
SELECT "channel",
       ROUND(fractal_json_value(p, '$.freqs[0]'), 4) AS "top_freq",
       ROUND(1.0 / fractal_json_value(p, '$.freqs[0]'), 1) AS "samples_per_cycle"
FROM (
    SELECT "channel", fractal_periodogram("levels") AS p
    FROM "rfs_capture"
    GROUP BY "channel", "levels"
)
ORDER BY "channel";

-- ---------------------------------------------------------------------------
-- 3. How ordered is each channel, window by window
-- (fractal_spectrogram_entropy: window 32, hop 16 -> 15 frames).
-- ---------------------------------------------------------------------------
REPLACE INTO rfs_entropy OVERWRITE ALL
SELECT "channel",
       fractal_spectrogram_entropy("levels", 32, 16) AS "ent"
FROM "rfs_capture"
GROUP BY "channel", "levels"
PARTITIONED BY ALL;

SELECT "channel",
       fractal_json_value("ent", '$.n_frames') AS "frames",
       ROUND(fractal_json_value("ent", '$.min_entropy'), 3) AS "min_entropy",
       ROUND(fractal_json_value("ent", '$.max_entropy'), 3) AS "max_entropy",
       ROUND(fractal_json_value("ent", '$.mean_entropy'), 3) AS "mean_entropy"
FROM "rfs_entropy"
GROUP BY "channel", "ent"
ORDER BY "channel";

-- ---------------------------------------------------------------------------
-- 4. When did CH-A lose its structure?  fractal_change_point_detect on
-- the entropy series (window 3 frames, threshold 8.0 pooled-stddev
-- units).  The jam begins at sample 161; frame 9 (samples 144-175) is
-- the first to contain it, and that is the boundary reported.  A clean
-- channel's entropy series is nearly constant, so its pooled standard
-- deviation is tiny and a low threshold would flag measurement jitter --
-- keep the threshold high for entropy series.
-- ---------------------------------------------------------------------------
SELECT "channel",
       fractal_change_point_detect(fractal_json_text("ent", '$.frames'), 3, 8.0) AS "change_points"
FROM "rfs_entropy"
GROUP BY "channel", "ent"
ORDER BY "channel";

-- ---------------------------------------------------------------------------
-- 5. Reasoning: the interference triage narrative (plugin-gated; the
-- clean hint is the expected output without one).
-- ---------------------------------------------------------------------------
SELECT fractal_reason(
    'one-line RF interference triage: which channel lost its structure, when, and the likely cause',
    CONCAT(
        'ch_a_entropy=',
        (SELECT "ent" FROM "rfs_entropy" WHERE "channel" = 'CH-A'),
        ' ch_a_change_points=',
        (SELECT fractal_change_point_detect(fractal_json_text("ent", '$.frames'), 3, 8.0)
         FROM "rfs_entropy" WHERE "channel" = 'CH-A'),
        ' ch_b_mean_entropy=',
        (SELECT fractal_json_value("ent", '$.mean_entropy')
         FROM "rfs_entropy" WHERE "channel" = 'CH-B'))) AS "narrative";

-- ---------------------------------------------------------------------------
-- 6. The kit's own headline check.
--
-- The demo contract: a kit prints its headline and exits
-- non-zero unless the result holds.  CH-A is jammed, so its spectral
-- entropy rises; CH-B is noise throughout and stays high.  The claim
-- is that CH-A's MAXIMUM frame entropy exceeds its MINIMUM -- the jam
-- made it less ordered -- while CH-B, which never changes, does not
-- move much.
-- ---------------------------------------------------------------------------
SELECT CASE
           WHEN (SELECT fractal_json_value("ent", '$.max_entropy') FROM "rfs_entropy" WHERE "channel" = 'CH-A')
                > (SELECT fractal_json_value("ent", '$.min_entropy') FROM "rfs_entropy" WHERE "channel" = 'CH-A')
            AND (SELECT fractal_json_value("ent", '$.max_entropy') FROM "rfs_entropy" WHERE "channel" = 'CH-A')
                > (SELECT fractal_json_value("ent", '$.mean_entropy') FROM "rfs_entropy" WHERE "channel" = 'CH-B')
           THEN 'HEADLINE kit=rf-spectrum-sensing ok'
           ELSE 'HEADLINE kit=rf-spectrum-sensing FAILED'
       END AS "headline";
