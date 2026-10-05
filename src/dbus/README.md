# D-Bus transport

Import `dbus/mod.zig` from a consumer under `src/`. This is an opt-in module:
importing it does not open a connection or claim a name. Consumers such as
notifications choose their own startup policy. No new C library is
required; the module uses libc and the existing Wayland event loop.

1. `Connection.openSession(allocator, loop, environ)` reads the explicit
   `DBUS_SESSION_BUS_ADDRESS` via `std.process.Environ`. `openSystem` reads
   `DBUS_SYSTEM_BUS_ADDRESS`, defaulting to
   `unix:path=/var/run/dbus/system_bus_socket`. Tests override it with a private
   bus address. `open` instead takes an address string.
   Unix path and Linux abstract alternatives are tried in order. Connection
   and EXTERNAL authentication share a two-second deadline per alternative;
   a supplied GUID must match. The fd stays nonblocking throughout; startup
   waits use `poll`, while subsequent traffic uses `wl.EventLoop.addFd`.
2. Call `hello(owner, callback)` once. On a successful callback,
   `connection.unique_name` is available and ordinary calls are permitted.
   `requestName(name, flags, owner, callback)` returns the bus's `u` result
   unchanged; the consumer chooses ownership/contending-name policy.
3. Construct arguments in a `wire.Writer{ .allocator = allocator }`, then
   pass its address and the signature to `call`. Calls copy their encoded
   arguments into the write queue, so the writer can immediately be freed.
   The callback gets either a borrowed `wire.Message` (including D-Bus ERROR
   messages) or a local `Failure` such as timeout/disconnect. Timeout is in
   milliseconds; the timer wakes for the earliest pending deadline and disarms
   when idle. At most 256 calls may be pending.
4. `register` installs a handler for path/interface/member. Its strings and
   owner must outlive their registration. Read `message.body` through a local
   reader copy after checking `message.headers.signature`, then use `reply`
   or `replyError`. Incoming bodies are already structurally validated.
   `unregisterMethodsByOwner(owner)` removes method handlers for temporary
   request objects before their owner or path storage is freed.
   `signal` emits a path/interface/member message. No-reply calls suppress
   both success and error replies. Unknown methods receive `UnknownMethod`;
   handler errors become `InvalidArgs`. A handler that replies must return
   success to avoid a second error reply.
   Returning successfully without replying sends nothing; this is the supported
   deferred-reply path. Call `deferReply(message)` inside the handler to own a
   `Connection.Deferred` containing the serial and a copied sender. It does not
   retain the body or any other borrowed slices. Return success after deferring.
   Later, `replyDeferred(&deferred, signature, &body)` or
   `replyErrorDeferred(&deferred, name, description)` sends and releases the
   handle. Both suppress output for no-reply calls. On a send failure, the
   handle remains owned so it can be retried or released explicitly.
   Treat handles as move-only and use only their originating connection.
   `releaseDeferred(&deferred)` abandons without sending and is idempotent;
   replying through an already consumed handle fails with `InvalidRequest`.
   `registerSignal` installs a signal handler matching on optional `sender`,
   `path`, `interface`, and `member`. Multiple matching handlers can be installed.
   `unregisterSignal` and `unregisterSignalsByOwner` remove handlers.
   `addMatch(rule, owner, callback)` and `removeMatch(rule, owner, callback)` issue
   bus match rules (`callback` can be null for fire-and-forget). `subscribe(handler, owner, callback)`
   and `unsubscribe(handler, owner, callback)` format the signal match rule and
   register/unregister the handler and match rule in one step. Incoming signals are
   dispatched to all matching handlers.
5. `close` removes sources, closes the fd and completes all pending calls
   exactly once with `Disconnected`; it is idempotent. `destroy` additionally
   frees the object. Both must run before the Wayland event loop is destroyed.
   Callbacks may close the connection or enqueue new messages. They may not
   destroy it or recursively dispatch the loop. All message slices expire
   when the callback returns; copy any values needed later.
   Closing invalidates every deferred reply (`Disconnected` on a later send).
   Consumers must abandon every outstanding deferred reply on close: cancel
   their delayed work and call `releaseDeferred` before `destroy`. Handles are
   caller-owned, so close does not free their copied sender storage for them.
   `flush` attempts one nonblocking write without dispatching callbacks. This
   allows best-effort shutdown messages before close, but does not guarantee
   delivery if the socket is backpressured or only accepts a partial write.
   An optional `on_disconnect` hook runs exactly once after pending calls are
   completed, while the connection remains alive. It may cancel consumer work
   and release deferred handles, but must not destroy the connection or dispatch.

Writers expose `byte`, `int(T, value)`, `uint32`, `boolean`, `double`, `string`,
`objectPath`, `signature`, `alignTo`, `variant`, `beginArray` and `endArray`.
After `variant(sig)` write one value; pair each `beginArray(element_alignment)`
with `endArray(token)`. Begin structs/dict entries with `alignTo(8)`. Body
writers start at offset zero, equivalent to the message's 8-aligned body
origin. Readers returned by `array` retain absolute offsets and bound their
view at the array end. `done` checks that the complete value was consumed.
Outgoing messages are also decoded/validated before entering the queue.

The codec enforces the specification's 128 MiB message and 64 MiB array
limits, zero padding/terminators, UTF-8, signature grammar/depth, header types,
required fields, names, and exact body consumption. The connection separately
caps queued output at 8 MiB. Malformed input closes the connection and logs
an error; it is never passed to a handler. `openSystemWithFds` opts into Unix
descriptor negotiation and reception (up to 16 descriptors per message).
Received descriptors are borrowed during dispatch and closed afterward; duplicate
one if it must outlive the callback. Sending descriptors remains unsupported.
There is no automatic introspection, reconnect, or bus activation fallback.
Authentication supports EXTERNAL only.

See [TESTING.md](../../TESTING.md) for `zig build test-dbus`, and
[hello.md](hello.md) for the real wire fixture's provenance.
