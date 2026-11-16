// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
//
// Unit test for the vector wire format in src/db.h (vecform): the dimension field is 16 bits, so a longer vector must be
// refused with a message that names the limit and never written with a truncated length (SECURITY_AUDIT.md 3.19).
#include "../src/db.h"

#include <cstdio>

using namespace fsqlmcp;

static int failed = 0;
static void check( const char* label, bool cond )
{
    std::printf( "%s %s\n", cond ? "OK:" : "FAIL:", label );
    if( !cond ) failed = 1;
}

int main()
{
    {
        const std::vector<float> v( 65535, 0.5f );
        const auto b = vecform::pack( v );
        check( "65535 dimensions pack", b.size() == 4 + 4 * 65535u );
        check( "the length field reads 0xffff", b[ 0 ] == 0xff && b[ 1 ] == 0xff );
        const auto back = vecform::unpackToText( b );
        check( "and unpacks", back.has_value() );
    }
    {
        bool refused = false, named = false;
        try { vecform::pack( std::vector<float>( 70000, 0.5f ) ); }
        catch( const ToolError& e )
        {
            refused = e.errorClass == ErrorClass::Schema;
            named = std::string( e.what() ).find( "65535" ) != std::string::npos;
        }
        check( "70000 dimensions are refused as a schema error", refused );
        check( "the refusal names the limit", named );
    }
    {
        const std::vector<float> small{ 1.0f, 2.0f, 3.0f };
        const auto b = vecform::pack( small );
        const auto t = vecform::unpackToText( b );
        check( "a small vector round-trips", t.has_value() && t->find( '1' ) != std::string::npos );
    }
    return failed;
}
