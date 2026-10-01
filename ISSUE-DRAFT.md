# Title

A child created by open(FH, '|-') cannot read its STDIN if the parent read STDIN to EOF first

# Body

## Description

When a process reads its own STDIN to the end and then forks a writer
child with `open(FH, '|-')`, the child cannot read anything from its
STDIN, even though the child's STDIN is the new pipe.  The EOF
condition that was set before the fork is still in effect.

The condition belongs to the handle rather than to the descriptor.
`open(FH, '|-')` dup2()s the pipe onto fd 0 in the child, but the
PerlIO object for STDIN is the one inherited across the fork, EOF flag
and all.  `STDIN->clearerr` in the child is enough to make it work,
which is what identifies the flag as the cause; `binmode STDIN`, which
touches only the layer stack, is not.

This is not a regression.  It has behaved this way for as long as I
have been checking, which is since 5.12.

## Steps to Reproduce

```perl
$_ = do { local $/; <STDIN> };          # parent reads to EOF
if (open(CHLD, '|-') == 0) {
    print <STDIN>;                      # reads nothing
    exit;
}
print CHLD $_;
```

```
$ printf 'hello\nworld\n' | perl that.pl
$                                       # expected hello/world
```

With `STDIN->clearerr` added as the child's first statement, the same
script prints the two lines.

## What works and what does not

Probed on every release from 5.12.5 to 5.44.0
([results and workflow](https://github.com/kaz-utashiro/perl-stdin-eof-bench)):

| in the child | 5.12.5 – 5.36.3 | 5.38.0 – 5.44.0 |
|---|---|---|
| nothing — just read STDIN | FAIL | FAIL |
| `exec "cat"` | ok | ok |
| `STDIN->clearerr` | ok | ok |
| `open STDIN, '<&', 0` | ok | ok |
| a hand-rolled `pipe` instead of `'\|-'` | ok | ok |
| `scalar <STDIN> if eof STDIN` | ok | **FAIL** |
| parent reads in list context, child does nothing | ok | **FAIL** |

`exec` works because the condition is a property of the handle: once
the program is replaced, there is no handle left to carry it.
`clearerr` is the whole of the fix within perl, and it is what
identifies the EOF flag as the thing at fault; `binmode STDIN`, which
touches only the layer stack, does nothing.

The last two rows turn at 5.38.0 because 80c1f1e45e stopped a failing
readline from clearing the stream state.  That was deliberate (#20060,
settled in #21240), so I am not reporting it as a regression — only
noting that it leaves `clearerr`, the fdopen-style re-open and a
hand-rolled pipe as the ways out.  That `clearerr` is also the call
#21240 names for a stale EOF is a good hint as to where the condition
lives.  It settles something I had called mysterious in 2014 as well:
list context ends in a failing read, so reading the input into `@_` was
never special, and a plain array behaves the same.

## Discussion

Since `open(FH, '|-')` is replacing the child's STDIN with a pipe, the
EOF and error state of the handle it is replacing has no bearing on the
new descriptor, and clearing it in the child looks like the natural
thing to do — the same work `STDIN->clearerr` now has to be done by
hand.  At a minimum this is worth a note in the documentation of
`open`'s `'|-'` form, since the obvious reading of "the child's STDIN
is the pipe" does not suggest that a condition from before the fork
still applies.

This is the same shape as #24883, where a standard handle's PerlIO
object outlives the descriptor swap and carries its layer stack with
it.  Here it carries its EOF flag.

## Real-world impact

Found in [App::Greple](https://metacpan.org/dist/App-Greple).  With an
output filter configured, a naive implementation starts one filter
process per input file, whether or not the file matched, so the filter
has to be started only once the match is known — which means reading
the input before forking.  Searching a directory of 13,000 small files
(one calendar event per file) is practical only that way.  The
workaround there has been the fdopen-style re-open since 2014.

Anyone writing a filter that reads first and forks second will meet
this, and the symptom — a child that silently produces nothing — gives
no hint of its cause.

The 2014 write-up, in Japanese, is still online:
https://qiita.com/kaz-utashiro/items/80fc83e56e645f19e927

## Perl configuration

Probed on ubuntu-latest with shogo82148/actions-setup-perl builds
(5.12.5 through 5.44.0); also reproduced on macOS/arm64 with Homebrew
perl 5.44.0.

<details><summary>perl -V (Homebrew 5.44.0, macOS arm64)</summary>

```
Summary of my perl5 (revision 5 version 44 subversion 0) configuration:
   
  Platform:
    osname=darwin
    osvers=24.6.0
    archname=darwin-thread-multi-2level
    uname='darwin sequoia-arm64.local 24.6.0 darwin kernel version 24.6.0: fri feb 27 19:34:48 pst 2026; root:xnu-11417.140.69.709.8~1release_arm64_vmapple arm64 '
    config_args='-des -Dinstallstyle=lib/perl5 -Dinstallprefix=/opt/homebrew/Cellar/perl/5.44.0 -Dprefix=/opt/homebrew/opt/perl -Dprivlib=/opt/homebrew/opt/perl/lib/perl5/5.44 -Dsitelib=/opt/homebrew/opt/perl/lib/perl5/site_perl/5.44 -Dotherlibdirs=/opt/homebrew/lib/perl5/site_perl/5.44 -Dvendorlib=/opt/homebrew/lib/perl5/vendor_perl/5.44 -Dvendorprefix=/opt/homebrew -Dperlpath=/opt/homebrew/opt/perl/bin/perl -Dstartperl=#!/opt/homebrew/opt/perl/bin/perl -Dman1dir=/opt/homebrew/opt/perl/share/man/man1 -Dman3dir=/opt/homebrew/opt/perl/share/man/man3 -Duseshrplib -Duselargefiles -Dusethreads'
    hint=recommended
    useposix=true
    d_sigaction=define
    useithreads=define
    usemultiplicity=define
    use64bitint=define
    use64bitall=define
    uselongdouble=undef
    usemymalloc=n
    default_inc_excludes_dot=define
  Compiler:
    cc='cc'
    ccflags ='-fno-common -DPERL_DARWIN -DNO_THREAD_SAFE_QUERYLOCALE -DNO_POSIX_2008_LOCALE -DHAS_BROKEN_LANGINFO_CODESET -DNO_LOCALE_COLLATE -fno-strict-aliasing -pipe -fstack-protector-strong'
    optimize='-O3'
    cppflags='-fno-common -DPERL_DARWIN -DNO_THREAD_SAFE_QUERYLOCALE -DNO_POSIX_2008_LOCALE -DHAS_BROKEN_LANGINFO_CODESET -DNO_LOCALE_COLLATE -fno-strict-aliasing -pipe -fstack-protector-strong'
    ccversion=''
    gccversion='Apple LLVM 17.0.0 (clang-1700.6.4.2)'
    gccosandvers=''
    intsize=4
    longsize=8
    ptrsize=8
    doublesize=8
    byteorder=12345678
    doublekind=3
    d_longlong=define
    longlongsize=8
    d_longdbl=define
    longdblsize=8
    longdblkind=0
    ivtype='long'
    ivsize=8
    nvtype='double'
    nvsize=8
    Off_t='off_t'
    lseeksize=8
    alignbytes=8
    prototype=define
  Linker and Libraries:
    ld='cc'
    ldflags =' -fstack-protector-strong'
    libpth=/opt/homebrew/lib /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/17/lib /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk/usr/lib /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib /usr/lib
    libs=-lgdbm
    perllibs=
    libc=
    so=dylib
    useshrplib=true
    libperl=libperl.dylib
    gnulibc_version=''
  Dynamic Linking:
    dlsrc=dl_dlopen.xs
    dlext=bundle
    d_dlsymun=undef
    ccdlflags=' '
    cccdlflags=' '
    lddlflags='-bundle -undefined dynamic_lookup -fstack-protector-strong'


Characteristics of this binary (from libperl): 
  Compile-time options:
    HAS_LONG_DOUBLE
    HAS_STRTOLD
    HAS_TIMES
    MULTIPLICITY
    PERLIO_LAYERS
    PERL_COPY_ON_WRITE
    PERL_HASH_FUNC_SIPHASH13
    PERL_HASH_USE_SBOX32
    PERL_MALLOC_WRAP
    PERL_OP_PARENT
    PERL_PRESERVE_IVUV
    PERL_USE_SAFE_PUTENV
    USE_64_BIT_ALL
    USE_64_BIT_INT
    USE_ITHREADS
    USE_LARGE_FILES
    USE_LOCALE
    USE_LOCALE_CTYPE
    USE_LOCALE_NUMERIC
    USE_LOCALE_TIME
    USE_PERLIO
    USE_PERL_ATOF
    USE_REENTRANT_API
  Built under darwin
  Compiled at Jul 15 2026 11:53:55
  %ENV:
    PERLDOC="-MPod::Text::Termcap"
    PERL_BADLANG="0"
  @INC:
    /opt/homebrew/opt/perl/lib/perl5/site_perl/5.44/darwin-thread-multi-2level
    /opt/homebrew/opt/perl/lib/perl5/site_perl/5.44
    /opt/homebrew/lib/perl5/vendor_perl/5.44/darwin-thread-multi-2level
    /opt/homebrew/lib/perl5/vendor_perl/5.44
    /opt/homebrew/opt/perl/lib/perl5/5.44/darwin-thread-multi-2level
    /opt/homebrew/opt/perl/lib/perl5/5.44
    /opt/homebrew/lib/perl5/site_perl/5.44/darwin-thread-multi-2level
    /opt/homebrew/lib/perl5/site_perl/5.44
```

</details>
