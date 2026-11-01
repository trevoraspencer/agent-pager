#!/usr/bin/perl
# Runs without hardware or PVE: every command and the notifier are replaced with fakes.
use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP;
use Test::More;

my $here;
BEGIN {
    $here = dirname(File::Spec->rel2abs(__FILE__));
    require "$here/../pve-disk-health";
}

my $fx = "$here/fixtures";
sub slurp { my ($f) = @_; open(my $fh, '<', "$fx/$f") or die "$f: $!"; local $/; return <$fh> }
sub fixture { return JSON::PP->new->decode(slurp(@_)) }

# Mutable fake world. Each test changes it, then runs the checker.
my %world;
sub reset_world {
    %world = (
        perccli_present => 1,
        megaraid        => 1,
        vall            => fixture('perccli-vall.json'),
        pd              => fixture('perccli-pd.json'),
        fall            => fixture('perccli-fall.json'),
        scan            => fixture('smartctl-scan.json'),
        smart           => {
            '/dev/bus/9' => fixture('smartctl-megaraid4.json'),
            '/dev/nvme9' => fixture('smartctl-nvme9.json'),
        },
        lvs    => fixture('lvs.json'),
        lvs_rc => 0,
    );
}

my @calls;
my $enc = JSON::PP->new->canonical(1);
$PVEDiskHealth::IS_EXEC      = sub { $world{perccli_present} };
$PVEDiskHealth::HAS_MEGARAID = sub { $world{megaraid} };
$PVEDiskHealth::NODENAME     = sub { 'node-under-test' };
$PVEDiskHealth::NOTIFY       = sub { push @calls, [@_] };
$PVEDiskHealth::RUN = sub {
    my ($cfg, $cmd, @a) = @_;
    my $args = join(' ', @a);
    if ($cmd eq $cfg->{perccli}) {
        return (0, $enc->encode($world{vall})) if $args eq '/call/vall show all J';
        return (0, $enc->encode($world{pd}))   if $args eq '/call/eall/sall show all J';
        return (0, $enc->encode($world{fall})) if $args eq '/call/fall show J';
    } elsif ($cmd eq $cfg->{smartctl}) {
        return (0, $enc->encode($world{scan})) if $args eq '--scan-open -j';
        my $dev = $a[-1];
        return (0, $enc->encode($world{smart}{$dev})) if $world{smart}{$dev};
        return (2, '');
    } elsif ($cmd eq $cfg->{lvs}) {
        return ($world{lvs_rc}, $world{lvs_rc} ? '' : $enc->encode($world{lvs}));
    }
    die "unexpected command: $cmd $args\n";
};

my $tmp = tempdir(CLEANUP => 1);
my $conf = "$tmp/empty.conf";
open(my $cfh, '>', $conf) or die;
close($cfh);
my $state = "$tmp/state/state.json";

sub run_check {
    my (@extra) = @_;
    @calls = ();
    my $out = '';
    {
        local *STDOUT;
        open(STDOUT, '>', \$out) or die;
        my $rc = PVEDiskHealth::main('--config', $conf, '--state', $state, @extra);
        is($rc, 0, 'exit 0');
    }
    return $out;
}
sub errors  { scalar grep { $_->[0] eq 'error' } @calls }
sub infos   { scalar grep { $_->[0] eq 'info' } @calls }
sub pd2     { $world{pd}{Controllers}[0]{'Response Data'}{'Drive /c0/e252/s2 - Detailed Information'}{'Drive /c0/e252/s2 State'} }
sub pool0   { $world{lvs}{report}[0]{lv}[0] }
sub vd0     { $world{vall}{Controllers}[0]{'Response Data'}{'/c0/v0'}[0] }
sub saved   { open(my $fh, '<', $state) or return {}; local $/; JSON::PP->new->decode(<$fh>)->{findings} }

# ---- parsing
reset_world();
my %cfg = %PVEDiskHealth::DEFAULTS;
my $f = PVEDiskHealth::collect(\%cfg);
is_deeply([sort keys %$f], [sort(
    'vd:/c0/v0', 'pd:/c0/e252/s1', 'pd:/c0/e252/s2', 'foreign:/c0',
    'smart:/dev/bus/9:megaraid,4', 'thin:vgtest/pool0',
)], 'finds exactly the problems in the fixtures');
is($f->{'vd:/c0/v0'}{rank}, 2, 'Dgrd ranks as degraded');
is_deeply($f->{'vd:/c0/v0'}{flags}, ['inconsistent'], 'Consist No is a flag');
is_deeply($f->{'pd:/c0/e252/s2'}{flags}, ['predictive_failure', 'smart_alert'], 'PF and SMART alert flags');
is_deeply($f->{'pd:/c0/e252/s2'}{counters}, { media_errors => 140, other_errors => 4 }, 'PD counters');
is_deeply($f->{'smart:/dev/bus/9:megaraid,4'}{counters},
    { grown_defects => 88, read_uncorrected => 210, verify_uncorrected => 40 }, 'SCSI SMART counters');
is($f->{'thin:vgtest/pool0'}{level}, 94, '95.10% is at the 94 step');
ok(!grep({ /FAKESN|FAKEWWN|FAKEMODEL/ } $enc->encode($f)), 'no serial, WWN or model is collected');

# ---- baseline page, then no repeat
reset_world();
my $out = run_check();
is(errors(), 1, 'first run pages once for existing problems');
like($out, qr/vd:\/c0\/v0: new/, 'first run names the new findings');
is_deeply($calls[0], ['error', 'node-under-test'], 'push carries only the node name');
ok(-e $state, 'state saved');
is((stat($state))[2] & 07777, 0600, 'state file is 0600');
run_check();
is(errors(), 0, 'same state does not page again');

# ---- counter step
pd2()->{'Media Error Count'} = 149;
run_check();
is(errors(), 0, '+9 media errors does not page');
pd2()->{'Media Error Count'} = 150;
$out = run_check();
is(errors(), 1, '+10 media errors since the last push pages');
like($out, qr/media_errors 140 -> 150/, 'counter reason is printed');
pd2()->{'Media Error Count'} = 155;
run_check();
is(errors(), 0, 'the step restarts from the paged value');
pd2()->{'Predictive Failure Count'} = 13;
run_check();
is(errors(), 0, 'a daily predictive-failure +1 does not page');

# ---- new counter from zero on an existing finding
pd2()->{'Other Error Count'} = 4;
my $s1 = $world{pd}{Controllers}[0]{'Response Data'}{'Drive /c0/e252/s1 - Detailed Information'}{'Drive /c0/e252/s1 State'};
$s1->{'S.M.A.R.T alert flagged by drive'} = 'Yes';
$out = run_check();
is(errors(), 1, 'a flag turning on pages');
like($out, qr/s1: smart_alert/, 'flag reason is printed');

# ---- worsening state
vd0()->{State} = 'Offln';
$out = run_check();
is(errors(), 1, 'Dgrd -> Offln pages');
like($out, qr/worse \(VD Dgrd -> VD Offln\)/, 'worse reason is printed');
vd0()->{State} = 'Dgrd';
run_check();
is(errors(), 0, 'getting better does not page');
vd0()->{State} = 'Offln';
run_check();
is(errors(), 1, 'getting worse again pages again');

# ---- thin pool steps
pool0()->{data_percent} = '89.90';
run_check();
is(infos(), 1, 'pool under 90% clears with an info notice');
is(errors(), 0, 'clearing does not page');
for my $case (['90.00', 1], ['91.50', 0], ['92.00', 1], ['93.90', 0], ['94.00', 1], ['94.50', 0]) {
    pool0()->{data_percent} = $case->[0];
    run_check();
    is(errors(), $case->[1], "thin pool at $case->[0]% pages $case->[1] time(s)");
}
pool0()->{metadata_percent} = '80.00';
run_check();
is(errors(), 1, 'metadata at 80% pages');

# ---- tool failure pages once, then clears
$world{lvs_rc} = 5;
$out = run_check();
is(errors(), 1, 'a failing tool pages');
like($out, qr/check:lvs: new/, 'tool failure is a finding');
run_check();
is(errors(), 0, 'a still-failing tool does not page again');
$world{lvs_rc} = 0;
$out = run_check();
like($out, qr/cleared: check:lvs/, 'tool recovery is reported');
is(infos(), 1, 'recovery sends info');

# ---- clear sends info
vd0()->{State} = 'Optl';
vd0()->{Consist} = 'Yes';
$out = run_check();
is(errors(), 0, 'a fixed VD does not page');
is(infos(), 1, 'a fixed VD sends one info');
ok(!exists saved()->{'vd:/c0/v0'}, 'cleared key is dropped');

# ---- perccli missing on a MegaRAID host
reset_world();
unlink $state;
$world{perccli_present} = 0;
$f = PVEDiskHealth::collect(\%cfg);
ok($f->{'check:perccli'}, 'MegaRAID without perccli is a finding');
$world{megaraid} = 0;
$f = PVEDiskHealth::collect(\%cfg);
ok(!$f->{'check:perccli'}, 'no MegaRAID, no perccli finding');

# ---- perccli status not Success is never healthy
reset_world();
$world{pd}{Controllers}[0]{'Command Status'}{Status} = 'Failure';
$f = PVEDiskHealth::collect(\%cfg);
ok($f->{'check:perccli'}, 'a PD query failure is a finding');
$world{fall} = fixture('perccli-fall-none.json');
$f = PVEDiskHealth::collect(\%cfg);
ok(!$f->{'foreign:/c0'}, 'no foreign group is not a finding');

# ---- NVMe flags
reset_world();
$world{smart}{'/dev/nvme9'}{nvme_smart_health_information_log}{critical_warning} = 4;
$world{smart}{'/dev/nvme9'}{nvme_smart_health_information_log}{percentage_used} = 91;
$f = PVEDiskHealth::collect(\%cfg);
is_deeply($f->{'smart:/dev/nvme9:nvme'}{flags}, ['nvme_critical_warning', 'nvme_wear'], 'NVMe warning and wear flags');

# ---- --show, --dry-run, --test, --baseline-quiet
reset_world();
unlink $state;
$out = run_check('--show');
is(scalar @calls, 0, '--show sends nothing');
ok(!-e $state, '--show saves nothing');
like($out, qr/would send a disk-health error/, '--show says what would page');
unlike($out, qr/FAKESN|FAKEWWN|FAKEMODEL/, '--show prints no serials');
$out = run_check('--dry-run');
is(scalar @calls, 0, '--dry-run sends nothing');
ok(!-e $state, '--dry-run saves nothing');
$out = run_check('--test');
is_deeply(\@calls, [['error', 'node-under-test disk-health test']], '--test sends one marked error');
ok(!-e $state, '--test does not touch the state');
$out = run_check('--baseline-quiet');
is(scalar @calls, 0, '--baseline-quiet: first run sends nothing');
ok(-e $state, '--baseline-quiet: baseline saved');
pd2()->{'Media Error Count'} = 160;
run_check('--baseline-quiet');
is(errors(), 1, '--baseline-quiet still pages on later worsening');

# ---- config and ignore
open($cfh, '>', $conf) or die;
print $cfh "# local\ncounter_step = 50\nignore = thin:*, foreign:/c0\nbogus = 1\nthin_data_warn = lots\n";
close($cfh);
my ($c, $w) = PVEDiskHealth::read_config($conf, 1);
is($c->{counter_step}, 50, 'config overrides a default');
is($c->{thin_data_warn}, 90, 'a bad number keeps the default');
is(scalar @$w, 2, 'unknown key and bad number are warned');
$f = PVEDiskHealth::collect($c);
ok(!grep({ /^thin:|^foreign:/ } keys %$f), 'ignore drops matching keys');
ok(!eval { PVEDiskHealth::read_config("$tmp/missing.conf", 1) }, 'a named config that is missing is an error');

# ---- the real command runner (needs coreutils timeout)
SKIP: {
    skip 'no timeout command', 2 if system('sh', '-c', 'command -v timeout >/dev/null 2>&1') != 0;
    my ($rc, $o) = PVEDiskHealth::run_cmd({ cmd_timeout => 5 }, 'echo', 'hello');
    is_deeply([$rc, $o], [0, "hello\n"], 'run_cmd returns exit code and stdout');
    ($rc) = PVEDiskHealth::run_cmd({ cmd_timeout => 5 }, '/nonexistent/tool');
    isnt($rc, 0, 'a missing tool is a non-zero exit');
}

done_testing();
