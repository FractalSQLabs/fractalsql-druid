<p align="center">
  <img src="../FractalSQLforDruid.jpg" alt="FractalSQL for Apache Druid" width="720">
</p>

# Analytics API Reference

The Analytics tier provides mathematical primitives for analyzing the "shape" of data and state, turning raw vectors into structural insights.

> **Array convention.** A series or vector argument is a Druid `ARRAY` column of
> numbers or its text form: a CSV string (`'0.6,0.8,0.0,0.0'`) or a bracketed
> JSON array (`'[0.6,0.8,0.0,0.0]'`). Druid has no BLOB type. A function that
> returns a document returns it as TEXT (JSON); use `fractal_json_value()` /
> `fractal_json_text()` on it. These are plain scalar functions registered by the
> extension when Druid loads it: no separate install or activation step.

---

## Fractal Dimension Analysis

### `fractal_dimension_dfa`
**Detrended Fluctuation Analysis**
Calculates the scaling exponent ($\alpha$) of a time-ordered series to distinguish between white noise, pink noise, and Brownian motion.

**Signature**: `fractal_dimension_dfa(series) RETURNS REAL` — `series` is an `ARRAY` or a CSV/JSON TEXT array.
**Requirement**: $\ge 16$ points. The DFA, drift and change-point functions accept at most 134,217,728 samples.


#### Using the DFA exponent as a Hurst exponent

There is deliberately no separate Hurst function: the DFA exponent *is* the Hurst exponent for noise-like input.

- For a series of **increments** (returns, differences): $H = \alpha$. $\alpha < 0.5$ is mean-reverting (anti-persistent), $\alpha \approx 0.5$ a random walk, $\alpha > 0.5$ trending (persistent).
- For a series of **levels** (prices, a cumulative sum): $H = \alpha - 1$.

On synthetic fractional Gaussian noise with known $H$ from 0.3 to 0.9, DFA had an overall RMSE of 0.036 at $n = 1024$ (0.068 at $n = 256$), against 0.070 (0.094 at $n = 256$) for classic and bias-corrected rescaled-range (R/S) estimators. On random-walk returns with heavy tails or volatility clustering, DFA called 0-2% of series trending or mean-reverting at a $\pm 0.1$ band, against 7-11% for raw R/S. (Synthetic tests, not market data.)

Caveats:

- **Sampling noise.** The estimate has a standard deviation of about 0.03 at $n = 1024$ and 0.05-0.07 at $n = 256$. Do not classify a regime from one value near 0.5 on a short series.
- **Short-memory autocorrelation inflates $\alpha$.** DFA's smallest box is 4 samples, so a series with only lag-1 momentum (AR(1), $\varphi = 0.3$) reads about 0.61 although its long-run $H$ is 0.5. In testing, raising the smallest box to 32 brought that to 0.52 while genuinely persistent (0.7) and anti-persistent (0.3) series stayed put, at the price of a larger standard deviation. This function does not expose the box size yet.

### `fractal_dimension_boxcount`
**Minkowski-Bouligand Dimension**
Measures the spatial complexity of a point cloud using box-counting.

**Signature**: `fractal_dimension_boxcount(points, dim) RETURNS REAL`
**Requirement**: $\ge 8$ points with finite coordinates, a non-degenerate bounding box, and (number of points) × `dim` ≤ 4,194,304. The point count in the first sentence is necessary, not sufficient: in testing on uniform-random points, 2-D sets of 64 and 100 points were always refused, 200 points were refused about one time in ten, and 500 always succeeded; 3-D sets of 500 points were always refused and 2,000 always succeeded.

### `fractal_dimension_drift`
**Regime Change Detection**
Detects changes in the DFA exponent between a recent window and the baseline.

**Signature**: `fractal_dimension_drift(series, win) RETURNS TEXT (JSON)`
**Return**: `{"drift":..,"recent_alpha":..,"baseline_alpha":..}` as a JSON document. `drift` is a **signed** number — `recent_alpha - baseline_alpha` — so positive means the recent window is more complex/irregular than the baseline and negative means it is approaching a more ordered state. The window and series-length minimums are listed under [Known limits](druid-integration.md#5-known-limits).

**Requirement**: `win` of at least 24 samples, and a series of at least `2 * win` samples. Anything smaller returns `{"drift":null,...}`.

---

## Time-Series and Topology

### `fractal_change_point_detect`
**Change-Point Localization**
DFA's complement: localizes *where* a series' mean and/or variance shifted, instead of only characterizing its overall scaling behavior.

**Signature**: `fractal_change_point_detect(series, window, threshold [, max_points]) RETURNS TEXT (JSON)` — `series` is an `ARRAY` or a CSV/JSON TEXT array; `threshold` defaults to 2.0 pooled-standard-deviation units and `max_points` to 16 (the function is registered at arities 3 and 4, omitted trailing arguments take the documented defaults).
**Return**: `{"indices":[..]}` — ascending boundary indices, up to `max_points`.
Sliding two-sample test over adjacent windows of `window` samples; flags a boundary when the mean differs by more than `threshold` pooled-standard-deviation units or the variance ratio exceeds `threshold` squared. Requires at least `2 * window` points.

### `fractal_chunk_text` (REST)
**Split long text into chunks (pure, no model)**

`POST /fractalsql/chunk` with `{"text": ..., "chunk_size": n, "chunk_overlap": n, "chunk_mode": "paragraph"|"sentence"|"fixed"}` returns `{"chunks": [{"no","start","end","text"}]}`. Druid SQL has no function that can return a list of rows, so the splitter is an endpoint on this host; the chunks it returns are the ones every FractalSQL host returns.

`start` and `end` are character offsets into the original text (`end` is exclusive), and `text` is that slice. Characters are UTF-8 code points, not bytes. `chunk_size` is 1 to 100000 (default 800), `chunk_overlap` is 0 to `chunk_size - 1` (default 0), and at most 100000 chunks are produced. An empty or blank text gives an empty list.

| `chunk_mode` | How the text is cut |
| --- | --- |
| `paragraph` (the default) | At paragraph breaks (a run of blanks that contains at least two line feeds). Whole paragraphs are packed into a chunk while it stays within `chunk_size`. |
| `sentence` | After a run of `.`, `!` or `?` that is followed by whitespace or the end. Whole sentences are packed the same way; a paragraph break also ends a sentence. |
| `fixed` | Every `chunk_size - chunk_overlap` characters, ignoring the text's structure. |

A paragraph or sentence longer than `chunk_size` is cut like a fixed span, and neighbouring pieces share `chunk_overlap` characters. The size is in characters, not tokens: pick it a little under your embedding model's limit. A Druid datasource is append-only, so the vectorizer here does not keep a chunk datasource in step with its source: ingest the chunks you get back as rows of their own datasource.

### `fractal_periodogram`
**Classical Periodogram**
Power at each positive Fourier frequency. Short series use a direct DFT; longer ones use an FFT (radix-2, or Bluestein's algorithm for other lengths), which agrees with the direct sum to floating-point rounding.

**Signature**: `fractal_periodogram(series [, max_peaks]) RETURNS TEXT (JSON)` — `max_peaks` defaults to 8 (arity 1 or 2).

The series may have at most 1,048,576 samples; a longer one is refused.
**Return**: `{"freqs":[..],"power":[..]}` — only the `max_peaks` bins with highest power, sorted descending. Each `freqs` entry is cycles per sample in $(0, 0.5]$; `1.0/freq` is samples per cycle. Useful for network-beaconing and retry-loop cadence detection that DFA alone is blind to. Requires at least 4 points.

### `fractal_spectrogram_entropy`
**Short-Time Spectral Entropy**
`fractal_periodogram` says which frequencies dominate a whole series; this says *how ordered* the frequency content is, window by window, and so *when* it changes. A window slides over the series; each frame has its mean removed, is tapered with a periodic Hann window, and is transformed by a direct DFT. The Shannon entropy of the frame's normalized power spectrum is divided by $\ln(\text{window}/2)$, so every value lies in $[0, 1]$.

**Signature**: `fractal_spectrogram_entropy(series [, window [, hop [, max_frames]]]) RETURNS TEXT (JSON)` — `series` is an `ARRAY` or a CSV/JSON TEXT array; `window` defaults to 64, `hop` to 32 and `max_frames` to 4096 (registered at arities 1 to 4). A NULL series returns NULL.
**Return**: a bare JSON array with one entropy value per frame, e.g. `[0.2503,0.2505,...]`. It is a bare array, not an object, so it pipes straight into `fractal_change_point_detect` or `fractal_dimension_dfa`. Frame `f` covers `series[f*hop .. f*hop + window - 1]` (0-based); there are `floor((n - window)/hop) + 1` frames and the first `max_frames` are returned.

| Value | Meaning |
|---|---|
| near 0 | energy concentrated in a few frequencies: a beacon, a retry loop, a locked carrier |
| near 1 | energy spread across the band: noise-like, jammed, or a signal that has lost its structure |

Calibration: a pure tone reads about 0.2 to 0.3 (the Hann taper spreads it over a few bins), white noise about 0.9, not 1.0 (a noise periodogram is itself randomly distributed). A constant frame has no spectral energy and reports exactly `0.0`, never NaN.

Limits: `window` in $[8, 512]$, `hop >= 1`, `max_frames` in $[1, 4096]$, `n >= window`, all samples finite; anything else is a clean SQL error. Cost is $O(\text{frames} \times \text{window}^2 / 2)$.

```sql
-- where does a signal's spectral order change? boundary indices are FRAME indices
SELECT fractal_change_point_detect(
         fractal_spectrogram_entropy(samples, 64, 32), 4, 2.0, 8)
  FROM rf_capture WHERE capture_id = 7;
```

### `fractal_tda_persistence_diagram`
**Topological Persistence**
Topological analysis over a point cloud's Vietoris-Rips filtration, capped at 512 points.

**Signature**: `fractal_tda_persistence_diagram(points, dim, max_dim, max_thresh [, max_h0_bars]) RETURNS TEXT (JSON)` — `points` is a flat `ARRAY` or CSV/JSON TEXT array, `dim` points per row (`points` length must divide evenly); `max_dim` is 0 (birth/death bars only) or 1 (also computes `betti1`); `max_h0_bars` defaults to 64 (arity 4 or 5).
**Return**: `{"n_h0_bars":N,"h0_bars":[{"birth":..,"death":..},...],"betti1":N|null}`. `h0_bars` is an exact 0-dimensional persistence computation (single-linkage clustering), sorted by death ascending. `betti1` (only computed when `max_dim = 1`) is the underlying graph's cycle rank, **not** full simplicial $H_1$: it over-counts true $H_1$ whenever a filled triangle exists in the data. A full simplicial computation (what Ripser/GUDHI do via boundary-matrix reduction) is out of scope.

### `fractal_state_fingerprint`
**SimHash State Fingerprint**
Random-hyperplane SimHash (Charikar 2002): projects a state vector onto `n_bits` random hyperplanes (deterministic from `seed`) and packs the sign of each projection MSB-first into bytes.

**Signature**: `fractal_state_fingerprint(vec, n_bits [, seed]) RETURNS TEXT (hex)` — `vec` is an `ARRAY` or a CSV/JSON TEXT array; `seed` defaults to 0.0 (arity 2 or 3). Returns the fingerprint as `(n_bits + 7) / 8` bytes, hex-encoded. The sign of each projection is packed MSB-first. The seed selects the random hyperplanes: a different seed means a different (and therefore not comparable) fingerprint.

`n_bits` must be between 1 and 33,554,424 (a 4 MiB fingerprint), and `n_bits` times the vector length must not exceed 268,435,456 (about a second of work); a larger value is an error.

Two nearly-identical states collapse to the same or a very low Hamming-distance fingerprint, unlike an exact hash's all-or-nothing sensitivity to floating-point noise.

### `fractal_cycle_detect`
**Streaming Cycle Detection**
Brent's algorithm (1980) run over a stream of `fractal_state_fingerprint` outputs, fed through one detector in order.

**Signature**: `fractal_cycle_detect(fingerprints_json, n_bits [, hamming_threshold]) RETURNS TEXT (JSON)` — `fingerprints_json` is a JSON array of hex-encoded fingerprints, each `(n_bits + 7) / 8` bytes decoded (build it with `CONCAT('["', ARRAY_TO_STRING(ARRAY_AGG("fingerprint", 16384), '","'), '"]')`); `hamming_threshold` defaults to 0 (arity 2 or 3).
**Return**: `{"detected":true,"cycle_len":N,"at_index":I}` (or `{"detected":false}`). `at_index` is the position in the stream where the cycle closed, `cycle_len` its length. Every fingerprint must decode to the same `n_bytes` (the `n_bits` argument sets it). The underlying detector re-arms after a closure, but this single-call convenience stops at the **first** cycle found — a caller watching for a second, independent cycle later in a longer stream re-invokes it on the later segment of the stream.

These two pair into tolerant "have I basically been in this state before" loop detection; the shipped agent engines compose them with a DFA drift check (see [api-agency.md](api-agency.md)).

---

## Vector Math and Quantization

Utilities over vectors (see [vectorizer-setup.md](vectorizer-setup.md)). They accept a vector as an `ARRAY` or as CSV/JSON TEXT.

Every distance in this section is computed by the one shared double-precision implementation, so the values agree to the last bit with the other SQL-visible distances and with every other FractalSQL host -- see the precision contract in [api-discovery.md](api-discovery.md).

### `fractal_vector_lp_distance`
**Generalized $L_p$ Distance**

**Signature**: `fractal_vector_lp_distance(a, b, p) RETURNS REAL`
$(\sum_i |a_i - b_i|^p)^{1/p}$ for $p > 0$. `p = 2` matches `fractal_vector_l2_distance` mathematically but not bit-for-bit (different code path). For $0 < p < 1$ this is **not** a proper metric (the triangle inequality does not hold), so never substitute it silently for the L2 primitives as a default distance; use it explicitly where fractional-$p$ contrast at high dimensionality is wanted, such as high-dimensional genomic or embedding similarity.

### `fractal_vector_quantize_int8` / `fractal_vector_quantize_binary`
**Per-Vector Quantization**

- `fractal_vector_quantize_int8(v) RETURNS TEXT (JSON)` → `{"scale":S,"codes":[..]}`: symmetric int8 quantization, 4x compression. `codes` is one signed integer per dimension, `scale` lets the caller dequantize `v[i] ≈ codes[i] * scale`.
- `fractal_vector_quantize_binary(v) RETURNS TEXT`: 1-bit quantization: the sign bits as a text array of `0`/`1` values (bit $i$ is 1 if `v[i] >= 0`), padded with zeros to a multiple of 8 entries (a 10-dimension vector gives 16). Pairs with `fractal_vector_hamming_distance` for cheap candidate filtering ahead of a full-precision L2/cosine re-rank.

---

## Domain-Specific Geometry

These functions take **pre-extracted geometry** (graphs, meshes, skeletons) as input.

| Function | Input | Output | Description |
| --- | --- | --- | --- |
| `fractal_vascular_network` | `node_coords`, `edges`, `arc_length` | `{mean_tortuosity, branch_density, fractal_dimension}` | Vessel network complexity. |
| `fractal_cortical_folding` | `vertices`, `faces` | `{mesh_area, hull_area, gyrification_index}` | Brain surface folding. |
| `fractal_nerve_plexus_metric` | `node_coords`, `dim`, `edges` | `{fiber_length_density, branch_density, fractal_dimension}` | Nerve fiber density. |
| `fractal_morphological_complexity` | `points`, `dim` | `{dimension, lacunarity}` | Pre-segmented mask complexity. |

The point-cloud functions (`fractal_dimension_boxcount`, `fractal_morphological_complexity`) refuse any non-finite coordinate, and refuse a cloud whose number of points times `dim` exceeds 4,194,304 (about 1,400,000 three-dimensional points). `fractal_cortical_folding` takes at most 4,194,304 vertices, and refuses vertices so nearly coplanar that the convex hull cannot be built. Each refusal is an error, not a wrong answer.

---

## Portfolio Optimization

### `fractal_optimize_portfolio`
**Cardinality-Constrained Sharpe-Ratio Maximization**

Finds the best $K$ assets in a large universe without brute-force exponential cost.

**Signature**: `fractal_optimize_portfolio(mu, cov, k [, seed [, use_obl [, diffusion_mode]]]) RETURNS TEXT (JSON)` — `mu`/`cov` are flat `ARRAY` or CSV/JSON TEXT arrays (`cov` flattened row-major); omitted trailing arguments take their defaults (the function is registered at several arities).
**Limit**: restarts times the square of the asset count is bounded at 2^27 (a single run counts as one restart), so one run takes up to about 11,000 assets and a 64-restart multimodal run about 1,400. A larger request is refused before any work is done.
**Return**: `{"sharpe":..,"weights":[..]}`.
**`use_obl`**: apply Opposition-Based Learning to each SFS trial candidate. Also evaluate its bound-reflected opposite and keep whichever fits better. Off by default; doubles the fitness-eval cost of the affected diffusion step when enabled.
**`diffusion_mode`**: `'gaussian'` (default, canonical SFS) or `'levy'`: substitutes a heavy-tailed Lévy-flight step (Mantegna's algorithm) for the Gaussian walk, which can help escape local optima on highly multimodal problems at the cost of occasional very large steps.

### `fractal_optimize_subset`
**Value-weighted k-subset allocation.** Picks at most `k` items from a scored list and weights them to maximise the total value, with a cap on each item's weight: the general form of `fractal_optimize_portfolio`, for budgets, slots and nodes.

**Signature**: `fractal_optimize_subset(item_values, upper_bounds, k [, prev_weights [, turnover_penalty [, seed]]]) RETURNS TEXT (JSON)`; the vectors are arrays or JSON text. At most 255 items. Every `upper_bounds[i]` must be in `[0, 1]` and the `k` largest must add up to at least 1.

`prev_weights` and `turnover_penalty` steer the search away from reallocating (rebalancing). **Return**: `{"score":..,"weights":[..]}`, `score` being the value-weighted total achieved.

### `fractal_optimize_portfolio_multimodal`
**Enterprise tier.** Diverse-candidate variant of `fractal_optimize_portfolio`: runs `n_restarts` independent single-best searches and greedy-selects up to `n_restarts` structurally distinct candidates instead of one.

**Signature**: `fractal_optimize_portfolio_multimodal(mu, cov, k [, n_restarts [, overlap_threshold [, quality_frac [, seed [, use_obl [, diffusion_mode]]]]]]) RETURNS TEXT (JSON)`
**Return**: `{"candidates": [{"sharpe":..,"weights":[..]}, ...], "n_found":N}`.
**`overlap_threshold`**: max allowed selected-asset overlap (0.0–1.0, Jaccard-style) between any two returned candidates.
**`quality_frac`**: a candidate must reach at least `quality_frac` × the best Sharpe found to be kept.
**`use_obl`/`diffusion_mode`**: same knobs as `fractal_optimize_portfolio`, applied uniformly to every restart. Requires an enterprise core build with OBL/Lévy-flight support: errors with a clear "predates support" hint against an older `enterprise_lib` if you pass non-default values (the plain symbol still serves default-args calls against an older core).

### `fractal_optimize_portfolio_multimodal_pareto`
**Enterprise tier.** Pareto-front sibling of `fractal_optimize_portfolio_multimodal`: runs the same `n_restarts` independent searches, but scores each by decomposed **(return, risk)** instead of scalar Sharpe and reduces them to a genuine non-dominated Pareto front (NSGA-II crowding-distance truncation if the front exceeds `max_front`). This is not the sharpe-threshold + asset-overlap selection the sibling above uses. Purely additive: does not change that function's selection semantics.

**Signature**: `fractal_optimize_portfolio_multimodal_pareto(mu, cov, k [, n_restarts [, max_front [, seed [, use_obl [, diffusion_mode]]]]]) RETURNS TEXT (JSON)`
**Return**: `{"candidates": [{"return":..,"risk":..,"sharpe":..,"weights":[..]}, ...], "n_found":N}`: `sharpe = return/risk` is informational, not the selection criterion.
**`max_front`**: cap on returned front size, `1 <= max_front <= n_restarts`.

## Named Feature Store

A generic per-item vector store for custom metadata or flagged examples. The vectors live in the `fractalsql_feature_store` datasource, which the first write creates.

### `fractal_store_morphology`
Upserts a vector against a `doc_id`: it appends a row with an MSQ write, and the newest row of a `doc_id` is its vector.
**Signature**: `fractal_store_morphology(doc_id, feature_array) RETURNS TEXT ('ok')`
`feature_array` is a JSON array or a comma-separated list of numbers. A negative `doc_id` is refused. The write waits for its MSQ task, so it takes a few seconds.

### `fractal_mine_topology_negatives`
Brute-force k-NN over the stored vectors, by true Euclidean distance, nearest first.
**Signature**: `fractal_mine_topology_negatives(surrogate_vector, k) RETURNS TEXT (JSON)`
**Return**: `[{"doc_id":..,"distance":..}, ...]`. A stored vector of another dimension is skipped, and a datasource that has no rows yet gives `[]`. `k` must be positive.
