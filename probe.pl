# Does a child created by open(FH, '|-') see STDIN at EOF because the
# parent read its STDIN to the end?  And which of the documented
# workarounds still work?
#
# Each case runs in its own process: the parent reads all of STDIN,
# forks a writer child, and the child is expected to echo the data
# back.  Prints one RESULT line naming the cases that worked.
use strict; use warnings;

my $data = "hello\nworld\n";
my %case = (
    'plain'        => q{ if (open(CHLD, '|-') == 0) { print <STDIN>; exit } },
    'exec-cat'     => q{ if (open(CHLD, '|-') == 0) { exec "cat" or warn $!; exit } },
    'read-to-clear'   => q{ if (open(CHLD, '|-') == 0) { scalar <STDIN> if eof STDIN; print <STDIN>; exit } },
    'fdopen-guard' => q{ if (open(CHLD, '|-') == 0) { open STDIN, '<&', 0 if eof STDIN; print <STDIN>; exit } },
    'fdopen-plain' => q{ if (open(CHLD, '|-') == 0) { open STDIN, '<&', 0; print <STDIN>; exit } },
    'seek'         => q{ if (open(CHLD, '|-') == 0) { seek STDIN, 0, 0; print <STDIN>; exit } },
    'clearerr'     => q{ if (open(CHLD, '|-') == 0) { use IO::Handle; STDIN->clearerr; print <STDIN>; exit } },
    'binmode'      => q{ if (open(CHLD, '|-') == 0) { binmode STDIN; print <STDIN>; exit } },
);
# these two restructure rather than work around, so they are run apart
my %shape = (
    'read-after-fork' => 1,
    'own-pipe'        => 1,
);

my $dir = $ENV{TMPDIR} || '/tmp';
my %ok;

for my $name (sort keys %case) {
    my $prog = "\$_ = do { local \$/; <STDIN> };\n$case{$name}\nprint CHLD \$_;\n";
    $ok{$name} = run_child($prog);
}
$ok{'read-after-fork'} = run_child(<<'P');
if (open(CHLD, '|-') == 0) { print <STDIN>; exit }
$_ = do { local $/; <STDIN> };
print CHLD $_;
P
# The parent side matters too: how it reads changes whether the EOF
# flag ends up set.  These read into a list instead of slurping into a
# scalar, which the 2014 write-up found to work "mysteriously".
$ok{'parent-@_'} = run_child(<<'P');
@_ = <STDIN>;
if (open(CHLD, '|-') == 0) { print <STDIN>; exit }
print CHLD @_;
P
$ok{'parent-my'} = run_child(<<'P');
my @x = <STDIN>;
if (open(CHLD, '|-') == 0) { print <STDIN>; exit }
print CHLD @x;
P
$ok{'parent-@_-eof'} = run_child(<<'P');
@_ = <STDIN>;
my $e = eof STDIN;
if (open(CHLD, '|-') == 0) { print <STDIN>; exit }
print CHLD @_;
P
$ok{'own-pipe'} = run_child(<<'P');
$_ = do { local $/; <STDIN> };
pipe PIN, POUT or die;
if (fork == 0) { close STDIN; open STDIN, '<&PIN'; close PIN; close POUT; print <STDIN>; exit }
close PIN;
print POUT $_;
P

sub run_child {
    my $prog = shift;
    my $pl  = "$dir/probe-$$-case.pl";
    my $out = "$dir/probe-$$-case.out";
    open my $f, '>', $pl or die $!;
    print {$f} $prog;
    close $f;
    open my $p, '|-', "$^X $pl > $out 2>/dev/null" or die $!;
    print {$p} $data;
    close $p;
    open my $r, '<', $out or return 'ERR';
    my $got = do { local $/; <$r> };
    close $r;
    unlink $pl, $out;
    (defined $got && $got eq $data) ? 'ok' : 'FAIL';
}

my @order = qw(plain parent-@_ parent-my parent-@_-eof exec-cat read-after-fork read-to-clear clearerr binmode fdopen-guard fdopen-plain seek own-pipe);
printf "RESULT perl=%vd %s\n", $^V, join ' ', map { "$_=$ok{$_}" } @order;
