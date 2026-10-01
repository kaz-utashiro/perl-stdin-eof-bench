# perl-stdin-eof-bench

A child created by `open(FH, '|-')` cannot read its STDIN if the parent
had already read its own STDIN to the end.  The child's STDIN is the
pipe, but the EOF condition set before the fork is still in effect, so
the child reads nothing:

```perl
$_ = do { local $/; <STDIN> };          # parent reads to EOF
if (open(CHLD, '|-') == 0) {
    print <STDIN>;                      # reads nothing
    exit;
}
print CHLD $_;
```

The condition lives on the handle, not on the descriptor.  `open(FH,
'|-')` dup2()s the pipe onto fd 0 in the child, but STDIN's PerlIO
object -- and its EOF flag -- is the one inherited across the fork.
`STDIN->clearerr` is enough to fix it, which is what pins the cause to
that flag; `binmode`, which only touches the layer stack, is not.

First written up in 2014:
[Perl で子プロセスが入力を読めない問題](https://qiita.com/kaz-utashiro/items/80fc83e56e645f19e927)
(Japanese).  Found in [App::Greple](https://metacpan.org/dist/App-Greple),
which must not spawn one filter process per file before knowing whether
the file matched, and therefore reads the input before forking.

## Results

Sixteen releases, 5.12.5 through 5.44.0
([run](https://github.com/kaz-utashiro/perl-stdin-eof-bench/actions/runs/36851387847),
see [probe.pl](probe.pl)):

| perl | `plain` | `read-to-clear` | `parent-@_` | `parent-my` | `clearerr` | `exec-cat` |
|---|---|---|---|---|---|---|
| 5.12.5, 5.16.3 | FAIL | ok | ok | ok | ok | FAIL |
| 5.20.3 – 5.36.3 | FAIL | ok | ok | ok | ok | ok |
| **5.38.0** – 5.44.0 | FAIL | **FAIL** | **FAIL** | **FAIL** | ok | ok |

Uniform across all sixteen releases probed: `plain` fails, `clearerr`
works, `fdopen-guard` and `fdopen-plain` work, `read-after-fork` and
`own-pipe` work, and `binmode`, `seek` and `parent-@_-eof` fail.  Four
columns move, and three of them turn together at 5.38.0.

| case | what the child does | |
|---|---|---|
| `plain` | just reads STDIN | the bug |
| `exec-cat` | `exec "cat"` | works — a fresh program gets a fresh handle |
| `read-after-fork` | parent reads *after* forking | works — restructuring, not a workaround |
| `read-to-clear` | `scalar <STDIN> if eof STDIN` | **worked through 5.36.3** |
| `parent-@_` | parent reads with `@_ = <STDIN>` | **worked through 5.36.3** |
| `parent-my` | parent reads with `my @x = <STDIN>` | **worked through 5.36.3** |
| `parent-@_-eof` | the same, then `eof STDIN` | fails everywhere |
| `clearerr` | `STDIN->clearerr` | works — the minimal fix |
| `binmode` | `binmode STDIN` | fails — layers are not the issue |
| `fdopen-guard` | `open STDIN, '<&', 0 if eof STDIN` | works |
| `fdopen-plain` | `open STDIN, '<&', 0` | works, the guard is not load-bearing |
| `seek` | `seek STDIN, 0, 0` | fails — cannot seek a pipe |
| `own-pipe` | hand-rolled `pipe` + `fork` | works |

### Why `read-to-clear` stopped working

Not neglect: it was taken away on purpose.  Reading from a handle used
to clear the stream state as a side effect, and that side effect was
itself the cause of perl/perl5#20060, where genuine read errors were
being lost.  Tony Cook's 80c1f1e45e narrowed it in 5.37.4 — "only clear
the stream error state in readline() for glob()" — which is why 5.38.0
is the boundary above.

When the narrowing surfaced as perl/perl5#21240 ("readline() no longer
detects appended data"), the answer there was "a direct consequence of
fixing #20060 ... I'm inclined to say this is not a bug, but a fix",
and the reporter was pointed at `seek($fh,0,1)` or `$fh->clearerr()`.

So `clearerr` is not just the one call that happens to fix the
condition this repository is about; it is the call perl's own
maintainers nominate for clearing a stale EOF.

### Why the list-read trick worked, and why it stopped

The 2014 write-up found that reading the input into `@_` made the child
work and called it mysterious.  It has a plain cause, and it is the same
one as `read-to-clear`:

| how the parent reads | what happens |
|---|---|
| `do { local $/; <STDIN> }` | one call reaches EOF, no *failing* readline follows, so the flag stays set |
| `@_ = <STDIN>` (list context) | the final readline fails and returns undef; up to 5.36.3 that cleared the state it had just set |
| either, then `eof STDIN` | the test sets the flag again — fails on every release |

So the trick was never about `@_`.  Reading into an ordinary `my @x`
behaves identically and stops working at the same place; what mattered
was list context ending in a failed read, which is exactly what
`read-to-clear` does deliberately.  80c1f1e45e took that side effect
away in 5.37.4, so both columns turn at **5.38.0** — not at 5.42, where
the 2014 addendum had placed it.


### exec-cat, and why it first looked version-dependent

`exec-cat` is the only case whose output is written by a separate
program rather than by the forked perl, so it is the only one that can
lose data if the parent exits without waiting for the child.  The first
version of this probe never closed the pipe and relied on exit-time
cleanup, and on 5.12.5 and 5.16.3 that lost the output — which looked
like `exec` behaving differently on old perls, and is not.

With `close CHLD` in place, `exec-cat` works on all sixteen releases.
The `exec-cat-noclose` case keeps the old form for comparison, and what
it actually measures is that 5.12.5 and 5.16.3 do not reliably reap a
`'|-'` child during exit-time cleanup, while 5.20.3 and later do.

Related: the same theme of a standard handle outliving its descriptor
appears in perl/perl5#24883 and
[perl-perlio-leak-bench](https://github.com/kaz-utashiro/perl-perlio-leak-bench).
