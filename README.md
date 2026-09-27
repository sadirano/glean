# glean

glean is a Zig 0.16 fuzzy picker library with fzf-style queries, for programs
that want a picker without calling an external one. It reads all input rows
before opening the picker.

## Library

Declare the package in the consumer's `build.zig.zon` (supply its package URL
and Zig hash):

```zig
.dependencies = .{
    .glean = .{ .url = "<package-url>", .hash = "<zig-hash>" },
},
```

Add the module to the consumer's executable in `build.zig`:

```zig
exe.root_module.addImport("glean", b.dependency("glean", .{}).module("glean"));
```

With `const glean = @import("glean");`, an allocator named `arena`, and a row
handler in scope:

```zig
const rows = [_][]const u8{ "one", "two" };
const result = try glean.pick.pick(arena, &rows, .{});
switch (result) {
    .picked => |indices| for (indices) |index| handle(rows[index]),
    .cancelled, .no_console => {},
}
```

The returned indices refer to the original rows. Pass `Options.colors` to
apply `--color=` words over the built-in palette.

## Trying it by hand

The repo builds `glean.exe`, a test harness for the library. It is not meant
to be installed; for a general command-line picker, use fzf.

```text
glean [--multi] [--prompt TEXT] [--header-lines N] [--delimiter C] [--with-nth N..] [FILE]
```

Without FILE, glean reads stdin to EOF. The picker uses the Windows console,
so redirected stdin and stdout work. Selected rows go to stdout, one per line.
`--delimiter "\t"` selects a tab. `--with-nth N..` searches and displays fields
from N onward. `FZF_DEFAULT_OPTS` supplies color overrides. Exit codes are 0
for a selection, 1 for no rows or matches, 130 for cancellation, and 2 for a
usage error or unavailable console.

Queries use fuzzy subsequences by default. Separate terms with spaces for AND,
or put `|` between terms for OR. Prefix a term with `'` for an exact substring,
`^` for a start match, or `!` to exclude a match; `$` marks an end match and
`^term$` matches a whole row. Backslash escapes a space. Matching uses smart
case: an uppercase ASCII letter makes its term case sensitive.

Type to search. Up/Down (also Ctrl-K/Ctrl-J and Ctrl-P/Ctrl-N) move through the
results; Page Up/Down move a page. Enter accepts. Esc, Ctrl-C, and Ctrl-G
cancel. In multi mode, Tab and Shift-Tab toggle a row and move. Left/Right,
Home/End, and Ctrl-A/Ctrl-E move within the query. Backspace or Ctrl-H deletes
one character; Ctrl-U clears the query and Ctrl-W deletes a word.

The matcher follows fzf by Junegunn Choi; see NOTICE for credit.
