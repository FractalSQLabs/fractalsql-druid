/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
package com.fractalsqlabs.fractalsql.druid;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The registry of {@code fractal_*} functions.
 *
 * <p>This is the single source of truth for the function surface. It fixes,
 * for every function: its SQL name, the shape of its arguments, where each
 * argument lands in the native call, and what it returns. The Calcite
 * binding, the native expression macro and the JNI dispatcher are all
 * generated from (or checked against) this table, so they cannot drift.
 *
 * <p>The function ids are the {@code FN_*} constants shared with
 * {@code fractalsql_jni.c}: the dispatcher switches on them, so a mismatch
 * reads the wrong core function. {@link #idsMatchTheNativeTable()} checks
 * that at startup and in the unit tests.
 */
public final class FractalFn {

    /** The kind of an argument. */
    public enum ArgType {
        /** A vector: a Druid ARRAY column, or the result of a vector function. */
        ARRAY,
        /** A number: a Druid numeric column or a literal. */
        NUMBER,
        /** A string. */
        STRING
    }

    /** The kind of a result. */
    public enum RetType {
        /** A single number. */
        DOUBLE,
        /** A whole number. */
        BIGINT,
        /** A JSON document, as text. */
        STRING
    }

    // Slots in the native call. The dispatcher takes three arrays and three
    // scalars, which is the widest shape any function needs.
    public static final int SLOT_A = 0;
    public static final int SLOT_B = 1;
    public static final int SLOT_C = 2;
    public static final int SLOT_P1 = 3;
    public static final int SLOT_P2 = 4;
    public static final int SLOT_P3 = 5;

    /** How many doubles the native call may write back. */
    public static final int OUT_SIZE = 256;

    /**
     * One function.
     *
     * <p>{@code argSlots} says where each argument goes: an {@code SLOT_*}
     * constant per argument, in argument order.
     */
    public static final class Spec {
        private final int id;
        private final String sqlName;
        private final String nativeName;
        private final ArgType[] argTypes;
        private final int[] argSlots;
        private final RetType retType;
        private final boolean vectorResult;
        private final boolean javaOnly;

        Spec(
                int id,
                String sqlName,
                ArgType[] argTypes,
                int[] argSlots,
                RetType retType,
                boolean vectorResult,
                boolean javaOnly)
        {
            this.id = id;
            this.sqlName = sqlName;
            this.nativeName = sqlName.toLowerCase(java.util.Locale.ROOT);
            this.argTypes = argTypes;
            this.argSlots = argSlots;
            this.retType = retType;
            this.vectorResult = vectorResult;
            this.javaOnly = javaOnly;
        }

        /** The native function id -- a {@code FN_*} constant. */
        public int id()
        {
            return id;
        }

        /** The SQL name, e.g. {@code FRACTAL_DIMENSION_DFA}. */
        public String sqlName()
        {
            return sqlName;
        }

        /** The native expression name, e.g. {@code fractal_dimension_dfa}. */
        public String nativeName()
        {
            return nativeName;
        }

        /** The kinds of the arguments, in order. */
        public ArgType[] argTypes()
        {
            return argTypes.clone();
        }

        /** Where each argument goes in the native call. */
        public int[] argSlots()
        {
            return argSlots.clone();
        }

        /** What the function returns. */
        public RetType retType()
        {
            return retType;
        }

        /**
         * Whether the core call produces a vector.
         *
         * <p>Such a function's result is carried as the core's JSON text
         * form -- the core's convention, and the
         * one that survives Druid's expression layer intact (an ARRAY
         * coming out of a native expression does not).
         */
        public boolean isVectorResult()
        {
            return vectorResult;
        }

        /**
         * Whether the function is evaluated in Java rather than through
         * the JNI dispatcher.
         *
         * <p>A handful of functions are pure Java -- they build or
         * format a vector and never call the core. A few more are
         * handled in Java because they need their own native entry
         * point rather than the generic one: the ledger and audit
         * functions and the multimodal portfolio family, whose
         * candidates list does not fit the dispatcher's scalar
         * result. Every other function has a case in the JNI
         * dispatcher, and the unit tests check that.
         */
        public boolean isJavaOnly()
        {
            return javaOnly;
        }

        /** How many arguments the function takes. */
        public int arity()
        {
            return argTypes.length;
        }

        /** Whether the argument at {@code i} is a vector. */
        public boolean isArrayArg(int i)
        {
            return argTypes[i] == ArgType.ARRAY;
        }

        @Override
        public String toString()
        {
            return sqlName;
        }
    }

    private static final Map<String, Spec> BY_NAME = new LinkedHashMap<>();
    private static final Map<Integer, Spec> BY_ID = new LinkedHashMap<>();

    private FractalFn()
    {
    }

    private static Spec add(int id, String sqlName, RetType ret, ArgType[] types, int[] slots)
    {
        return add(id, sqlName, ret, types, slots, false, false);
    }

    private static Spec add(
            int id,
            String sqlName,
            RetType ret,
            ArgType[] types,
            int[] slots,
            boolean vectorResult,
            boolean javaOnly)
    {
        if (types.length != slots.length) {
            throw new IllegalArgumentException(sqlName + ": argument and slot counts differ");
        }
        final Spec spec = new Spec(id, sqlName, types, slots, ret, vectorResult, javaOnly);
        BY_NAME.put(sqlName, spec);
        BY_ID.put(id, spec);
        return spec;
    }

    static {
        // ---- analytics ------------------------------------------------
        add(1, "FRACTAL_DIMENSION_DFA",
                RetType.DOUBLE,
                new ArgType[]{ArgType.ARRAY},
                new int[]{SLOT_A});
        add(2, "FRACTAL_DIMENSION_DRIFT",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_P1});
        add(3, "FRACTAL_DIMENSION_BOXCOUNT",
                RetType.DOUBLE,
                new ArgType[]{ArgType.ARRAY, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_P1});
        add(4, "FRACTAL_CHANGE_POINT_DETECT",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY, ArgType.NUMBER, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_P1, SLOT_P2});
        add(5, "FRACTAL_PERIODOGRAM",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY},
                new int[]{SLOT_A});
        add(6, "FRACTAL_SPECTROGRAM_ENTROPY",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY, ArgType.NUMBER, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_P1, SLOT_P2});
        add(7, "FRACTAL_MORPHOLOGICAL_COMPLEXITY",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_P1});
        add(8, "FRACTAL_OPTIMIZE_PORTFOLIO",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY, ArgType.ARRAY, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_B, SLOT_P1});
        add(9, "FRACTAL_TDA_PERSISTENCE_DIAGRAM",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY, ArgType.NUMBER, ArgType.NUMBER, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_P1, SLOT_P2, SLOT_P3});
        add(10, "FRACTAL_STATE_FINGERPRINT",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_P1});
        add(15, "FRACTAL_STATE_DISTANCE",
                RetType.DOUBLE,
                new ArgType[]{ArgType.ARRAY, ArgType.ARRAY, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_B, SLOT_P1});
        add(11, "FRACTAL_VASCULAR_NETWORK",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY, ArgType.ARRAY, ArgType.ARRAY},
                new int[]{SLOT_A, SLOT_B, SLOT_C});
        add(12, "FRACTAL_CORTICAL_FOLDING",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY, ArgType.ARRAY},
                new int[]{SLOT_A, SLOT_B});
        add(13, "FRACTAL_NERVE_PLEXUS_METRIC",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY, ArgType.NUMBER, ArgType.ARRAY},
                new int[]{SLOT_A, SLOT_P1, SLOT_B});
        add(14, "FRACTAL_OPTIMIZE_PORTFOLIO_EX",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY, ArgType.ARRAY, ArgType.NUMBER, ArgType.NUMBER, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_B, SLOT_P1, SLOT_P2, SLOT_P3});

        // The multimodal portfolio family. These are enterprise-gated:
        // their core symbols live in the separately licensed enterprise
        // library, so on a Community build they report that the tier is
        // not loaded rather than answering with a different algorithm.
        // They are marked java-only because they need their own native
        // entry point: the dispatcher returns a scalar, and these
        // return a candidates list.
        add(16, "FRACTAL_OPTIMIZE_PORTFOLIO_MULTIMODAL",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY, ArgType.ARRAY, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_B, SLOT_P1},
                false,
                true);
        add(17, "FRACTAL_OPTIMIZE_PORTFOLIO_MULTIMODAL_EX",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY, ArgType.ARRAY, ArgType.NUMBER, ArgType.NUMBER, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_B, SLOT_P1, SLOT_P2, SLOT_P3},
                false,
                true);
        add(18, "FRACTAL_OPTIMIZE_PORTFOLIO_MULTIMODAL_PARETO",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY, ArgType.ARRAY, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_B, SLOT_P1},
                false,
                true);

        // ---- vector ---------------------------------------------------
        add(20, "FRACTAL_VECTOR_L2_DISTANCE",
                RetType.DOUBLE,
                new ArgType[]{ArgType.ARRAY, ArgType.ARRAY},
                new int[]{SLOT_A, SLOT_B});
        add(21, "FRACTAL_VECTOR_L2_SQUARED",
                RetType.DOUBLE,
                new ArgType[]{ArgType.ARRAY, ArgType.ARRAY},
                new int[]{SLOT_A, SLOT_B});
        add(22, "FRACTAL_VECTOR_COSINE_DISTANCE",
                RetType.DOUBLE,
                new ArgType[]{ArgType.ARRAY, ArgType.ARRAY},
                new int[]{SLOT_A, SLOT_B});
        add(23, "FRACTAL_VECTOR_COSINE_SIMILARITY",
                RetType.DOUBLE,
                new ArgType[]{ArgType.ARRAY, ArgType.ARRAY},
                new int[]{SLOT_A, SLOT_B});
        add(24, "FRACTAL_VECTOR_NEGATIVE_INNER_PRODUCT",
                RetType.DOUBLE,
                new ArgType[]{ArgType.ARRAY, ArgType.ARRAY},
                new int[]{SLOT_A, SLOT_B});
        add(25, "FRACTAL_VECTOR_NORM",
                RetType.DOUBLE,
                new ArgType[]{ArgType.ARRAY},
                new int[]{SLOT_A});
        add(26, "FRACTAL_VECTOR_LP_DISTANCE",
                RetType.DOUBLE,
                new ArgType[]{ArgType.ARRAY, ArgType.ARRAY, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_B, SLOT_P1});
        add(27, "FRACTAL_VECTOR_HAMMING_DISTANCE",
                RetType.BIGINT,
                new ArgType[]{ArgType.ARRAY, ArgType.ARRAY},
                new int[]{SLOT_A, SLOT_B});
        add(28, "FRACTAL_VECTOR_ADD",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY, ArgType.ARRAY},
                new int[]{SLOT_A, SLOT_B},
                true,
                false);
        add(29, "FRACTAL_VECTOR_SUB",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY, ArgType.ARRAY},
                new int[]{SLOT_A, SLOT_B},
                true,
                false);
        add(30, "FRACTAL_VECTOR_SCALE",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_P1},
                true,
                false);
        add(31, "FRACTAL_VECTOR_NORMALIZE",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY},
                new int[]{SLOT_A},
                true,
                false);
        add(32, "FRACTAL_VECTOR_QUANTIZE_BINARY",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY},
                new int[]{SLOT_A},
                true,
                false);
        add(33, "FRACTAL_VECTOR_QUANTIZE_INT8",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY},
                new int[]{SLOT_A});
        add(34, "FRACTAL_VECTOR_DIMS",
                RetType.BIGINT,
                new ArgType[]{ArgType.ARRAY},
                new int[]{SLOT_A});
        // The constructors and the JSON formatter are pure Java -- they
        // never call the core.
        add(35, "FRACTAL_VECTOR_TO_JSON",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY},
                new int[]{SLOT_A},
                false,
                true);
        add(36, "FRACTAL_VECTOR_FROM_TEXT",
                RetType.STRING,
                new ArgType[]{ArgType.STRING},
                new int[]{SLOT_A},
                false,
                true);
        add(37, "FRACTAL_VECTOR",
                RetType.STRING,
                new ArgType[]{ArgType.NUMBER},
                new int[]{SLOT_A},
                false,
                true);

        // -- cognition ---------------------------------------------------
        // The reasoning tier. These reach the core's reasoning plugin,
        // which speaks the OpenAI wire format over HTTP.
        add(38, "FRACTAL_REASON",
                RetType.STRING,
                new ArgType[]{ArgType.STRING, ArgType.STRING},
                new int[]{SLOT_A, SLOT_B},
                false,
                true);
        add(39, "FRACTAL_EMBED",
                RetType.STRING,
                new ArgType[]{ArgType.STRING},
                new int[]{SLOT_A},
                false,
                true);

        // -- reading a JSON document -------------------------------------
        // The functions above answer with a JSON document. Druid's own
        // JSON_VALUE reads a COMPLEX column, not a JSON string, so the
        // extension needs its own accessor for the documents it produces.
        add(40, "FRACTAL_JSON_VALUE",
                RetType.DOUBLE,
                new ArgType[]{ArgType.STRING, ArgType.STRING},
                new int[]{SLOT_A, SLOT_B},
                false,
                true);
        add(41, "FRACTAL_JSON_TEXT",
                RetType.STRING,
                new ArgType[]{ArgType.STRING, ArgType.STRING},
                new int[]{SLOT_A, SLOT_B},
                false,
                true);

        // -- the node's own identity -------------------------------------
        // The core's edition and version, as zero-argument functions.
        // 38 of the demo kits open with them as a sanity check.
        //
        // They are named fractal_edition and fractal_version, like every
        // other function here (FRACTAL_*).
        add(42, "FRACTAL_VERSION",
                RetType.STRING,
                new ArgType[0],
                new int[0],
                false,
                true);
        add(43, "FRACTAL_EDITION",
                RetType.STRING,
                new ArgType[0],
                new int[0],
                false,
                true);

        // -- the config / session tier ------------------------------------
        // These are named fractal_config_set and fractal_config_get,
        // with no aliases.
        //
        // The session id is an argument: a Druid query has no connection
        // to hang a session on, so the caller names the session it is
        // speaking for. Only the tuning keys may be set -- the operator's
        // settings are refused (see FractalSqlConfig).
        add(44, "FRACTAL_CONFIG_SET",
                RetType.STRING,
                new ArgType[]{ArgType.STRING, ArgType.STRING, ArgType.STRING},
                new int[]{SLOT_A, SLOT_B, SLOT_C},
                false,
                true);
        add(45, "FRACTAL_CONFIG_GET",
                RetType.STRING,
                new ArgType[]{ArgType.STRING, ArgType.STRING},
                new int[]{SLOT_A, SLOT_B},
                false,
                true);
        add(46, "FRACTAL_CONFIG_RESET",
                RetType.BIGINT,
                new ArgType[]{ArgType.STRING},
                new int[]{SLOT_A},
                false,
                true);
        add(47, "FRACTAL_CONFIG_LIST",
                RetType.STRING,
                new ArgType[]{ArgType.STRING},
                new int[]{SLOT_A},
                false,
                true);
        add(48, "FRACTAL_CONFIG_KEYS",
                RetType.STRING,
                new ArgType[0],
                new int[0],
                false,
                true);

        // -- the enterprise tier -------------------------------------------
        // The enterprise surface. On the community build every
        // one of these is a working stub that reports the tier as not
        // loaded; here they act on the extension's own ledger, which is
        // the same append-only chain and MAC envelope the community
        // build ships. The core's QTL blob format needs the enterprise
        // library loaded.
        add(60, "FRACTAL_LEDGER_FLUSH",
                RetType.BIGINT,
                new ArgType[0],
                new int[0],
                false,
                true);
        add(61, "FRACTAL_LEDGER_LOAD",
                RetType.BIGINT,
                new ArgType[0],
                new int[0],
                false,
                true);
        add(62, "FRACTAL_LEDGER_COMPACT",
                RetType.BIGINT,
                new ArgType[0],
                new int[0],
                false,
                true);
        add(63, "FRACTAL_LEDGER_RESET_SOFT",
                RetType.BIGINT,
                new ArgType[0],
                new int[0],
                false,
                true);
        add(64, "FRACTAL_LEDGER_RESET_HARD",
                RetType.BIGINT,
                new ArgType[0],
                new int[0],
                false,
                true);
        add(65, "FRACTAL_LEDGER_TRUTH_COUNT",
                RetType.BIGINT,
                new ArgType[0],
                new int[0],
                false,
                true);
        add(66, "FRACTAL_LEDGER_SHADOW_COUNT",
                RetType.BIGINT,
                new ArgType[0],
                new int[0],
                false,
                true);
        add(68, "FRACTAL_LEDGER_VERIFY",
                RetType.STRING,
                new ArgType[0],
                new int[0],
                false,
                true);
        add(59, "FRACTAL_LOCK_DESTRUCTIVE",
                RetType.BIGINT,
                new ArgType[0],
                new int[0],
                false,
                true);
        add(67, "FRACTAL_AUDIT_UNPACK",
                RetType.STRING,
                new ArgType[]{ArgType.STRING},
                new int[]{SLOT_A},
                false,
                true);
        add(69, "FRACTAL_AUDIT_LOG",
                RetType.BIGINT,
                new ArgType[]{ArgType.STRING, ArgType.STRING},
                new int[]{SLOT_A, SLOT_B},
                false,
                true);

        // -- the corpus tier ---------------------------------------------
        // Scout: the SFS over a whole corpus, with the walk turned off
        // and the final population returned, so it disperses across
        // distinct basins instead of collapsing into one. The corpus
        // arrives as an ARRAY -- ARRAY_AGG over the column -- because
        // a Druid aggregate cannot hold a growable buffer.
        add(49, "FRACTAL_SEARCH_EXPLORE",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY, ArgType.STRING, ArgType.STRING},
                new int[]{SLOT_A, SLOT_B, SLOT_C},
                false,
                true);
        // The tunable form of the same search: the SFS over the query
        // alone, with the iteration count, the population size and the
        // diffusion factor named by the caller.
        // The table-free CONVERGENCE function. It was renamed from
        // FRACTAL_SEARCH on 2026-11-18 (it runs SFS toward the query
        // direction; it is not a retrieval function) and there is NO
        // alias: the old name is refused.
        add(50, "FRACTAL_SFS_CONVERGE_DEBUG",
                RetType.STRING,
                new ArgType[]{ArgType.STRING, ArgType.NUMBER, ArgType.NUMBER, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_P1, SLOT_P2, SLOT_P3},
                false,
                true);

        // -- the index tier ----------------------------------------------
        // The native IVF index. The maths lives in the daemon; the
        // datasource I/O lives in the extension (Druid has no DDL and no
        // DML, so the index's cells live in a companion datasource,
        // written with an MSQ INSERT).
        //
        // THE OPTIONS ARGUMENT IS REQUIRED here (pass '' for the
        // defaults): a Calcite operator has a fixed arity, so the optional
        // trailing options cannot be omitted on Druid.
        add(70, "FRACTAL_INDEX_CREATE",
                RetType.STRING,
                new ArgType[]{ArgType.STRING, ArgType.STRING, ArgType.STRING},
                new int[]{SLOT_A, SLOT_B, SLOT_C},
                false,
                true);
        add(71, "FRACTAL_INDEX_REBUILD",
                RetType.STRING,
                new ArgType[]{ArgType.STRING, ArgType.STRING},
                new int[]{SLOT_A, SLOT_B},
                false,
                true);
        add(72, "FRACTAL_INDEX_DROP",
                RetType.STRING,
                new ArgType[]{ArgType.STRING},
                new int[]{SLOT_A},
                false,
                true);
        add(73, "FRACTAL_INDEX_INFO",
                RetType.STRING,
                new ArgType[]{ArgType.STRING},
                new int[]{SLOT_A},
                false,
                true);
        add(74, "FRACTAL_INDEX_CANDIDATES",
                RetType.STRING,
                new ArgType[]{ArgType.STRING, ArgType.STRING, ArgType.STRING, ArgType.STRING},
                new int[]{SLOT_A, SLOT_B, SLOT_C, SLOT_P1},
                false,
                true);
        // The named feature store: a datasource of per-doc_id vectors (the newest row of a doc_id wins).
        add(78, "FRACTAL_STORE_MORPHOLOGY",
                RetType.STRING,
                new ArgType[]{ArgType.NUMBER, ArgType.STRING},
                new int[]{SLOT_P1, SLOT_A},
                false,
                true);
        add(79, "FRACTAL_MINE_TOPOLOGY_NEGATIVES",
                RetType.STRING,
                new ArgType[]{ArgType.STRING, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_P1},
                false,
                true);
        // The INDEXED search: fractal_search(table, column, query, k,
        // options). It reads the index's cells, and every distance it
        // returns is verified against the index's own FP16 payload.
        //
        // The table-free convergence function is fractal_sfs_converge, and
        // the per-row distance aggregate is FRACTAL_SEARCH_DISTANCE (a
        // Calcite operator cannot carry two operators with one name).
        add(75, "FRACTAL_SEARCH",
                RetType.STRING,
                new ArgType[]{ArgType.STRING, ArgType.STRING, ArgType.STRING, ArgType.NUMBER, ArgType.STRING},
                new int[]{SLOT_A, SLOT_B, SLOT_C, SLOT_P1, SLOT_P2},
                false,
                true);

        // -- the session tier ---------------------------------------------
        // The Diversify monitor and the repulsive post-filter: the
        // core's opt-in v2.0 search behaviour, driven from the session.
        add(51, "FRACTAL_DIVERSIFY_ENABLE",
                RetType.BIGINT,
                new ArgType[0],
                new int[0],
                false,
                true);
        add(52, "FRACTAL_DIVERSIFY_DISABLE",
                RetType.BIGINT,
                new ArgType[0],
                new int[0],
                false,
                true);
        add(53, "FRACTAL_DIVERSIFY_SET_PARAMS",
                RetType.BIGINT,
                new ArgType[]{ArgType.STRING},
                new int[]{SLOT_A},
                false,
                true);
        // The Diversify inspector: the last computed D_q, whether the
        // monitor is on, and its own rolling overhead.
        add(54, "FRACTAL_EXPLAIN_RESULT",
                RetType.STRING,
                new ArgType[0],
                new int[0],
                false,
                true);
        add(55, "FRACTAL_DETECT_COLLAPSE",
                RetType.DOUBLE,
                new ArgType[0],
                new int[0],
                false,
                true);
        // The feedback report: a caller's verdict on a result, which
        // the ledger records.
        add(56, "FRACTAL_FEEDBACK_REPORT",
                RetType.BIGINT,
                new ArgType[]{ArgType.NUMBER, ArgType.STRING, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_B, SLOT_P1},
                false,
                true);
        // The isolated background: a result the caller has set aside.
        add(57, "FRACTAL_ISOLATE_BACKGROUND",
                RetType.BIGINT,
                new ArgType[]{ArgType.NUMBER},
                new int[]{SLOT_A},
                false,
                true);
        // The cycle detector: Brent's algorithm over a stream of state
        // fingerprints.
        add(58, "FRACTAL_CYCLE_DETECT",
                RetType.STRING,
                new ArgType[]{ArgType.STRING, ArgType.NUMBER, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_P1, SLOT_P2},
                false,
                true);
        // The table-free CONVERGENCE function: SFS toward the query direction, answering {dim, population_size, best_point, best_fit}.
        // FRACTAL_SFS_CONVERGE_DEBUG is the same search with the full trajectory trace.
        // Value-weighted k-subset allocation: maximise sum(weight x item_value) with at most k items weighted, each weight at most its upper bound,
        // the weights summing to 1. prev_weights and turnover_penalty steer the search away from reallocating. At most 255 items.
        add(77, "FRACTAL_OPTIMIZE_SUBSET",
                RetType.STRING,
                new ArgType[]{ArgType.ARRAY, ArgType.ARRAY, ArgType.NUMBER, ArgType.ARRAY, ArgType.NUMBER, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_B, SLOT_P1, SLOT_C, SLOT_P2, SLOT_P3});
        add(76, "FRACTAL_SFS_CONVERGE",
                RetType.STRING,
                new ArgType[]{ArgType.STRING, ArgType.NUMBER, ArgType.NUMBER, ArgType.NUMBER},
                new int[]{SLOT_A, SLOT_P1, SLOT_P2, SLOT_P3},
                false,
                true);
    }

    /** The registry, in declaration order. */
    public static List<Spec> all()
    {
        return Collections.unmodifiableList(new ArrayList<>(BY_NAME.values()));
    }

    /** Look a function up by SQL name. */
    public static Spec byName(String sqlName)
    {
        final Spec spec = BY_NAME.get(sqlName.toUpperCase(java.util.Locale.ROOT));
        if (spec == null) {
            throw new IllegalArgumentException("fractalsql: no such function: " + sqlName);
        }
        return spec;
    }

    /** Look a function up by SQL name, or null if there is none. */
    public static Spec findByName(String sqlName)
    {
        return BY_NAME.get(sqlName.toUpperCase(java.util.Locale.ROOT));
    }

    /** Look a function up by native id. */
    public static Spec byId(int id)
    {
        final Spec spec = BY_ID.get(id);
        if (spec == null) {
            throw new IllegalArgumentException("fractalsql: no such function id: " + id);
        }
        return spec;
    }

    /**
     * The native ids the JNI dispatcher knows about.
     *
     * <p>Kept in step with {@code fractalsql_jni.c} by hand and checked by
     * the unit tests -- a mismatch here means a call reaches the wrong core
     * function, which is silent, so it is worth asserting.
     */
    public static int[] nativeIds()
    {
        return new int[]{
                1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
                20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
                77
        };
    }

    /** Whether the registry and the native table agree on the id set. */
    public static boolean idsMatchTheNativeTable()
    {
        final int[] ids = nativeIds();
        final java.util.Set<Integer> wanted = new java.util.HashSet<>();
        for (int id : ids) {
            wanted.add(id);
        }
        // The Java-only functions never reach the dispatcher, so they are
        // not in its table.
        final java.util.Set<Integer> dispatched = new java.util.HashSet<>();
        for (Map.Entry<Integer, Spec> entry : BY_ID.entrySet()) {
            if (!entry.getValue().isJavaOnly()) {
                dispatched.add(entry.getKey());
            }
        }
        return wanted.equals(dispatched);
    }
}
