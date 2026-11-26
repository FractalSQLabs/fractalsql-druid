/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
/**
 * The extension against the function registry.
 *
 * <p>{@code service/protocol/functions.def} is the single source of truth
 * for the callable surface. This extension's registry must agree with it
 * -- on the names, and on the result kinds.
 *
 * <p>The file is found by walking up from the working directory; the test
 * skips when it cannot be found rather than failing. It is run with
 * {@code -Dfsql.functions.def=<path>} to point at a specific copy.
 */
public class FunctionRegistryTest {
    /** The registry row: X(sql, kind, cls). */
    private static final Pattern ROW =
            Pattern.compile("^X\\(([a-z0-9_]+),\\s*(STR|INT|REAL),\\s*([rse])\\)\\s*$");
    /** The ported functions, minus the ones this extension registers elsewhere. */
    private static final List<String> REGISTERED_ELSEWHERE =
            List.of("fractal_search_distance");
    /**
     * The 'r' (pure) functions in the function registry that this extension does
     * not expose on the SQL surface, and why.
     *
     * <p>Each entry is a decision, not an omission: either the function
     * belongs to a tier that has a different shape on Druid (the ledger,
     * the session overlay, cognition), or it needs a mechanism Druid does
     * not have in the SQL layer.
     */
    private static final Map<String, String> NOT_PORTED = new LinkedHashMap<>();
    static {
        NOT_PORTED.put("fractal_version", "node-level, not a per-row value");
        NOT_PORTED.put("fractal_edition", "node-level, not a per-row value");
        NOT_PORTED.put("fractal_optimize_subset", "needs a caller-supplied objective, which the core takes as a callback");
        // The multimodal portfolio family IS ported. Its core symbols
        // live in the separately licensed enterprise library, so the
        // functions are registered on every build and report that the
        // tier is not loaded when the library is absent -- the same
        // dormant-on-community shape the ledger has.
        NOT_PORTED.put("fractal_vector_from_float8_array", "the Postgres float8-array convention; Druid's native vector is an ARRAY column");
        NOT_PORTED.put("fractal_vector_to_float8_array", "the Postgres float8-array convention; Druid's native vector is an ARRAY column");
        NOT_PORTED.put("fractal_t2s_config", "cognition tier");
        NOT_PORTED.put("fractal_t2s_check_allowlist", "cognition tier");


        NOT_PORTED.put("fractal_config_reset", "the session tier's reset; the extension keeps the overlay, "
                + "but a reset has no place in a query's expression layer");
        NOT_PORTED.put("fractal_sfs_converge", "the table-free convergence function is exposed through its "
                + "tunable debug form (fractal_sfs_converge_debug); the plain form is the daemon's");
    }
    /** The kind column, mapped onto the extension's return types. */
    private static FractalFn.RetType retTypeOf(String kind)
    {
        switch (kind) {
            case "STR":
                return FractalFn.RetType.STRING;
            case "INT":
                return FractalFn.RetType.BIGINT;
            default:
                return FractalFn.RetType.DOUBLE;
        }
    }
    /**
     * Functions this extension adds beyond the function registry.
     *
     * <p>A superset is allowed, but it is a decision that has to be
     * recorded, not an accident.
     */
    private static final Map<String, String> DRUID_ADDITIONS = new LinkedHashMap<>();
    static {
        DRUID_ADDITIONS.put("fractal_optimize_portfolio_ex",
                "the OBL / Levy-flight knobs the core exposes; the registry folds them into "
                        + "fractal_optimize_portfolio's seed argument");
        DRUID_ADDITIONS.put("fractal_state_distance",
                "the Hamming distance between two state fingerprints, which is what "
                        + "fractal_agent_detect_loop needs and which the "
                        + "registry has no equivalent for");
        DRUID_ADDITIONS.put("fractal_json_value",
                "Druid's JSON_VALUE reads a COMPLEX column, not a JSON string, so the extension "
                        + "needs its own accessor for the documents its functions return");
        DRUID_ADDITIONS.put("fractal_json_text",
                "the same accessor, for the string-valued fields");
        DRUID_ADDITIONS.put("fractal_search_distance",
                "the aggregate that used to carry the name fractal_search: the fleet's indexed "
                        + "search took the name on 2026-11-18, and a Calcite operator cannot carry "
                        + "two operators with one name");
        for (String featureFunction : new String[]{"fractal_store_morphology", "fractal_mine_topology_negatives"}) {
            DRUID_ADDITIONS.put(featureFunction,
                    "the named feature store: its vectors live in a datasource (fractalsql_feature_store) that "
                            + "an MSQ INSERT writes and a query reads, which the daemon's registry cannot do, so "
                            + "the SQL names live in the extension, like the index's management functions");
        }
        for (String indexFunction : new String[]{"fractal_index_create", "fractal_index_rebuild",
                "fractal_index_drop", "fractal_index_info", "fractal_index_candidates"}) {
            DRUID_ADDITIONS.put(indexFunction,
                    "the index's management functions: on Druid they are SERVICE operations (they read a "
                            + "datasource and, for a build, write one, which a Druid SQL function cannot "
                            + "do), so the SQL names live in the extension and the daemon's registry "
                            + "carries only the plumbing function fractal_index_op");
        }
    }
    /** Find the function registry, or null. */
    private static Path findRegistry()
    {
        final String override = System.getProperty("fsql.functions.def");
        if (override != null) {
            final Path p = Paths.get(override);
            return Files.isRegularFile(p) ? p : null;
        }
        // Walk up from the working directory looking for the registry.
        Path dir = Paths.get("").toAbsolutePath();
        for (int i = 0; i < 4 && dir != null; i++) {
            final Path candidate = dir.resolve("service").resolve("protocol").resolve("functions.def");
            if (Files.isRegularFile(candidate)) {
                return candidate;
            }
            dir = dir.getParent();
        }
        return null;
    }
    /** The registry rows: sql name -> {kind, cls}. */
    private static Map<String, String[]> readRegistry(Path file) throws Exception
    {
        final Map<String, String[]> rows = new LinkedHashMap<>();
        for (String line : Files.readAllLines(file, StandardCharsets.UTF_8)) {
            final Matcher m = ROW.matcher(line.trim());
            if (m.matches()) {
                rows.put(m.group(1), new String[]{m.group(2), m.group(3)});
            }
        }
        return rows;
    }
    @Test
    public void theExtensionAgreesWithTheFunctionRegistry() throws Exception
    {
        final Path file = findRegistry();
        Assumptions.assumeTrue(file != null, "the function registry is not available; skipping");
        final Map<String, String[]> registry = readRegistry(file);
        assertTrue(registry.size() > 50, "the function registry looks wrong: " + registry.size() + " rows");
        final List<String> problems = new ArrayList<>();
        // 1. Every ported function must exist in the function registry, with
        //    the same result kind. A function the registry does not know
        //    about is allowed (the extension can be a superset), but it is
        //    worth seeing.
        for (FractalFn.Spec spec : FractalFn.all()) {
            final String sql = spec.sqlName().toLowerCase(java.util.Locale.ROOT);
            final String[] row = registry.get(sql);
            if (row == null) {
                if (!DRUID_ADDITIONS.containsKey(sql)) {
                    problems.add(sql + " is not in the function registry and is not a "
                            + "recorded Druid addition");
                }
                continue;
            }
            final FractalFn.RetType expected = retTypeOf(row[0]);
            if (expected != spec.retType()) {
                problems.add(sql + ": the registry says " + row[0] + " (" + expected
                        + "), the extension says " + spec.retType());
            }
        }
        // 2. Every 'r' (pure) function in the function registry must either be
        //    ported -- under its own name or a documented rename -- or be
        //    on the not-ported list. A pure function that is neither is
        //    an omission, not a decision.
        for (Map.Entry<String, String[]> entry : registry.entrySet()) {
            final String sql = entry.getKey();
            final String cls = entry.getValue()[1];
            if (!"r".equals(cls)) {
                continue;
            }
            if (REGISTERED_ELSEWHERE.contains(sql)) {
                continue;
            }
            final boolean isPorted =
                    FractalFn.findByName(sql.toUpperCase(java.util.Locale.ROOT)) != null;
            if (!isPorted && !NOT_PORTED.containsKey(sql)) {
                problems.add(sql + " is a pure ('r') registry function that is neither ported "
                        + "nor on the not-ported list");
            }
        }
        // 3. Every name on the not-ported list must still exist in the
        //    function registry, or the list is stale.
        for (String sql : NOT_PORTED.keySet()) {
            if (!registry.containsKey(sql)) {
                problems.add(sql + " is on the not-ported list but is not in the function registry");
            }
        }
        // 4. Every recorded Druid addition must really be absent from the
        //    function registry, or the record is stale.
        for (String sql : DRUID_ADDITIONS.keySet()) {
            if (registry.containsKey(sql)) {
                problems.add(sql + " is recorded as a Druid addition but is in the function registry");
            }
        }
        assertTrue(problems.isEmpty(), "the extension and the function registry disagree:\n  "
                + String.join("\n  ", problems));
    }
}
