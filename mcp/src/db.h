// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// fractalsql-druid-mcp's connection layer: Apache Druid's SQL API over HTTP
// for the per-row functions, and the extension's /fractalsql endpoints for
// the operations that need a query or provider of their own (agents,
// text-to-SQL, the vectorizer, the table-backed searches). One dedicated
// session per MCP session, all execution under the session's own mutex.
#pragma once
#include <string>
#include <vector>
#include <variant>
#include <memory>
#include <map>
#include <set>
#include <mutex>
#include <atomic>
#include <chrono>
#include <iostream>
#include <optional>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <netdb.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include "mcp_json.h"
#include "errors.h"
#include "logging.h"

namespace fsqlmcp
{
    static const char* const kMcpPluginName       = "fractalsql-druid-mcp";
    static const char* const kMcpPluginVersion    = "2.0.0";
    static const char* const kEngineVersionExpect = "2.0.0";

    using SqlValue = std::variant<std::nullptr_t, std::int64_t, double, std::string,
                                  std::vector<std::uint8_t>>;

    inline std::optional<std::string> asText( const SqlValue& v )
    {
        return std::holds_alternative<std::string>( v )
            ? std::optional<std::string>( std::get<std::string>( v ) ) : std::nullopt;
    }

    inline std::optional<std::vector<std::uint8_t>> asBlob( const SqlValue& v )
    {
        return std::holds_alternative<std::vector<std::uint8_t>>( v )
            ? std::optional<std::vector<std::uint8_t>>( std::get<std::vector<std::uint8_t>>( v ) )
            : std::nullopt;
    }

    inline Json asScalarJson( const SqlValue& v )
    {
        return std::visit( []( auto&& x ) -> Json
        {
            using T = std::decay_t<decltype( x )>;
            if constexpr( std::is_same_v<T, std::nullptr_t> ) return nullptr;
            else if constexpr( std::is_same_v<T, std::int64_t> ) return x;
            else if constexpr( std::is_same_v<T, double> ) return x;
            else if constexpr( std::is_same_v<T, std::string> ) return x;
            else return nullptr;
        }, v );
    }

    // NULL -> {"ok":true}; non-JSON text -> {"text":text}.
    inline Json parseJsonLenient( const SqlValue& v )
    {
        const auto t = asText( v );
        if( !t ) return Json{ { "ok", true } };
        try { return Json::parse( *t ); } catch( ... ) { return Json{ { "text", *t } }; }
    }

    // NULL or non-JSON text is a real engine-layer bug.
    inline Json parseJsonStrict( const SqlValue& v )
    {
        const auto t = asText( v );
        if( !t )
            throw ToolError( ErrorClass::ServerInternal, "expected a JSON document, engine returned NULL" );
        try { return Json::parse( *t ); }
        catch( ... )
        {
            throw ToolError( ErrorClass::ServerInternal,
                "engine returned non-JSON text where a JSON document was documented" );
        }
    }

    // ---------------------------------------------------------------- HTTP

    namespace druidhttp
    {
        struct Url
        {
            bool tls = false;
            std::string host;
            std::string port;
            std::string prefix;   // path prefix, no trailing slash
        };

        inline Url parseUrl( const std::string& u )
        {
            Url out;
            std::string rest = u;
            if( rest.rfind( "https://", 0 ) == 0 ) { out.tls = true; rest = rest.substr( 8 ); }
            else if( rest.rfind( "http://", 0 ) == 0 ) { rest = rest.substr( 7 ); }
            else throw ToolError( ErrorClass::Connectivity, "the Druid URL must start with http:// or https://" );
            const std::size_t slash = rest.find( '/' );
            std::string hostPort = slash == std::string::npos ? rest : rest.substr( 0, slash );
            out.prefix = slash == std::string::npos ? "" : rest.substr( slash );
            while( !out.prefix.empty() && out.prefix.back() == '/' ) out.prefix.pop_back();
            const std::size_t colon = hostPort.rfind( ':' );
            if( colon != std::string::npos && hostPort.find( ']' ) == std::string::npos )
            {
                out.port = hostPort.substr( colon + 1 );
                out.host = hostPort.substr( 0, colon );
            }
            else
            {
                out.host = hostPort;
                out.port = out.tls ? "443" : "80";
            }
            if( out.host.empty() )
                throw ToolError( ErrorClass::Connectivity, "the Druid URL has no host" );
            return out;
        }

        struct Response
        {
            int status = 0;
            std::string body;
        };

        class Conn
        {
        public:
            Conn() = default;
            Conn( const Conn& ) = delete;
            Conn& operator=( const Conn& ) = delete;
            ~Conn()
            {
                if( ssl_ ) { SSL_shutdown( ssl_ ); SSL_free( ssl_ ); }
                if( ctx_ ) SSL_CTX_free( ctx_ );
                if( fd_ >= 0 ) ::close( fd_ );
            }

            void open( const Url& u, int timeoutMs, bool insecure )
            {
                addrinfo hints{};
                hints.ai_socktype = SOCK_STREAM;
                addrinfo* res = nullptr;
                if( getaddrinfo( u.host.c_str(), u.port.c_str(), &hints, &res ) != 0 || !res )
                    throw ToolError( ErrorClass::Connectivity, "cannot resolve the Druid host " + u.host );
                std::string lastErr = "connect failed";
                for( addrinfo* p = res; p; p = p->ai_next )
                {
                    fd_ = ::socket( p->ai_family, p->ai_socktype, p->ai_protocol );
                    if( fd_ < 0 ) continue;
                    const int flags = fcntl( fd_, F_GETFL, 0 );
                    fcntl( fd_, F_SETFL, flags | O_NONBLOCK );
                    int rc = ::connect( fd_, p->ai_addr, p->ai_addrlen );
                    if( rc != 0 && errno == EINPROGRESS )
                    {
                        pollfd pfd{ fd_, POLLOUT, 0 };
                        rc = poll( &pfd, 1, 10000 ) == 1 ? 0 : -1;
                        int soerr = 0; socklen_t sl = sizeof soerr;
                        if( rc == 0 && ( getsockopt( fd_, SOL_SOCKET, SO_ERROR, &soerr, &sl ) != 0 || soerr != 0 ) ) rc = -1;
                    }
                    if( rc == 0 ) { fcntl( fd_, F_SETFL, flags ); break; }
                    lastErr = std::strerror( errno );
                    ::close( fd_ ); fd_ = -1;
                }
                freeaddrinfo( res );
                if( fd_ < 0 )
                    throw ToolError( ErrorClass::Connectivity, "cannot connect to Druid at " + u.host + ":" + u.port + ": " + lastErr );
                timeval tv{ timeoutMs / 1000, ( timeoutMs % 1000 ) * 1000 };
                setsockopt( fd_, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv );
                setsockopt( fd_, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv );
                if( u.tls )
                {
                    ctx_ = SSL_CTX_new( TLS_client_method() );
                    if( !ctx_ ) throw ToolError( ErrorClass::Connectivity, "TLS is not available" );
                    SSL_CTX_set_min_proto_version( ctx_, TLS1_2_VERSION );
                    if( insecure ) SSL_CTX_set_verify( ctx_, SSL_VERIFY_NONE, nullptr );
                    else { SSL_CTX_set_default_verify_paths( ctx_ ); SSL_CTX_set_verify( ctx_, SSL_VERIFY_PEER, nullptr ); }
                    ssl_ = SSL_new( ctx_ );
                    SSL_set_fd( ssl_, fd_ );
                    SSL_set_tlsext_host_name( ssl_, u.host.c_str() );
                    if( !insecure ) SSL_set1_host( ssl_, u.host.c_str() );
                    if( SSL_connect( ssl_ ) != 1 )
                        throw ToolError( ErrorClass::Connectivity, "TLS handshake with Druid failed" );
                }
            }

            void writeAll( const std::string& s )
            {
                std::size_t off = 0;
                while( off < s.size() )
                {
                    const int n = ssl_ ? SSL_write( ssl_, s.data() + off, static_cast<int>( s.size() - off ) )
                                       : static_cast<int>( ::send( fd_, s.data() + off, s.size() - off, MSG_NOSIGNAL ) );
                    if( n <= 0 ) throw ToolError( ErrorClass::Connectivity, "the Druid connection dropped while sending" );
                    off += static_cast<std::size_t>( n );
                }
            }

            // The largest Druid response accepted (a SQL result set can be large; a stream that never ends is not one).
            static constexpr std::size_t kMaxDruidResponseBytes = std::size_t( 256 ) << 20;

            // Reads until EOF (the request carries Connection: close).
            std::string readAll()
            {
                std::string out;
                char buf[65536];
                for( ;; )
                {
                    const int n = ssl_ ? SSL_read( ssl_, buf, sizeof buf )
                                       : static_cast<int>( ::recv( fd_, buf, sizeof buf, 0 ) );
                    if( n > 0 )
                    {
                        // A body that never ends must not grow the heap until the process is killed (SECURITY_AUDIT.md 3.21).
                        if( out.size() + static_cast<std::size_t>( n ) > kMaxDruidResponseBytes )
                            throw ToolError( ErrorClass::Connectivity, "the Druid response was larger than the "
                                             + std::to_string( kMaxDruidResponseBytes >> 20 ) + " MiB limit" );
                        out.append( buf, static_cast<std::size_t>( n ) );
                        continue;
                    }
                    if( n == 0 ) break;
                    if( !ssl_ && ( errno == EAGAIN || errno == EWOULDBLOCK ) )
                        throw ToolError( ErrorClass::Connectivity, "the Druid call timed out" );
                    if( ssl_ )
                    {
                        const int e = SSL_get_error( ssl_, n );
                        if( e == SSL_ERROR_ZERO_RETURN ) break;
                        if( e == SSL_ERROR_SYSCALL && out.size() > 0 ) break;
                        throw ToolError( ErrorClass::Connectivity, "the Druid call failed or timed out" );
                    }
                    break;
                }
                return out;
            }

        private:
            int fd_ = -1;
            SSL_CTX* ctx_ = nullptr;
            SSL* ssl_ = nullptr;
        };

        inline std::string dechunk( const std::string& in )
        {
            std::string out;
            std::size_t p = 0;
            while( p < in.size() )
            {
                const std::size_t eol = in.find( "\r\n", p );
                if( eol == std::string::npos ) break;
                std::size_t len = 0;
                try { len = std::stoul( in.substr( p, eol - p ), nullptr, 16 ); }
                catch( const std::exception& )
                {
                    throw ToolError( ErrorClass::Connectivity, "Druid sent a malformed chunked response" );
                }
                p = eol + 2;
                if( len == 0 ) break;
                if( p + len > in.size() ) break;
                out.append( in, p, len );
                p += len + 2;
            }
            return out;
        }

        inline Response request( const Url& u, const std::string& method, const std::string& path,
                                 const std::string& body, const std::string& authHeader,
                                 int timeoutMs, bool insecure )
        {
            Conn c;
            c.open( u, timeoutMs, insecure );
            std::string req = method + " " + u.prefix + path + " HTTP/1.1\r\n";
            req += "Host: " + u.host + ":" + u.port + "\r\n";
            req += "Connection: close\r\nAccept: application/json\r\n";
            if( !authHeader.empty() ) req += "Authorization: " + authHeader + "\r\n";
            if( method == "POST" )
            {
                req += "Content-Type: application/json\r\n";
                req += "Content-Length: " + std::to_string( body.size() ) + "\r\n";
            }
            req += "\r\n";
            if( method == "POST" ) req += body;
            c.writeAll( req );
            const std::string raw = c.readAll();
            const std::size_t hdrEnd = raw.find( "\r\n\r\n" );
            if( hdrEnd == std::string::npos || raw.compare( 0, 5, "HTTP/" ) != 0 )
                throw ToolError( ErrorClass::Connectivity, "Druid sent a malformed HTTP response" );
            Response r;
            r.status = std::atoi( raw.c_str() + raw.find( ' ' ) + 1 );
            const std::string headers = raw.substr( 0, hdrEnd );
            std::string lower = headers;
            for( char& ch : lower ) ch = static_cast<char>( std::tolower( static_cast<unsigned char>( ch ) ) );
            const std::string content = raw.substr( hdrEnd + 4 );
            r.body = lower.find( "transfer-encoding: chunked" ) != std::string::npos ? dechunk( content ) : content;
            return r;
        }

        inline std::string base64( const std::string& in )
        {
            static const char* t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            std::string out;
            std::size_t i = 0;
            while( i + 2 < in.size() )
            {
                const unsigned v = ( static_cast<unsigned char>( in[ i ] ) << 16 ) | ( static_cast<unsigned char>( in[ i + 1 ] ) << 8 )
                                   | static_cast<unsigned char>( in[ i + 2 ] );
                out += t[ ( v >> 18 ) & 63 ]; out += t[ ( v >> 12 ) & 63 ]; out += t[ ( v >> 6 ) & 63 ]; out += t[ v & 63 ];
                i += 3;
            }
            if( i + 1 == in.size() )
            {
                const unsigned v = static_cast<unsigned char>( in[ i ] ) << 16;
                out += t[ ( v >> 18 ) & 63 ]; out += t[ ( v >> 12 ) & 63 ]; out += "==";
            }
            else if( i + 2 == in.size() )
            {
                const unsigned v = ( static_cast<unsigned char>( in[ i ] ) << 16 ) | ( static_cast<unsigned char>( in[ i + 1 ] ) << 8 );
                out += t[ ( v >> 18 ) & 63 ]; out += t[ ( v >> 12 ) & 63 ]; out += t[ ( v >> 6 ) & 63 ]; out += '=';
            }
            return out;
        }
    }

    // ------------------------------------------------- vector text <-> blob

    // The adapters read vector results as the canonical packed form
    // (u16 dim, u16 reserved, float32 payload, little-endian). Druid returns
    // the core's text form, so the layer packs it on the way in and unpacks
    // it on the way out.
    namespace vecform
    {
        inline std::optional<std::vector<float>> parseText( const std::string& s )
        {
            std::vector<float> out;
            std::size_t i = 0;
            while( i < s.size() && std::isspace( static_cast<unsigned char>( s[ i ] ) ) ) ++i;
            if( i >= s.size() ) return std::nullopt;
            if( s[ i ] == '[' ) ++i;
            while( i < s.size() )
            {
                while( i < s.size() && ( std::isspace( static_cast<unsigned char>( s[ i ] ) ) || s[ i ] == ',' ) ) ++i;
                if( i >= s.size() || s[ i ] == ']' ) break;
                char* end = nullptr;
                const double v = std::strtod( s.c_str() + i, &end );
                if( end == s.c_str() + i ) return std::nullopt;
                out.push_back( static_cast<float>( v ) );
                i = static_cast<std::size_t>( end - s.c_str() );
            }
            return out;
        }

        // The format's dimension field is 16 bits: a longer vector cannot be packed, and is refused rather than written with a
        // truncated length (it then failed the length check on the way back, with no hint why) (SECURITY_AUDIT.md 3.19).
        constexpr std::size_t kMaxDim = 0xffff;

        inline std::vector<std::uint8_t> pack( const std::vector<float>& v )
        {
            if( v.size() > kMaxDim )
                throw ToolError( ErrorClass::Schema, "a vector of " + std::to_string( v.size() ) + " dimensions is over the "
                                 + std::to_string( kMaxDim ) + " the vector format holds" );
            std::vector<std::uint8_t> b( 4 + 4 * v.size() );
            b[ 0 ] = static_cast<std::uint8_t>( v.size() & 0xff );
            b[ 1 ] = static_cast<std::uint8_t>( ( v.size() >> 8 ) & 0xff );
            // An empty vector has a null data(); memcpy with a null source is undefined even for zero bytes.
            if( !v.empty() ) std::memcpy( b.data() + 4, v.data(), 4 * v.size() );
            return b;
        }

        inline std::optional<std::string> unpackToText( const std::vector<std::uint8_t>& b )
        {
            if( b.size() < 4 ) return std::nullopt;
            const std::size_t dim = static_cast<std::size_t>( b[ 0 ] ) | ( static_cast<std::size_t>( b[ 1 ] ) << 8 );
            if( b.size() != 4 + 4 * dim ) return std::nullopt;
            std::string s = "[";
            for( std::size_t i = 0; i < dim; ++i )
            {
                float f;
                std::memcpy( &f, b.data() + 4 + 4 * i, 4 );
                char buf[40];
                std::snprintf( buf, sizeof buf, "%.9g", static_cast<double>( f ) );
                if( i ) s += ',';
                s += buf;
            }
            return s + "]";
        }
    }

    // ----------------------------------------------------- the route table

    namespace druidroutes
    {
        // A function the extension serves as an endpoint rather than as a
        // SQL expression. `names` are the JSON keys of the positional binds.
        struct Route
        {
            const char* path;                   // "/fractalsql/agent/x" etc.
            std::vector<const char*> names;     // bind i -> JSON key names[i]
            bool get = false;
        };

        inline const std::map<std::string, Route>& table()
        {
            static const std::map<std::string, Route> t = {
                { "fractal_agent_anomaly_triage", { "/fractalsql/agent/anomaly_triage",
                    { "log_table", "metric_col", "time_col", "filter_col", "filter_val", "baseline_window" } } },
                { "fractal_agent_regime_triage", { "/fractalsql/agent/regime_triage",
                    { "series", "win", "drift_threshold", "context" } } },
                { "fractal_agent_track_anomaly", { "/fractalsql/agent/track_anomaly",
                    { "track_table", "emb_col", "baseline_vec", "current_vec", "heading_series", "k", "id_col" } } },
                { "fractal_agent_detour_classify", { "/fractalsql/agent/detour_classify",
                    { "vehicle_table", "emb_col", "baseline_vec", "current_vec", "gps_trace", "k", "id_col", "boxcount_dim" } } },
                { "fractal_agent_network_coverage_alert", { "/fractalsql/agent/network_coverage_alert",
                    { "point_cloud", "drift_series", "boxcount_dim", "drift_win", "drift_threshold", "context" } } },
                { "fractal_agent_allocate", { "/fractalsql/agent/allocate",
                    { "mu", "cov", "cardinality", "context" } } },
                { "fractal_agent_rebalance_sibling", { "/fractalsql/agent/rebalance_sibling",
                    { "mu", "cov", "cardinality", "alloc_table", "alloc_emb_col", "baseline_vec", "seed", "k", "id_col", "context" } } },
                { "fractal_agent_diverse_portfolios", { "/fractalsql/agent/diverse_portfolios",
                    { "mu", "cov", "cardinality", "n_restarts", "overlap_threshold", "quality_frac", "seed", "context", "objective_mode" } } },
                { "fractal_agent_route_task", { "/fractalsql/agent/route_task",
                    { "task_emb", "cap_table", "cap_emb_col", "cap_id_col", "budget", "cost_per_route" } } },
                { "fractal_agent_schedule_workload", { "/fractalsql/agent/schedule_workload",
                    { "task_vec", "node_table", "node_emb_col", "node_id_col", "iterations", "population", "k", "context" } } },
                { "fractal_agent_outlier_intercept", { "/fractalsql/agent/outlier_intercept",
                    { "state_vec", "history_table", "emb_col", "threshold", "metric" } } },
                { "fractal_agent_patient_deterioration_triage", { "/fractalsql/agent/patient_deterioration_triage",
                    { "patient_table", "vec_col", "query_vec", "baseline_vec", "current_vec", "cohort_doc_ids", "k", "id_col" } } },
                { "fractal_agent_data_analyst", { "/fractalsql/agent/data_analyst",
                    { "question", "table_names", "max_retries", "context", "auto_execute" } } },
                { "fractal_sql_agent", { "/fractalsql/agent/sql_agent",
                    { "question", "table_names", "max_retries", "auto_execute" } } },
                { "fractal_agent_recall_hybrid", { "/fractalsql/agent/recall_hybrid",
                    { "mem_table", "vec_col", "query_vec", "filter_col", "filter_val", "k", "id_col", "content_col" } } },
                { "fractal_agent_recommend_diverse", { "/fractalsql/agent/recommend_diverse",
                    { "catalog_table", "emb_col", "query_vec", "k", "id_col" } } },
                { "fractal_agent_feedback_audit", { "/fractalsql/agent/feedback_audit",
                    { "catalog_table", "emb_col", "query_vec", "warmup_table", "warmup_vec_col", "warmup_count", "k" } } },
                { "fractal_search_agent", { "/fractalsql/agent/search_agent",
                    { "query", "table_name", "vector_col", "pop_size", "iterations" } } },
                { "fractal_rag_agent", { "/fractalsql/agent/rag_agent",
                    { "query", "table_name", "vector_col", "meta_filter" } } },
                { "fractal_agent_plan_explore", { "/fractalsql/agent/plan_explore",
                    { "initial_state", "strategy_table", "vector_col", "max_branches" } } },
                { "fractal_agent_trajectory_predict", { "/fractalsql/agent/trajectory_predict",
                    { "table_name", "vector_col", "baseline_id", "forecast_steps" } } },
                { "fractal_agent_detect_loop", { "/fractalsql/agent/detect_loop",
                    { "agent_id", "state_log", "dim", "n_bits", "seed", "hamming_threshold" } } },
                // The table-backed searches.
                { "fractal_search_telemetry", { "/fractalsql/search/telemetry", { "table", "column", "query", "k" } } },
                { "fractal_search_trajectory", { "/fractalsql/search/trajectory", { "table", "column", "baseline", "current", "k" } } },
                { "fractal_hybrid_clinical_search", { "/fractalsql/search/hybrid", { "table", "column", "query", "docIds", "k" } } },
                { "fractal_cross_modal_search", { "/fractalsql/search/cross-modal", { "table", "column", "morph", "clinical", "alpha", "k" } } },
                { "fractal_search_explore_table", { "/fractalsql/search/explore", { "datasource", "vectorColumn", "idColumn", "query", "k", "params" } } },
                // Text-to-SQL and the schema.
                { "fractal_text_to_sql", { "/fractalsql/text-to-sql", { "question", "tables" } } },
                // The multimodal portfolio family (enterprise-gated); the mode is the third name.
                { "fractal_optimize_portfolio_multimodal", { "/fractalsql/portfolio",
                    { "mu", "cov", "k", "n_restarts", "overlap_threshold", "quality_frac", "seed" } } },
                { "fractal_optimize_portfolio_multimodal_ex", { "/fractalsql/portfolio",
                    { "mu", "cov", "k", "n_restarts", "overlap_threshold", "quality_frac", "seed", "use_obl", "diffusion_mode" } } },
                { "fractal_optimize_portfolio_multimodal_pareto", { "/fractalsql/portfolio",
                    { "mu", "cov", "k", "n_restarts", "max_front", "seed", "use_obl", "diffusion_mode" } } },
                { "fractal_schema_context", { "/fractalsql/schema-context", {}, true } },
            };
            return t;
        }

        // Functions whose SQL result is a vector in the core's text form; the
        // adapters read these as the canonical packed blob.
        inline const std::set<std::string>& vectorResultFns()
        {
            static const std::set<std::string> s = {
                "fractal_vector", "fractal_vector_from_text", "fractal_vector_add", "fractal_vector_sub",
                "fractal_vector_scale", "fractal_vector_normalize", "fractal_vector_from_float8_array",
                "fractal_embed", "fractal_vector_quantize_binary" };
            return s;
        }
    }

    // ---------------------------------------------------------- connection

    class DbConnection
    {
    public:
        struct Config
        {
            std::string druidUrl;      // DRUID_URL: the router or broker (SQL API)
            std::string serviceUrl;    // DRUID_FRACTALSQL_URL: where /fractalsql is served (default: druidUrl)
            std::string user;          // DRUID_USER
            std::string password;      // DRUID_PASSWORD
            std::string token;         // DRUID_TOKEN (bearer)
            int         timeoutMs = 300000;
            bool        insecureTls = false;
            bool        agentPartialReasoningFail = true;
            bool        lockDestructive = false;
        };

        DbConnection() = default;
        DbConnection( const DbConnection& ) = delete;
        DbConnection& operator=( const DbConnection& ) = delete;

        void connect( const Config& cfg, const std::string& engineVersionExpected )
        {
            cfg_ = cfg;
            sql_ = druidhttp::parseUrl( cfg.druidUrl );
            svc_ = druidhttp::parseUrl( cfg.serviceUrl.empty() ? cfg.druidUrl : cfg.serviceUrl );
            if( !cfg.token.empty() ) auth_ = "Bearer " + cfg.token;
            else if( !cfg.user.empty() ) auth_ = "Basic " + druidhttp::base64( cfg.user + ":" + cfg.password );
            open_ = true;
            callScalar( "SELECT 1", {} );   // reachable and authorised
            if( cfg.lockDestructive ) applyDestructiveLatch();
            checkVersionSkew( engineVersionExpected );
        }

        void close() noexcept { open_ = false; }

        // The session name the daemon keys this connection's config overlay by.
        void setSession( const std::string& key ) { sessionKey_ = key; }

        SqlValue callScalar( const std::string& sql, const std::vector<SqlValue>& binds )
        {
            std::lock_guard<std::mutex> lk( mu_ );
            ensureOpen();
            const std::string fn = leadingFunction( sql );
            if( fn == "fractal_set_actor" )
                return nullptr;
            // The config functions take the session as their last argument.
            if( ( fn == "fractal_config_set" && binds.size() == 2 ) || ( fn == "fractal_config_get" && binds.size() == 1 ) )
            {
                std::vector<SqlValue> withSession = binds;
                withSession.push_back( sessionKey_ );
                std::vector<std::vector<SqlValue>> r = runSql( fn == "fractal_config_set"
                    ? "SELECT fractal_config_set(?, ?, ?)" : "SELECT fractal_config_get(?, ?)", withSession, false, nullptr );
                return r.empty() || r[ 0 ].empty() ? SqlValue( nullptr ) : r[ 0 ][ 0 ];
            }   // the actor is the authenticated Druid identity, never an argument
            if( fn == "fractal_search_explore" )
                return routeCall( "fractal_search_explore_table", binds );
            if( fn.rfind( "fractal_vectorizer_", 0 ) == 0 )
                return vectorizerCall( fn, binds );
            const auto it = druidroutes::table().find( fn );
            if( it != druidroutes::table().end() )
                return routeCall( fn, binds );
            if( fn == "fractal_ledger_verify" )
            {
                // kind 1 is the zero-argument SQL function; other kinds go through the extension.
                const double kind = binds.empty() ? 1.0 : numberOf( binds[ 0 ] );
                if( kind != 1.0 )
                {
                    const Json body{ { "action", "verify" }, { "kind", static_cast<std::int64_t>( kind ) } };
                    const druidhttp::Response r = druidhttp::request( svc_, "POST", "/fractalsql/ledger", body.dump(), auth_,
                                                                      cfg_.timeoutMs, cfg_.insecureTls );
                    if( r.status != 200 ) { warnServiceFallback( r.status ); throw httpError( r.status, r.body, "the ledger call" ); }
                    try { const Json j = Json::parse( r.body ); if( j.contains( "verify" ) ) return j.at( "verify" ).get<std::string>(); }
                    catch( ... ) {}
                    return r.body;
                }
                std::vector<std::vector<SqlValue>> rows = runSql( "SELECT fractal_ledger_verify()", {}, false, nullptr );
                return rows.empty() || rows[ 0 ].empty() ? SqlValue( nullptr ) : rows[ 0 ][ 0 ];
            }
            if( const auto adapted = adaptArity( fn, binds ) )
                return runAdapted( fn, *adapted );
            std::vector<std::vector<SqlValue>> rows = runSql( sql, binds, false, nullptr );
            if( rows.empty() || rows[ 0 ].empty() ) return nullptr;
            SqlValue v = rows[ 0 ][ 0 ];
            if( fn == "fractal_state_fingerprint" && std::holds_alternative<std::string>( v ) )
            {
                const std::string& hex = std::get<std::string>( v );
                std::vector<std::uint8_t> bytes;
                for( std::size_t i = 0; i + 1 < hex.size(); i += 2 )
                    bytes.push_back( static_cast<std::uint8_t>( std::stoi( hex.substr( i, 2 ), nullptr, 16 ) ) );
                return bytes;
            }
            if( druidroutes::vectorResultFns().count( fn ) && std::holds_alternative<std::string>( v ) )
            {
                const auto parsed = vecform::parseText( std::get<std::string>( v ) );
                if( parsed ) return vecform::pack( *parsed );
            }
            return v;
        }

        std::vector<std::vector<SqlValue>> queryAll( const std::string& sql, const std::vector<SqlValue>& binds )
        {
            std::lock_guard<std::mutex> lk( mu_ );
            ensureOpen();
            return runSql( sql, binds, false, nullptr );
        }

        std::vector<std::string> columnNames( const std::string& sql )
        {
            std::lock_guard<std::mutex> lk( mu_ );
            ensureOpen();
            std::vector<std::string> names;
            runSql( sql, {}, true, &names );
            return names;
        }

        void interrupt() {}   // an in-flight HTTP call ends when its socket times out
        bool probeAlive()
        { try { callScalar( "SELECT 1", {} ); return true; } catch( ... ) { return false; } }

        const std::vector<std::string>& startupWarnings() const { return warnings_; }

    private:
        void ensureOpen()
        {
            if( !open_ )
                throw ToolError( ErrorClass::Connectivity,
                                 "database connection is not open (closed or never connected)" );
        }

        // "SELECT fn(" -> fn, lowercased; empty when the statement is not that shape.
        static std::string leadingFunction( const std::string& sql )
        {
            std::size_t i = sql.find_first_not_of( " \t\r\n" );
            if( i == std::string::npos ) return "";
            auto lower = [&]( std::size_t from, std::size_t n ) {
                std::string s = sql.substr( from, n );
                for( char& c : s ) c = static_cast<char>( std::tolower( static_cast<unsigned char>( c ) ) );
                return s;
            };
            if( lower( i, 6 ) != "select" ) return "";
            i = sql.find_first_not_of( " \t\r\n", i + 6 );
            if( i == std::string::npos ) return "";
            std::size_t j = i;
            while( j < sql.size() && ( std::isalnum( static_cast<unsigned char>( sql[ j ] ) ) || sql[ j ] == '_' ) ) ++j;
            if( j == i || j >= sql.size() || sql[ j ] != '(' ) return "";
            return lower( i, j - i );
        }

        static Json bindToJson( const SqlValue& v )
        {
            if( std::holds_alternative<std::nullptr_t>( v ) ) return nullptr;
            if( std::holds_alternative<std::int64_t>( v ) ) return std::get<std::int64_t>( v );
            if( std::holds_alternative<double>( v ) ) return std::get<double>( v );
            if( std::holds_alternative<std::string>( v ) ) return std::get<std::string>( v );
            const auto text = vecform::unpackToText( std::get<std::vector<std::uint8_t>>( v ) );
            return text ? *text : std::string();
        }

        static Json paramFor( const SqlValue& v )
        {
            if( std::holds_alternative<std::nullptr_t>( v ) ) return Json{ { "type", "VARCHAR" }, { "value", nullptr } };
            if( std::holds_alternative<std::int64_t>( v ) ) return Json{ { "type", "BIGINT" }, { "value", std::get<std::int64_t>( v ) } };
            if( std::holds_alternative<double>( v ) ) return Json{ { "type", "DOUBLE" }, { "value", std::get<double>( v ) } };
            if( std::holds_alternative<std::string>( v ) ) return Json{ { "type", "VARCHAR" }, { "value", std::get<std::string>( v ) } };
            const auto text = vecform::unpackToText( std::get<std::vector<std::uint8_t>>( v ) );
            return Json{ { "type", "VARCHAR" }, { "value", text ? *text : std::string() } };
        }

        static SqlValue cellToValue( const Json& c )
        {
            if( c.is_null() ) return nullptr;
            if( c.is_boolean() ) return static_cast<std::int64_t>( c.get<bool>() ? 1 : 0 );
            if( c.is_number_integer() ) return static_cast<std::int64_t>( c.get<std::int64_t>() );
            if( c.is_number() )
            {
                const double d = c.get<double>();
                return std::isfinite( d ) ? SqlValue( d ) : SqlValue( nullptr );
            }
            if( c.is_string() ) return c.get<std::string>();
            return c.dump();
        }

        // The extension's /fractalsql endpoints are served by the nodes that load it (a broker). When
        // DRUID_FRACTALSQL_URL is unset the calls go to DRUID_URL, and a router does not serve them: warn
        // when such a call comes back 404 or 405, at most once an hour so a long-running HTTP deployment
        // does not lose the warning to a log tail that started later.
        void warnServiceFallback( int status ) const
        {
            if( ( status != 404 && status != 405 ) || !( cfg_.serviceUrl.empty() || cfg_.serviceUrl == cfg_.druidUrl ) ) return;
            static std::atomic<long long> lastWarn{ 0 };
            const long long now = std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::steady_clock::now().time_since_epoch() ).count() + 1;
            long long prev = lastWarn.load();
            if( prev != 0 && now - prev < 3600 ) return;
            if( !lastWarn.compare_exchange_strong( prev, now ) ) return;
            std::cerr << "WARN: an extension call to " << cfg_.druidUrl << " returned " << status
                      << "; DRUID_URL may be a router that does not serve /fractalsql. Set DRUID_FRACTALSQL_URL "
                         "to a broker (for example http://localhost:8082)\n";
        }

        ToolError httpError( int status, const std::string& body, const char* what ) const
        {
            std::string msg = std::string( what ) + " failed (HTTP " + std::to_string( status ) + ")";
            try
            {
                const Json j = Json::parse( body );
                if( j.is_object() )
                {
                    if( j.contains( "errorMessage" ) ) msg = j.at( "errorMessage" ).get<std::string>();
                    else if( j.contains( "error" ) && j.at( "error" ).is_string() ) msg = j.at( "error" ).get<std::string>();
                    else if( j.contains( "message" ) && j.at( "message" ).is_string() ) msg = j.at( "message" ).get<std::string>();
                }
            }
            catch( ... ) { if( !body.empty() && body.size() < 400 ) msg += ": " + body; }
            if( status == 401 || status == 403 || status >= 502 )
                return ToolError( ErrorClass::Connectivity, sanitizeSecrets( msg ) );
            return ToolError( ErrorClass::Engine, sanitizeSecrets( msg ) );
        }

        std::vector<std::vector<SqlValue>> runSql( const std::string& sql, const std::vector<SqlValue>& binds,
                                                   bool header, std::vector<std::string>* namesOut )
        {
            Json body{ { "query", sql }, { "resultFormat", "array" }, { "header", header },
                       { "context", Json{ { "sqlTimeZone", "UTC" } } } };
            if( !binds.empty() )
            {
                Json params = Json::array();
                for( const SqlValue& b : binds ) params.push_back( paramFor( b ) );
                body[ "parameters" ] = params;
            }
            const druidhttp::Response r = druidhttp::request( sql_, "POST", "/druid/v2/sql", body.dump(), auth_,
                                                              cfg_.timeoutMs, cfg_.insecureTls );
            if( r.status != 200 ) throw httpError( r.status, r.body, "the Druid SQL call" );
            Json rows;
            try { rows = Json::parse( r.body ); }
            catch( ... ) { throw ToolError( ErrorClass::Connectivity, "Druid returned a result that is not JSON" ); }
            std::vector<std::vector<SqlValue>> out;
            std::size_t first = 0;
            if( header && rows.is_array() && !rows.empty() && rows[ 0 ].is_array() && namesOut )
            {
                for( const Json& n : rows[ 0 ] ) namesOut->push_back( n.is_string() ? n.get<std::string>() : n.dump() );
                first = 1;
            }
            if( !rows.is_array() ) return out;
            for( std::size_t i = first; i < rows.size(); ++i )
            {
                std::vector<SqlValue> row;
                for( const Json& c : rows[ i ] ) row.push_back( cellToValue( c ) );
                out.push_back( std::move( row ) );
            }
            return out;
        }

        // ------------------------------------------------------------------
        // Calls whose Druid function takes fewer trailing arguments than the
        // standard tool passes. An argument Druid has no slot for is either
        // enforced at its default (a different value is refused, never
        // silently ignored) or applied to the result here.
        struct Adapted
        {
            std::string sql;                       // the Druid statement
            std::vector<SqlValue> binds;           // its binds
            std::string trimKey;                   // result field to limit, or empty
            std::int64_t trimTo = -1;              // the limit
        };

        static double numberOf( const SqlValue& v )
        {
            if( std::holds_alternative<std::int64_t>( v ) ) return static_cast<double>( std::get<std::int64_t>( v ) );
            if( std::holds_alternative<double>( v ) ) return std::get<double>( v );
            return std::nan( "" );
        }

        // A bound that must be a finite number, as an integer: casting NaN or an out-of-range double to int64 is undefined
        // behaviour, and a string bound to a limit parameter used to reach it (SECURITY_AUDIT.md 3.20).
        static std::int64_t intOf( const SqlValue& v, const char* what )
        {
            const double n = numberOf( v );
            if( !std::isfinite( n ) || n < -9.0e18 || n > 9.0e18 )
                throw ToolError( ErrorClass::Schema, std::string( what ) + " must be a number" );
            return static_cast<std::int64_t>( n );
        }

        static void enforceDefault( const char* what, const SqlValue& v, double fixed )
        {
            const double n = numberOf( v );
            if( !std::isnan( n ) && n != fixed )
                throw ToolError( ErrorClass::Schema, std::string( what ) + " is fixed at " +
                                 std::to_string( static_cast<long long>( fixed ) ) + " on this engine" );
        }

        static std::string placeholders( std::size_t n )
        {
            std::string s;
            for( std::size_t i = 0; i < n; ++i ) s += i ? ", ?" : "?";
            return s;
        }

        static std::optional<Adapted> adaptArity( const std::string& fn, const std::vector<SqlValue>& b )
        {
            Adapted a;
            if( fn == "fractal_tda_persistence_diagram" && b.size() == 5 )
            {
                enforceDefault( "max_h0_bars", b[ 4 ], 64 );
                a.binds.assign( b.begin(), b.begin() + 4 );
            }
            else if( fn == "fractal_state_fingerprint" && b.size() == 3 )
            {
                enforceDefault( "seed", b[ 2 ], 0 );
                a.binds.assign( b.begin(), b.begin() + 2 );
            }
            else if( fn == "fractal_periodogram" && b.size() == 2 )
            {
                a.binds.assign( b.begin(), b.begin() + 1 );
                a.trimKey = "freqs"; a.trimTo = intOf( b[ 1 ], "freqs" );
            }
            else if( fn == "fractal_change_point_detect" && b.size() == 4 )
            {
                a.binds.assign( b.begin(), b.begin() + 3 );
                a.trimKey = "indices"; a.trimTo = intOf( b[ 3 ], "indices" );
            }
            else if( fn == "fractal_spectrogram_entropy" && b.size() == 4 )
            {
                a.binds.assign( b.begin(), b.begin() + 3 );
                a.trimKey = "entropy"; a.trimTo = intOf( b[ 3 ], "entropy" );
            }
            else if( fn == "fractal_optimize_portfolio" && b.size() == 6 )
            {
                // (mu, cov, k, seed, use_obl, diffusion_mode) -> the extended form (mu, cov, k, use_obl, diffusion)
                enforceDefault( "seed", b[ 3 ], 0 );
                const bool levy = std::holds_alternative<std::string>( b[ 5 ] ) && std::get<std::string>( b[ 5 ] ) == "levy";
                a.binds = { b[ 0 ], b[ 1 ], b[ 2 ], b[ 4 ], static_cast<std::int64_t>( levy ? 1 : 0 ) };
                a.sql = "SELECT fractal_optimize_portfolio_ex(" + placeholders( 5 ) + ")";
                return a;
            }
            else if( fn == "fractal_feedback_report" && b.size() == 2 )
            {
                a.binds = { b[ 0 ], b[ 1 ], static_cast<std::int64_t>( 0 ) };
            }
            else return std::nullopt;
            a.sql = "SELECT " + fn + "(" + placeholders( a.binds.size() ) + ")";
            return a;
        }

        SqlValue runAdapted( const std::string& fn, const Adapted& a )
        {
            std::vector<std::vector<SqlValue>> rows = runSql( a.sql, a.binds, false, nullptr );
            if( rows.empty() || rows[ 0 ].empty() ) return nullptr;
            SqlValue v = rows[ 0 ][ 0 ];
            if( !a.trimKey.empty() && a.trimTo > 0 && std::holds_alternative<std::string>( v ) )
            {
                try
                {
                    Json doc = Json::parse( std::get<std::string>( v ) );
                    for( const char* key : { "freqs", "power", "indices", "entropy" } )
                        if( doc.is_object() && doc.contains( key ) && doc[ key ].is_array()
                            && static_cast<std::int64_t>( doc[ key ].size() ) > a.trimTo
                            && ( a.trimKey == key || ( a.trimKey == "freqs" && std::string( key ) == "power" ) ) )
                            doc[ key ] = Json( std::vector<Json>( doc[ key ].begin(), doc[ key ].begin() + a.trimTo ) );
                    return doc.dump();
                }
                catch( ... ) {}
            }
            if( fn == "fractal_state_fingerprint" && std::holds_alternative<std::string>( v ) )
            {
                const std::string& hex = std::get<std::string>( v );
                std::vector<std::uint8_t> bytes;
                for( std::size_t i = 0; i + 1 < hex.size(); i += 2 )
                    bytes.push_back( static_cast<std::uint8_t>( std::stoi( hex.substr( i, 2 ), nullptr, 16 ) ) );
                return bytes;
            }
            return v;
        }

        // A call the extension serves as an endpoint.
        SqlValue routeCall( const std::string& fn, const std::vector<SqlValue>& binds )
        {
            const druidroutes::Route& route = druidroutes::table().at( fn );
            Json body = Json::object();
            for( std::size_t i = 0; i < binds.size() && i < route.names.size(); ++i )
            {
                if( std::holds_alternative<std::nullptr_t>( binds[ i ] ) ) continue;
                body[ route.names[ i ] ] = bindToJson( binds[ i ] );
            }
            // A cohort travels as a JSON array of ids.
            if( fn == "fractal_hybrid_clinical_search" && body.contains( "docIds" ) && body[ "docIds" ].is_string() )
            {
                try { body[ "docIds" ] = Json::parse( body[ "docIds" ].get<std::string>() ); } catch( ... ) {}
            }
            if( ( fn == "fractal_agent_data_analyst" || fn == "fractal_sql_agent" ) && body.contains( "auto_execute" ) )
                body[ "auto_execute" ] = body[ "auto_execute" ].is_number() ? Json( body[ "auto_execute" ].get<std::int64_t>() != 0 ) : body[ "auto_execute" ];
            if( fn == "fractal_optimize_portfolio_multimodal" ) body[ "mode" ] = "multimodal";
            if( fn == "fractal_optimize_portfolio_multimodal_ex" ) body[ "mode" ] = "ex";
            if( fn == "fractal_optimize_portfolio_multimodal_pareto" ) body[ "mode" ] = "pareto";
            body[ "partial" ] = cfg_.agentPartialReasoningFail;
            const druidhttp::Response r = druidhttp::request( svc_, route.get ? "GET" : "POST", route.path,
                                                              route.get ? "" : body.dump(), auth_,
                                                              cfg_.timeoutMs, cfg_.insecureTls );
            if( r.status != 200 ) { warnServiceFallback( r.status ); throw httpError( r.status, r.body, "the extension call" ); }
            return r.body;
        }

        // The vectorizer is one endpoint with an action.
        SqlValue vectorizerCall( const std::string& fn, const std::vector<SqlValue>& binds )
        {
            Json body = Json::object();
            if( fn == "fractal_vectorizer_create" )
            {
                body = Json{ { "action", "create" }, { "source_table", bindToJson( binds.at( 0 ) ) },
                             { "source_column", bindToJson( binds.at( 1 ) ) },
                             { "embedding_column", bindToJson( binds.at( 2 ) ) } };
                if( binds.size() > 3 && std::holds_alternative<std::string>( binds[ 3 ] ) )
                {
                    try
                    {
                        Json opts = Json::parse( std::get<std::string>( binds[ 3 ] ) );
                        if( opts.is_object() )
                        {
                            if( opts.contains( "id_col" ) ) { body[ "id_column" ] = opts[ "id_col" ]; opts.erase( "id_col" ); }
                            body[ "options" ] = opts;
                        }
                    }
                    catch( ... ) {}
                }
                if( !body.contains( "id_column" ) ) body[ "id_column" ] = "id";
            }
            else if( fn == "fractal_vectorizer_process_queue" )
                body = Json{ { "action", "process_queue" }, { "batch_size", bindToJson( binds.at( 0 ) ) } };
            else
            {
                const std::string action = fn.substr( std::strlen( "fractal_vectorizer_" ) );
                body = Json{ { "action", action }, { "id", bindToJson( binds.at( 0 ) ) } };
            }
            const druidhttp::Response r = druidhttp::request( svc_, "POST", "/fractalsql/vectorizer", body.dump(), auth_,
                                                              cfg_.timeoutMs, cfg_.insecureTls );
            if( r.status != 200 ) { warnServiceFallback( r.status ); throw httpError( r.status, r.body, "the vectorizer call" ); }
            return r.body;
        }

        void applyDestructiveLatch()
        {
            try { runSql( "SELECT FRACTAL_LOCK_DESTRUCTIVE(?)", { static_cast<std::int64_t>( 1 ) }, false, nullptr ); }
            catch( const std::exception& e )
            {
                warnings_.push_back( std::string(
                    "FSQL_MCP_READ_ONLY: the daemon's destructive latch was not applied "
                    "(server-side refusal still active): " ) + e.what() );
                logging::event( "startup_warning", Json{ { "note", warnings_.back() } } );
            }
            catch( ... ) {}
        }

        void checkVersionSkew( const std::string& engineVersionExpected )
        {
            try
            {
                const auto rows = runSql( "SELECT FRACTAL_VERSION()", {}, false, nullptr );
                if( !rows.empty() && !rows[ 0 ].empty() )
                {
                    const auto t = asText( rows[ 0 ][ 0 ] );
                    if( t && *t != engineVersionExpected )
                    {
                        warnings_.push_back( "version skew: the extension reports " + *t +
                                             ", plugin built against " + engineVersionExpected );
                        logging::event( "startup_warning", Json{
                            { "note", warnings_.back() },
                            { "action", "warn-not-fail: the SQL surface is stable across the compat matrix" } } );
                    }
                }
            }
            catch( ... ) { /* non-fatal */ }
        }

        Config cfg_;
        druidhttp::Url sql_;
        druidhttp::Url svc_;
        std::string auth_;
        std::string sessionKey_ = "stdio";
        bool open_ = false;
        std::mutex mu_;
        std::vector<std::string> warnings_;
    };

    // Session -> dedicated connection registry. Over stdio there is exactly
    // one session ("stdio"); the HTTP transport gets one per Mcp-Session-Id.
    class Db
    {
    public:
        using ConnectConfig = DbConnection::Config;

        void configure( ConnectConfig cfg ) { cfg_ = std::move( cfg ); }

        ~Db() { closeAll(); }

        static void selectSession( const std::string& key ) { t_sessionKey() = key; }

        void closeSession( const std::string& key )
        {
            std::lock_guard<std::mutex> lk( regMu_ );
            connections_.erase( key );
        }
        void closeAll()
        {
            std::lock_guard<std::mutex> lk( regMu_ );
            connections_.clear();
        }

        bool probeAlive( const std::string& key )
        {
            return withConnection( key, []( DbConnection& c ) { return c.probeAlive(); } );
        }
        void interrupt( const std::string& key )
        {
            std::lock_guard<std::mutex> lk( regMu_ );
            auto it = connections_.find( key );
            if( it != connections_.end() )
                it->second->interrupt();
        }

        std::vector<std::string> sessionKeys()
        {
            std::lock_guard<std::mutex> lk( regMu_ );
            std::vector<std::string> out;
            for( const auto& kv : connections_ ) out.push_back( kv.first );
            return out;
        }

        SqlValue callScalar( const std::string& sql, const std::vector<SqlValue>& binds )
        { return acquire( t_sessionKey() )->callScalar( sql, binds ); }

        std::vector<std::vector<SqlValue>> queryAll( const std::string& sql,
                                                     const std::vector<SqlValue>& binds )
        { return acquire( t_sessionKey() )->queryAll( sql, binds ); }

        std::vector<std::string> columnNames( const std::string& sql )
        { return acquire( t_sessionKey() )->columnNames( sql ); }

        std::vector<std::string> startupWarnings()
        { return acquire( t_sessionKey() )->startupWarnings(); }

        // A readiness probe answers "not ready" when the engine cannot be reached; acquiring the connection can itself throw
        // (a bad URL, the concurrency limit), and an exception here would drop the probe's socket with no HTTP answer at all.
        bool probeAlive()
        { try { return acquire( t_sessionKey() )->probeAlive(); } catch( ... ) { return false; } }

    private:
        template<typename F>
        auto withConnection( const std::string& key, F f )
        -> decltype( f( *static_cast<DbConnection*>( nullptr ) ) )
        {
            std::shared_ptr<DbConnection> c = acquire( key );
            return f( *c );
        }

        static std::string& t_sessionKey()
        {
            thread_local std::string key = "stdio";
            return key;
        }

        std::shared_ptr<DbConnection> acquire( const std::string& key )
        {
            {
                std::lock_guard<std::mutex> lk( regMu_ );
                auto it = connections_.find( key );
                if( it != connections_.end() ) return it->second;
            }
            // The connect is blocking network I/O (up to the connect timeout): done outside the registry lock, so a slow
            // Druid for one session does not stall every other session's lookup (SECURITY_AUDIT.md 3.10).
            auto c = std::make_shared<DbConnection>();
            c->setSession( key );
            c->connect( cfg_, kEngineVersionExpect );
            {
                std::lock_guard<std::mutex> lk( regMu_ );
                auto it = connections_.find( key );
                if( it != connections_.end() ) return it->second;   // another thread of the same session won the race
                connections_[ key ] = c;
            }
            for( const std::string& w : c->startupWarnings() )
                logging::event( "session_startup_warning", Json{ { "session", key }, { "note", w } } );
            return c;
        }

        ConnectConfig cfg_;
        std::mutex regMu_;
        std::map<std::string, std::shared_ptr<DbConnection>> connections_;
    };
}
