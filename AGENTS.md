# Contributor guide

Use Zig 0.16. Build the test harness `glean.exe` with `zig build` (exported to
`~/.nix/bin` for hand testing only: the library is the product) and run unit tests with
`zig build test`. Run `zig build ci` before handing off a change; it checks
formatting, tests, the host executable, and Linux compilation.

Keep the package dependency free. Windows console behavior is the primary
runtime target; preserve the x86_64-linux compile. Keep source and output
ASCII except for the glyph table in `src/pick.zig`. Those glyphs are written
through WriteConsoleW as UTF-16, so they bypass legacy console code pages.

Comments explain decisions, not mechanics. Keep each file under 900 lines.
Use relative repo paths and nix aliases for locations in scripts and saved
state. The nix project is the first consumer of this library; note API changes
in the commit message.
