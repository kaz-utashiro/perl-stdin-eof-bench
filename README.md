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

One line per release ([probe.pl](probe.pl)):

```
RESULT perl=5.44.0 plain=FAIL exec-cat=ok read-after-fork=ok prime-read=FAIL \
clearerr=ok binmode=FAIL fdopen-guard=ok fdopen-plain=ok seek=FAIL own-pipe=ok
```

| case | what the child does | |
|---|---|---|
| `plain` | just reads STDIN | the bug |
| `exec-cat` | `exec "cat"` | works — a fresh program gets a fresh handle |
| `read-after-fork` | parent reads *after* forking | works — restructuring, not a workaround |
| `prime-read` | `scalar <STDIN> if eof STDIN` | **used to work, no longer does** |
| `clearerr` | `STDIN->clearerr` | works — the minimal fix |
| `binmode` | `binmode STDIN` | fails — layers are not the issue |
| `fdopen-guard` | `open STDIN, '<&', 0 if eof STDIN` | works |
| `fdopen-plain` | `open STDIN, '<&', 0` | works, the guard is not load-bearing |
| `seek` | `seek STDIN, 0, 0` | fails — cannot seek a pipe |
| `own-pipe` | hand-rolled `pipe` + `fork` | works |

The 2014 article offered reading-to-prime as a working if inelegant
option.  It no longer is.  Reading into `@_` used to work too and
stopped in 5.42; so did reading into an ordinary `my @x`.

Related: the same theme of a standard handle outliving its descriptor
appears in perl/perl5#24883 and
[perl-perlio-leak-bench](https://github.com/kaz-utashiro/perl-perlio-leak-bench).
