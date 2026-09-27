# glean

glean is a Zig 0.16 fuzzy picker library with fzf-style queries, for programs
that want a picker without calling an external one. It supports both a supplied
list of rows and feeds that stream rows while the picker is open.

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
`Options.ansi`, like fzf's `--ansi`, draws the SGR colors a row carries while
matching, previewing and returning it without them.

## Streaming rows

`glean.stream.pickFeed(arena, io, feed, opts)` shows rows while they arrive and
returns the picked rows as text. A `Feed` takes its rows from a child process
(`.command`, its stdout lines), this process's stdin (`.stdin`), or a function
that pushes rows itself (`.callback`, e.g. a directory walker; stop when
`sink.push` returns false). `filter` drops or rewrites lines, `max_rows` stops
the source after that many kept rows, and `collect` runs a feed with no UI.

## Preview

`Options.preview` takes a `Previewer`: a function called on a worker thread
with the current row, returning `PreviewText` (SGR colours pass through; an
optional `focus_line` is scrolled into view and marked). A slow preview never
blocks typing, and stale results are dropped. Two ready-made previewers:
`commandPreviewer` runs a command with `{}` replaced by the row (e.g. `bat`),
killed after a timeout; `textPreview` needs no tool - numbered lines from the
head of a text file, "(binary file)", or a directory's entries.
Shift-Up/Shift-Down scroll the pane.

## Trying it by hand

Run `zig build` to build `zig-out/bin/glean.exe`, a test harness for the library.
For contributors using the nix project runner, `x glean :build` also exports
the harness through `~/.nix/bin`. It is not a replacement for fzf as a general
command-line picker.

```text
glean [--multi] [--ansi] [--prompt TEXT] [--header-lines N] [--delimiter C] [--with-nth N..] [--filter QUERY] [--max-rows N] [--preview CMD] [--preview-window up:N%[:wrap]] [--preview-text] [FILE | -- COMMAND...]
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
cancel. In multi mode, Tab and Shift-Tab toggle a row and move down or up, and the
info line counts the marked rows. Left/Right,
Home/End, and Ctrl-A/Ctrl-E move within the query. Backspace or Ctrl-H deletes
one character; Ctrl-U clears the query and Ctrl-W deletes a word.

glean follows fzf by Junegunn Choi; see NOTICE for attribution and its MIT license.


### Preview command templates

The harness `--preview` option runs an executable directly on both Windows
and Linux. The template is split into arguments once, before receiving rows.
Whitespace separates arguments; single or double quotes group text and are
removed. Backslashes are literal, so Windows paths need no extra escaping.
A whole argument equal to `{}` receives the complete row as one literal
argument, including spaces, quotes, and shell metacharacters. Embedded `{}`
placeholders and unclosed quotes are rejected. The executable must be fixed.
For example, `--preview 'my-viewer -- {}'` passes each row to `my-viewer`.

Shell builtins, pipelines, redirection, and variable expansion are not part
of this grammar. Replace earlier shell-style preview examples with an
executable and separate arguments. Explicitly invoking a shell or interpreter
with a row in its code argument transfers responsibility for evaluating that
row to the caller. The library's existing `shell_quote` mode remains a legacy,
unsafe option for untrusted rows; the harness does not enable it.

### Producer and preview shutdown

Stopping a command feed kills and reaps its direct child even after stdout
has closed. Natural EOF allows a short exit grace period before killing it.
Command previews keep their timeout active through process reaping.

These guarantees cover direct children. Producer and preview descendants must
not keep inherited stdout handles open after their parent exits. Glean does
not create Windows Job Objects or process groups, so such descendants can
still hold a reader open. Race-free Job assignment needs child creation in a
suspended state before assigning the job and resuming execution; assigning
a job after ordinary spawn would leave an escape window.

Source callbacks must return promptly when `Sink.push` returns false. Preview
callbacks must return promptly when superseded or on shutdown; their context
must arrange cancellation for blocking work because the callback API has no
stop-token argument. Glean joins these callbacks. Windows stdin cancellation
retries until the reader acknowledges completion. Blocking stdin cancellation
on non-Windows systems remains unsupported.
