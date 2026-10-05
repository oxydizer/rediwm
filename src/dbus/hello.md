`hello.bin` is a complete little-endian Hello METHOD_CALL captured on
2026-09-13 from `busctl --user list`, observed by `busctl --user capture`
on a fresh `dbus-run-session` bus. It includes the bus-added sender `:1.1`.
It is 144 bytes: 16 fixed bytes, 125 header-field bytes, 3 padding bytes,
and no body. No host bus traffic was captured.

To reproduce, start `busctl --user capture > hello.pcapng` in a private bus,
wait until the monitor is registered, run `busctl --user list`, and stop the
capture. Extract the Enhanced Packet Block whose packet contains `Hello\0`:
the captured packet length is the uint32 at block offset 20, and packet data
starts at offset 28. The unit test both decodes and reproduces these exact bytes.
