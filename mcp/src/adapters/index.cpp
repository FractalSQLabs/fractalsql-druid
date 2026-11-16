// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// Index tier: 7 tools -- the native IVF index's management functions and the
// indexed search.
//
// The maths lives in the daemon (the core's IVF entry points) and the
// datasource I/O lives in the extension: Druid has no DDL and no DML, so the
// index's CELLS live in a COMPANION DATASOURCE, written with an MSQ INSERT
// (the same precedent the vectorizer's companion datasource sets). Druid has
// no cheap fetch by id either, so the vector a candidate needs to be verified
// is stored INSIDE the index, as an FP16 copy: the distances the search
// returns are exact to FP16 precision, not FP32.
#include "index.h"
#include "../db.h"
#include "../tool_param_helpers.h"
#include "../vectors.h"

namespace fsqlmcp
{
    std::vector<ToolSpec> buildIndexTools( Db& db )
    {
        std::vector<ToolSpec> t;

        t.push_back( ToolSpec{ "fractal_index_create", "Index", ToolClass::Cheap,
            { Str("table", true, "Datasource holding the vectors."),
              Str("column", true, "Vector column to index."),
              Obj("options", false, "{name:string, id_col:string, vector_format:string=INT8, nlist:int, "
                                    "pca_dim:int, iters:int, sample:int, seed:int, index_table:string}") },
            std::nullopt, true, false,   /* persists the index: refused in read-only mode */
            [&db]( const Json& a, CallCtx& ) {
                Json opts = a.contains( "options" ) && a.at( "options" ).is_object()
                    ? a.at( "options" ) : Json::object();
                return parseJsonLenient( db.callScalar( "SELECT fractal_index_create(?, ?, ?)",
                    { a.at( "table" ).get<std::string>(), a.at( "column" ).get<std::string>(),
                      opts.dump() } ) );
            } } );
        t.back().description = "Builds the native IVF index over a datasource's vector column. Two passes over the "
            "rows: a sample pass that trains the model, then an encode pass that assigns each row to a cell. The "
            "cells are written into a COMPANION DATASOURCE with an MSQ INSERT (Druid has no DDL and no DML): the "
            "default is <name>_cells. The row ids are the id_col values when the column is numeric, else the row's "
            "scan position (Druid has no row locator). Returns {index, index_table, rows, dim, format, nlist, "
            "code_bytes, id_kind, state}. The core must carry the IVF maths; when it does not, every index operation "
            "says so.";

        t.push_back( ToolSpec{ "fractal_index_ensure", "Index", ToolClass::Cheap,
            { Str("table", true, "Datasource holding the vectors."),
              Str("column", true, "Vector column to index."),
              Obj("options", false, "{name:string, id_col:string, vector_format:string=INT8, nlist:int, "
                                    "pca_dim:int, iters:int, sample:int, seed:int, index_table:string}") },
            std::nullopt, true, false,   /* may build, refresh or rebuild the index: refused in read-only mode */
            [&db]( const Json& a, CallCtx& ) {
                Json opts = a.contains( "options" ) && a.at( "options" ).is_object()
                    ? a.at( "options" ) : Json::object();
                return parseJsonLenient( db.callScalar( "SELECT fractal_index_ensure(?, ?, ?)",
                    { a.at( "table" ).get<std::string>(), a.at( "column" ).get<std::string>(),
                      opts.dump() } ) );
            } } );
        t.back().description = "Leaves the index on a datasource's vector column fit to use, doing the least work: builds it when there "
            "is none (created), folds in the rows added since the build when that is all that is needed (refreshed), rebuilds it after "
            "more than a quarter of the rows were added or a fifth deleted (rebuilt), and otherwise changes nothing (unchanged). A "
            "degraded index is rebuilt only when new options are given. Returns {name, action, status, generation, rows}.";

        t.push_back( ToolSpec{ "fractal_index_rebuild", "Index", ToolClass::Cheap,
            { Str("name", true, "Index name."),
              Obj("options", false, "{nlist:int, iters:int, sample:int, seed:int}") },
            std::nullopt, true, false,   /* replaces the index generation: refused in read-only mode */
            [&db]( const Json& a, CallCtx& ) {
                Json opts = a.contains( "options" ) && a.at( "options" ).is_object()
                    ? a.at( "options" ) : Json::object();
                return parseJsonLenient( db.callScalar( "SELECT fractal_index_rebuild(?, ?)",
                    { a.at( "name" ).get<std::string>(), opts.dump() } ) );
            } } );
        t.back().description = "Rebuilds an index over the source's rows as they are now. The cells of the previous "
            "generation stay in the companion datasource and are ignored; a Druid datasource cannot be rewritten.";

        t.push_back( ToolSpec{ "fractal_index_drop", "Index", ToolClass::Cheap,
            { Str("name", true, "Index name.") }, std::nullopt, true, false,
            [&db]( const Json& a, CallCtx& ) {
                return parseJsonLenient( db.callScalar( "SELECT fractal_index_drop(?)",
                    { a.at( "name" ).get<std::string>() } ) );
            } } );
        t.back().description = "PERMANENT AND IRREVERSIBLE: drops the index. The cells stay in the companion "
            "datasource -- a Druid datasource cannot be rewritten, and Druid has no DELETE -- and are ignored from "
            "then on. Replace the datasource to reclaim the space.";

        t.push_back( ToolSpec{ "fractal_index_refresh", "Index", ToolClass::Cheap,
            { Str("name", true, "Index name.") },
            std::nullopt, true, false,   /* appends cells to the index datasource: refused in read-only mode */
            [&db]( const Json& a, CallCtx& ) {
                return parseJsonLenient( db.callScalar( "SELECT fractal_index_refresh(?)",
                    { a.at( "name" ).get<std::string>() } ) );
            } } );
        t.back().description = "Folds the rows added since the build (an id above the highest the index covers) into "
            "the index's cells without retraining: each is encoded with the existing model and appended to the "
            "companion datasource. Returns {name, added, rows, generation, refreshed}. A deleted row is already "
            "dropped by the verify step and a changed vector needs fractal_index_rebuild; fractal_index_info says "
            "which one it advises.";

        t.push_back( ToolSpec{ "fractal_index_list", "Index", ToolClass::Cheap,
            {}, std::nullopt, false, true,   /* reads the index metadata */
            [&db]( const Json&, CallCtx& ) {
                return parseJsonLenient( db.callScalar( "SELECT fractal_index_list()", {} ) );
            } } );
        t.back().description = "The registered indexes, each with its shape, rows, rows now, status (ready, stale, "
            "empty, orphaned or unknown) and generation.";

        t.push_back( ToolSpec{ "fractal_index_info", "Index", ToolClass::Cheap,
            { Str("name", true, "Index name.") }, std::nullopt, false, true,   /* reads the index metadata */
            [&db]( const Json& a, CallCtx& ) {
                return parseJsonLenient( db.callScalar( "SELECT fractal_index_info(?)",
                    { a.at( "name" ).get<std::string>() } ) );
            } } );
        t.back().description = "What the index is: its shape (dim, format, nlist, code_bytes), the rows it covers, "
            "a STATUS (ready, stale, empty, orphaned or unknown) with advice on what to do next (refresh or rebuild), "
            "and the rows added or deleted since the build (delta_rows counts the added ones).";

        t.push_back( ToolSpec{ "fractal_index_candidates", "Index", ToolClass::Cheap,
            { Str("table", true, "Datasource holding the vectors."),
              Str("column", true, "Vector column the index covers."),
              Vec("query", true, "Query vector."),
              Obj("options", false, "{index:string, nprobe:int=8, per_cell:int=1}") },
            std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) {
                Json opts = a.contains( "options" ) && a.at( "options" ).is_object()
                    ? a.at( "options" ) : Json::object();
                return parseJsonLenient( db.callScalar( "SELECT fractal_index_candidates(?, ?, ?, ?)",
                    { a.at( "table" ).get<std::string>(), a.at( "column" ).get<std::string>(),
                      vectors::vectorParamToText( a.at( "query" ), "query" ), opts.dump() } ) );
            } } );
        t.back().description = "The candidate row ids for Scout: the nearest cells in full, plus per_cell "
            "representatives from every other cell, plus the rows newer than the index. The candidates are the "
            "index's own row ids, not a scan position.";

        t.push_back( ToolSpec{ "fractal_search", "Index", ToolClass::Cheap,
            { Str("table", true, "Datasource holding the vectors."),
              Str("column", true, "Vector column the index covers."),
              Vec("query", true, "Query vector."),
              Int("k", false, "Neighbors to return.", 10),
              Obj("options", false, "{index:string, nprobe:int=8, rerank:int=30, verify:int=1, ids:[int]} (ids: restrict the search to these row ids)") },
            std::nullopt, false, false,
            [&db]( const Json& a, CallCtx& ) {
                Json opts = a.contains( "options" ) && a.at( "options" ).is_object()
                    ? a.at( "options" ) : Json::object();
                return parseJsonLenient( db.callScalar( "SELECT fractal_search(?, ?, ?, ?, ?)",
                    { a.at( "table" ).get<std::string>(), a.at( "column" ).get<std::string>(),
                      vectors::vectorParamToText( a.at( "query" ), "query" ),
                      static_cast<std::int64_t>( a.value( "k", 10 ) ), opts.dump() } ) );
            } } );
        t.back().description = "The INDEXED search: the IVF index's cells are probed, read and searched, and every "
            "candidate is VERIFIED before it is returned -- the distance is recomputed from the index's own FP16 copy "
            "of the vector, so it is exact to FP16 precision, not FP32. Returns {candidates:[{doc_id, distance}], "
            "rows_scanned, cells_probed, verified, precision, indexed_rows}: rows_scanned is the number of rows the "
            "index read, so it is far below the datasource's row count. It does NOT apply Diversify repulsion.";

        return t;
    }
}
