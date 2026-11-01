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
        fall_raw        => undef,
        fall_rc         => 0,
        scan            => fixture('smartctl-scan.json'),
        smart           => {
            '/dev/bus/9' => fixture('smartctl-megaraid4.json'),
            '/dev/nvme9' => fixture('smartctl-nvme9.json'),
        },
        smart_rc => {},
        lvs      => fixture('lvs.json'),
        lvs_rc   => 0,
    );
}

my (@calls, @timeouts);
my $now = 1_000_000;
my $notify_dies = 0;
my $enc = JSON::PP->new->canonical(1);
$PVEDiskHealth::IS_EXEC      = sub { $world{perccli_present} };
$PVEDiskHealth::HAS_MEGARAID = sub { $world{megaraid} };
$PVEDiskHealth::NODENAME     = sub { 'node-under-test' };
$PVEDiskHealth::NOW          = sub { $now };
$PVEDiskHealth::NOTIFY       = sub { die "notify broke\n" if $notify_dies; push @calls, [@_] };
$PVEDiskHealth::RUN = sub {
    my ($cfg, $cmd, @a) = @_;
    push @timeouts, $cfg->{cmd_timeout};
    my $args = join(' ', @a);
    if ($cmd eq $cfg->{perccli}) {
        return (0, $enc->encode($world{vall})) if $args eq '/call/vall show all J';
        return (0, $enc->encode($world{pd}))   if $args eq '/call/eall/sall show all J';
        return ($world{fall_rc}, $world{fall_raw} // $enc->encode($world{fall})) if $args eq '/call/fall show J';
    } elsif ($cmd eq $cfg->{smartctl}) {
        return (0, $enc->encode($world{scan})) if $args eq '--scan-open -j';
        my $dev = $a[-1];
        return ($world{smart_rc}{$dev} // 0, $enc->encode($world{smart}{$dev})) if $world{smart}{$dev};
        return (2, '');
    } elsif ($cmd eq $cfg->{lvs}) {
        return ($world{lvs_rc}, $world{lvs_rc} ? '' : $enc->encode($world{lvs}));
    }
    die "unexpected command: $cmd $args\n";
};

my $tmp = tempdir(CLEANUP => 1);
my $state = "$tmp/state/state.json";
my $fallback = "$tmp/run/state.json";
my $conf = "$tmp/test.conf";
sub write_conf {
    my ($extra) = @_;
    open(my $fh, '>', $conf) or die;
    print $fh "fallback_state_file = $fallback\n", $extra // '';
    close($fh);
}
write_conf();
my %cfg = (%PVEDiskHealth::DEFAULTS, fallback_state_file => $fallback);

sub run_check {
    my (@extra) = @_;
    @calls = ();
    my $out = '';
    my $rc;
    {
        local *STDOUT;
        local *STDERR;
        open(STDOUT, '>', \$out) or die;
        my $err = '';
        open(STDERR, '>', \$err) or die;
        $rc = PVEDiskHealth::main('--config', $conf, '--state', $state, @extra);
    }
    return wantarray ? ($out, $rc) : $out;
}
sub fresh   { reset_world(); unlink $state, $fallback; write_conf(); run_check() }
sub errors  { scalar grep { $_->[0] eq 'error' } @calls }
sub infos   { scalar grep { $_->[0] eq 'info' } @calls }
sub found   { PVEDiskHealth::collect(\%cfg)->{findings} }
sub rdata   { $world{pd}{Controllers}[0]{'Response Data'} }
sub pd2     { rdata()->{'Drive /c0/e252/s2 - Detailed Information'}{'Drive /c0/e252/s2 State'} }
sub pool0   { $world{lvs}{report}[0]{lv}[0] }
sub vd0     { $world{vall}{Controllers}[0]{'Response Data'}{'/c0/v0'}[0] }
sub saved   { open(my $fh, '<', $state) or return {}; local $/; JSON::PP->new->decode(<$fh>) }
sub drop_drive { my ($s) = @_; delete rdata()->{"Drive /c0/e252/s$s"}; delete rdata()->{"Drive /c0/e252/s$s - Detailed Information"} }

# ---- parsing
reset_world();
my $f = found();
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
my $inv = PVEDiskHealth::collect(\%cfg)->{inventory};
is_deeply([sort keys %$inv], [sort(
    'ctrl:/c0', 'vd:/c0/v0', 'vd:/c0/v1', map({ "pd:/c0/e252/s$_" } 0 .. 3),
    'dev:/dev/bus/9:megaraid,4', 'dev:/dev/nvme9:nvme', 'pool:vgtest/pool0', 'pool:vgtest/pool1',
)], 'inventory lists controllers, volumes, drives, SMART devices and pools');

# ---- baseline page, then no repeat
my ($out, $rc) = fresh();
is($rc, 0, 'first run exits 0');
is(errors(), 1, 'first run pages once for existing problems');
like($out, qr{vd:/c0/v0: new}, 'first run names the new findings');
is_deeply($calls[0], ['error', 'node-under-test'], 'push carries only the node name');
is((stat($state))[2] & 07777, 0600, 'state file is 0600');
is(saved()->{version}, 2, 'state format version 2');
run_check();
is(scalar @calls, 0, 'same state sends nothing');

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

# ---- flag turning on
rdata()->{'Drive /c0/e252/s1 - Detailed Information'}{'Drive /c0/e252/s1 State'}{'S.M.A.R.T alert flagged by drive'} = 'Yes';
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

# ---- a failed source does not clear its findings
$world{lvs_rc} = 5;
$out = run_check();
is(errors(), 1, 'a failing tool pages');
like($out, qr/check:lvs: new/, 'tool failure is a finding');
is(infos(), 0, 'a failed lvs does not clear the thin pool finding');
ok(saved()->{findings}{'thin:vgtest/pool0'}, 'thin pool finding kept while lvs fails');
run_check();
is(scalar @calls, 0, 'a still-failing tool sends nothing again');
$world{lvs_rc} = 0;
$out = run_check();
like($out, qr/cleared: check:lvs/, 'tool recovery is reported');
is(errors(), 0, 'recovery does not page');
is(infos(), 1, 'recovery sends info');

# ---- clear sends info
vd0()->{State} = 'Optl';
vd0()->{Consist} = 'Yes';
$out = run_check();
is(errors(), 0, 'a fixed VD does not page');
is(infos(), 1, 'a fixed VD sends one info');
ok(!exists saved()->{findings}{'vd:/c0/v0'}, 'cleared key is dropped');

# ---- P1-1: disappearing hardware pages; it is not a clear
fresh();
drop_drive(2);
$out = run_check();
is(errors(), 1, 'a failing drive that disappears pages');
like($out, qr{gone:pd:/c0/e252/s2: new}, 'the missing drive is named');
is(infos(), 0, 'a missing failed drive does not send a false recovery');
ok(saved()->{findings}{'pd:/c0/e252/s2'}, 'the missing drive retains its original failure');
ok(saved()->{findings}{'gone:pd:/c0/e252/s2'}, 'gone finding saved');
run_check();
is(scalar @calls, 0, 'a drive still missing does not page again');
drop_drive(0);
$out = run_check();
is(errors(), 1, 'a healthy drive that disappears pages too');
like($out, qr{gone:pd:/c0/e252/s0}, 'second missing drive is named');

fresh();
delete $world{vall}{Controllers}[0]{'Response Data'}{'/c0/v1'};
splice(@{ $world{lvs}{report}[0]{lv} }, 1, 1);
@{ $world{scan}{devices} } = grep { $_->{name} ne '/dev/nvme9' } @{ $world{scan}{devices} };
$out = run_check();
like($out, qr{gone:vd:/c0/v1}, 'a missing VD pages');
like($out, qr{gone:pool:vgtest/pool1}, 'a missing thin pool pages');
like($out, qr{gone:dev:/dev/nvme9:nvme}, 'a missing NVMe device pages');
is(infos(), 0, 'nothing that disappeared is reported as cleared');

$out = run_check('--accept-inventory');
like($out, qr/accepted the current inventory/, '--accept-inventory accepts');
is(scalar @calls, 0, '--accept-inventory sends nothing');
run_check();
is(scalar @calls, 0, 'after --accept-inventory the removed hardware is forgotten');
ok(!grep({ /^gone:/ } keys %{ saved()->{findings} }), 'no gone findings left');

fresh();
$world{vall} = { Controllers => [] };
$world{pd}   = { Controllers => [] };
$world{fall} = { Controllers => [] };
$out = run_check();
like($out, qr{gone:ctrl:/c0}, 'a controller that disappears pages');

fresh();
$world{perccli_present} = 0;
$out = run_check();
like($out, qr/check:perccli: new/, 'perccli going missing is a finding');
unlike($out, qr/gone:/, 'perccli going missing does not mark hardware gone');
is(infos(), 0, 'perccli going missing clears nothing');

# ---- P1-3: SMART failures are kept per device
reset_world();
push @{ $world{scan}{devices} }, { name => '/dev/sdy', type => 'sat', protocol => 'ATA', open_error => 'No such device' };
$f = found();
ok(!$f->{'check:smartctl:/dev/sdz:scsi'}, 'a MegaRAID volume that cannot be opened is skipped');
ok($f->{'check:smartctl:/dev/sdy:sat'}, 'a real open failure is a finding');

reset_world();
$world{smart_rc}{'/dev/nvme9'} = 4;
$f = found();
ok($f->{'check:smartctl:/dev/nvme9:nvme'}, 'exit bit 2 (value 4) is a query failure');
$world{smart_rc}{'/dev/nvme9'} = 64;
ok(!found()->{'check:smartctl:/dev/nvme9:nvme'}, 'exit bit 6 (error log) is not a query failure');
$world{smart_rc}{'/dev/nvme9'} = 8;
is_deeply(found()->{'smart:/dev/nvme9:nvme'}{flags}, ['smart_failed'], 'exit bit 3 (value 8) is a failing disk');
reset_world();
delete $world{smart}{'/dev/nvme9'}{smart_status};
like(found()->{'check:smartctl:/dev/nvme9:nvme'}{state}, qr/no health data/, 'missing health data is a finding');

fresh();
$world{smart_rc}{'/dev/nvme9'} = 4;
$out = run_check();
like($out, qr{check:smartctl:/dev/nvme9:nvme: new}, 'first device failure pages');
$world{smart_rc}{'/dev/bus/9'} = 2;
$out = run_check();
is(errors(), 1, 'a second failing device pages even while the first still fails');
like($out, qr{check:smartctl:/dev/bus/9:megaraid,4: new}, 'second failure has its own key');
is(infos(), 0, 'a failing SMART query does not clear that drive');
ok(saved()->{findings}{'smart:/dev/bus/9:megaraid,4'}, 'drive finding kept while its query fails');

# ---- P2-4: the foreign query
for my $case (
    ['a timeout', 124, ''],
    ['a nonzero exit with no JSON', 3, ''],
    ['malformed output', 0, '{"Controllers": "x"}'],
    ['a failure that is not "no foreign"', 1, '{"Controllers":[{"Command Status":{"Controller":0,"Status":"Failure","Description":"Controller busy"}}]}'],
) {
    reset_world();
    $world{fall_rc} = $case->[1];
    $world{fall_raw} = $case->[2];
    $f = found();
    ok(grep({ /^check:perccli:foreign/ } keys %$f), "foreign query: $case->[0] is a finding");
}
reset_world();
$world{fall} = fixture('perccli-fall-none.json');
$f = found();
ok(!$f->{'foreign:/c0'} && !grep({ /^check:/ } keys %$f), 'an explicit "no foreign configuration" is absent and fine');

# ---- P2-5: bad JSON shapes are findings, never a crash
reset_world();
$world{scan} = [];
ok(found()->{'check:smartctl:scan'}, 'a SMART scan of [] is a finding');
reset_world();
$world{smart}{'/dev/nvme9'} = [1, 2];
ok(found()->{'check:smartctl:/dev/nvme9:nvme'}, 'a device answer that is not an object is a finding');
reset_world();
$world{vall} = { Controllers => ['x'] };
ok(found()->{'check:perccli:vd'}, 'a controller entry that is not an object is a finding');
reset_world();
$world{pd}{Controllers}[0]{'Response Data'} = [];
ok(found()->{'check:perccli:pd:/c0'}, 'PD response data that is not an object is a finding');
reset_world();
rdata()->{'Drive /c0/e252/s3 - Detailed Information'} = 'oops';
ok(found()->{'check:perccli:pd:/c0/e252/s3'}, 'a drive without detail is a finding');
reset_world();
$world{lvs} = { report => [{ lv => 'x' }] };
ok(found()->{'check:lvs'}, 'an lvs report of the wrong shape is a finding');
reset_world();
{
    local $PVEDiskHealth::COLLECTORS{thin} = sub { die "boom\n" };
    my $ctx = PVEDiskHealth::collect(\%cfg);
    like($ctx->{findings}{'check:thin:internal'}{state}, qr/boom/, 'an unexpected error in a collector is a finding');
    ok($ctx->{failed}{thin}, 'and marks that source incomplete');
    ok($ctx->{findings}{'vd:/c0/v0'}, 'the other sources still run');
}

# ---- P2-6: state problems
fresh();
open(my $sfh, '>', $state) or die;
print $sfh "{not json";
close($sfh);
($out, $rc) = run_check();
is($rc, 0, 'a corrupt state does not stop the run');
like($out, qr/check:state: new/, 'a corrupt state is a finding that pages');
ok(-e "$state.bad", 'the corrupt file is kept aside');
is(errors(), 1, 'one push for the corrupt state');
$out = run_check();
is(errors(), 0, 'after the rebuild nothing pages again');
like($out, qr/cleared: check:state/, 'the corrupt-state finding clears');

fresh();
unlink "$state.bad";
open($sfh, '>', $state) or die;
print $sfh "{not json";
close($sfh);
# Isolate the state fault: no hardware faults should trigger the retry for us.
{
local $PVEDiskHealth::COLLECTORS{perc} = sub {};
local $PVEDiskHealth::COLLECTORS{smart} = sub {};
local $PVEDiskHealth::COLLECTORS{thin} = sub {};
$notify_dies = 1;
($out, $rc) = run_check();
is($rc, 1, 'a corrupt-state alert that cannot be sent exits nonzero');
ok(-e $state && !-e "$state.bad", 'corrupt state stays in place until its alert is delivered');
is((PVEDiskHealth::load_state($state))[1], 'corrupt', 'failed send does not replace corrupt state');
$notify_dies = 0;
($out, $rc) = run_check('--baseline-quiet');
is($rc, 0, 'rerun after failed corrupt-state notification succeeds');
is(errors(), 1, 'corrupt-state alert retries even with baseline-quiet');
like($out, qr/check:state: new/, 'retry reports the pending corruption');
ok(-e "$state.bad", 'bad state is retained after successful delivery');
}

fresh();
my $sdir = dirname($state);
chmod 0500, $sdir;
pd2()->{'Media Error Count'} = 200;
($out, $rc) = run_check();
is($rc, 1, 'an unwritable state exits 1');
is(errors(), 1, 'an unwritable state sends one error');
ok(-e $fallback, 'the fallback state is written');
($out, $rc) = run_check();
is(scalar @calls, 0, 'an unwritable state does not page every run');
($out, $rc) = run_check();
is(scalar @calls, 0, 'still no repeat on the third run');
chmod 0700, $sdir;
($out, $rc) = run_check();
is($rc, 0, 'state writable again');
ok(!-e $fallback, 'the fallback state is removed');
like($out, qr/cleared: check:state-write/, 'the write problem clears with info');
is(errors(), 0, 'and does not page');

fresh();
pd2()->{'Media Error Count'} = 300;
$notify_dies = 1;
($out, $rc) = run_check();
is($rc, 1, 'a failed notification exits 1');
$notify_dies = 0;
run_check();
is(errors(), 1, 'the change pages on the next run, after a failed notification');

# ---- P2-7: the whole run has a deadline
fresh();
write_conf("deadline = 0\n");
($out, $rc) = run_check();
is($rc, 0, 'a run past the deadline still finishes');
like($out, qr/check:deadline: new/, 'hitting the deadline is a finding');
is(errors(), 1, 'and it is sent');
is(infos(), 0, 'nothing is cleared when collection stopped early');
ok(saved()->{findings}{'vd:/c0/v0'}, 'findings are kept when collection stopped early');
write_conf("deadline = 20\ncmd_timeout = 60\n");
@timeouts = ();
run_check();
ok(@timeouts && $timeouts[0] <= 18, 'each command timeout is capped by the time left');
write_conf();

# ---- perccli missing on a MegaRAID host
reset_world();
$world{perccli_present} = 0;
ok(found()->{'check:perccli'}, 'MegaRAID without perccli is a finding');
$world{megaraid} = 0;
ok(!found()->{'check:perccli'}, 'no MegaRAID, no perccli finding');

# ---- NVMe flags
reset_world();
$world{smart}{'/dev/nvme9'}{nvme_smart_health_information_log}{critical_warning} = 4;
$world{smart}{'/dev/nvme9'}{nvme_smart_health_information_log}{percentage_used} = 91;
is_deeply(found()->{'smart:/dev/nvme9:nvme'}{flags}, ['nvme_critical_warning', 'nvme_wear'], 'NVMe warning and wear flags');

# ---- --show, --dry-run, --test, --baseline-quiet
reset_world();
unlink $state, $fallback;
$out = run_check('--show');
is(scalar @calls, 0, '--show sends nothing');
ok(!-e $state, '--show saves nothing');
like($out, qr/would send a disk-health error/, '--show says what would page');
unlike($out, qr/FAKESN|FAKEWWN|FAKEMODEL/, '--show prints no serials');
run_check('--dry-run');
is(scalar @calls, 0, '--dry-run sends nothing');
ok(!-e $state, '--dry-run saves nothing');
run_check('--test');
is_deeply(\@calls, [['error', 'node-under-test disk-health test']], '--test sends one marked error');
ok(!-e $state, '--test does not touch the state');
run_check('--baseline-quiet');
is(scalar @calls, 0, '--baseline-quiet: first run sends nothing');
ok(-e $state, '--baseline-quiet: baseline saved');
pd2()->{'Media Error Count'} = 160;
run_check('--baseline-quiet');
is(errors(), 1, '--baseline-quiet still pages on later worsening');

# ---- config and ignore
write_conf("# local\ncounter_step = 50\nignore = thin:*, foreign:/c0\nbogus = 1\nthin_data_warn = lots\n");
my ($c, $w) = PVEDiskHealth::read_config($conf, 1);
is($c->{counter_step}, 50, 'config overrides a default');
is($c->{thin_data_warn}, 90, 'a bad number keeps the default');
is(scalar @$w, 2, 'unknown key and bad number are warned');
$f = PVEDiskHealth::collect($c)->{findings};
ok(!grep({ /^thin:|^foreign:/ } keys %$f), 'ignore drops matching keys');
ok(!eval { PVEDiskHealth::read_config("$tmp/missing.conf", 1) }, 'a named config that is missing is an error');

# ---- second-review regressions
fresh();
drop_drive(2);
$world{smart}{'/dev/nvme9'}{smart_status}{passed} = JSON::PP::false;
my $prior_smart = saved()->{findings}{'smart:/dev/bus/9:megaraid,4'};
$world{smart}{'/dev/bus/9'}{scsi_grown_defect_list} += 20;
run_check('--accept-inventory');
is(scalar @calls, 0, 'accept inventory never notifies');
ok(!saved()->{findings}{'smart:/dev/nvme9:nvme'}, 'accept does not acknowledge a new unrelated fault');
is_deeply(saved()->{findings}{'smart:/dev/bus/9:megaraid,4'}, $prior_smart,
    'accept leaves existing notification baselines untouched');
ok(!saved()->{findings}{'pd:/c0/e252/s2'}, 'accept removes the absent drive failure');
$out = run_check();
like($out, qr{smart:/dev/nvme9:nvme: new}, 'the unrelated SMART failure still pages next run');
like($out, qr{grown_defects 88 -> 108}, 'an unrelated counter rise still pages next run');

for my $bad (
    { 'smart:/dev/nvme9:nvme' => 1 },
    { bad => { rank => [], state => 'bad', flags => [], counters => {} } },
    { bad => { rank => 1, state => 'bad', flags => {}, counters => {} } },
    { bad => { rank => 1, state => 'bad', flags => [], counters => { errors => [] } } },
    { bad => { rank => 1, state => 'bad', flags => [], counters => {}, paged_counters => [] } },
) {
    fresh();
    open(my $fh, '>', $state) or die;
    print $fh $enc->encode({ findings => $bad, inventory => {} });
    close $fh;
    ($out, $rc) = run_check();
    is($rc, 0, 'invalid nested state is recovered without crashing');
    like($out, qr/check:state: new/, 'invalid nested state pages as corrupt');
}

fresh();
chmod 0500, $sdir;
$notify_dies = 1;
($out, $rc) = run_check();
is($rc, 1, 'failed state-write notification exits nonzero');
unlike($out, qr/sent disk-health error/, 'failed notification is not claimed as sent');
my ($fbstate) = PVEDiskHealth::load_state($fallback);
ok(!$fbstate->{findings}{'check:state-write'}, 'failed notification is not acknowledged in fallback');
$notify_dies = 0;
run_check();
is(errors(), 1, 'state-write notification retries after failed send');
run_check();
is(errors(), 0, 'successful state-write notification is deduplicated');
chmod 0700, $sdir;

for my $case (
    [124, { Controllers => [{ 'Command Status' => { Status => 'Success', Controller => 0 } }] }],
    [3, fixture('perccli-fall.json')],
    [0, { Controllers => [{ 'Command Status' => { Status => 'Success', Controller => 0 } }] }],
) {
    reset_world();
    ($world{fall_rc}, $world{fall}) = @$case;
    ok(grep({ /^check:perccli:foreign/ } keys %{ found() }),
        'foreign query rejects error exits or missing response data, even with Success JSON');
}
reset_world();
$world{fall}{Controllers}[0]{'Response Data'}{'FOREIGN CONFIGURATION'} = [];
ok(!grep({ /^check:perccli:foreign|^foreign:/ } keys %{ found() }), 'a valid empty foreign list is accepted');
write_conf();

# ---- the README install block lists the current checksums
{
    require Digest::SHA;
    open(my $rfh, '<', "$here/../README.md") or die;
    my $readme = do { local $/; <$rfh> };
    for my $file (qw(pve-disk-health pve-disk-health.service pve-disk-health.timer)) {
        my $sum = Digest::SHA->new(256)->addfile("$here/../$file")->hexdigest;
        like($readme, qr/^\Q$sum\E  \Q$file\E$/m, "README checksum for $file is current");
    }
}

# ---- the real command runner (needs coreutils timeout)
SKIP: {
    skip 'no timeout command', 2 if system('sh', '-c', 'command -v timeout >/dev/null 2>&1') != 0;
    my ($r, $o) = PVEDiskHealth::run_cmd({ cmd_timeout => 5 }, 'echo', 'hello');
    is_deeply([$r, $o], [0, "hello\n"], 'run_cmd returns exit code and stdout');
    ($r) = PVEDiskHealth::run_cmd({ cmd_timeout => 5 }, '/nonexistent/tool');
    isnt($r, 0, 'a missing tool is a non-zero exit');
}

done_testing();
