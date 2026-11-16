// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
// Platform socket shim for the optional HTTP transport: the only file in
// mcp/src that touches the POSIX socket headers. Deliberately includes NO
// standard-heavy header (notably nothing JSON): an isolating boundary. The
// HTTP transport sees sockets only through this interface.
#include <cstdint>
#include <string>

namespace fsqlmcp::net
{
    // Opaque, no-include socket handles (an int descriptor on POSIX); kept
    // typeless here so no TU besides the .cpp needs the platform headers.
    using Socket = void*;
    Socket invalidSocket();
    bool isInvalid( Socket s );

    // The underlying file descriptor as an intptr_t, exposed ONLY so the
    // optional direct-TLS mode can hand it to OpenSSL's SSL_set_fd(), which
    // takes a plain int. No other caller needs this; the plaintext path
    // never leaves this header's Socket abstraction.
    std::intptr_t rawHandle( Socket s );

    void init();          // no-op on POSIX
    void shutdownNet();   // no-op on POSIX

    // Returns invalidSocket() + a human-readable reason on failure.
    Socket listenTcp( const std::string& host, int port, std::string& errOut );

    // True when a connection is waiting, false after `ms` with none (or on a
    // signal). A signal handler installed with std::signal restarts a blocked
    // accept(), so the accept loop waits here in short slices instead.
    bool waitForConnection( Socket listenSock, int ms );
    Socket accept( Socket listenSock );     // invalidSocket() when the listener has stopped
    void stopListening( Socket listenSock );// shutdown(both); wakes a blocked accept()
    int  recv( Socket s, char* buf, int len );   // <=0 => closed/error (caller continues)
    int  send( Socket s, const char* buf, int len ); // <=0 => failed
    void close( Socket s );
    // Closes after a refusal reply: half-closes, reads and discards the
    // client's pending request for up to lingerMs, then closes. A plain close
    // with unread data resets the connection, and the reset discards the
    // reply that was just written -- the peer then sees a broken connection
    // instead of the refusal it was owed.
    void closeAfterReply( Socket s, int lingerMs );
}