use warnings;
use strict;
use Test::More;

BEGIN {
    use lib('t');
    require TestUtils;
    import TestUtils;
}

plan tests => 60;

###########################################################
# test thruks script path
TestUtils::test_command({
    cmd  => '/bin/bash -c "type thruk"',
    like => ['/\/thruk\/script\/thruk/'],
}) or BAIL_OUT("wrong thruk path");

`rm -rf var/thruk/obj_retention*`;
`rm -rf var/thruk/localconfcache/`;

# local files should be fetched on the first call
TestUtils::test_command({
    cmd     => '/usr/bin/env thruk r -d "" /sites/tier3a/config/diff -v',
    errlike => [qr%\Q[]\E%, qr%\Qremote file sync started\E%, qr%\Qupdating file: /omd/sites/demo/etc/naemon/conf.d/commands.cfg\E%],
    like    => [],
});

# no file updates on check
TestUtils::test_command({
    cmd     => '/usr/bin/env thruk r -d "" /sites/tier3a/config/check -v',
    errlike => [qr%\Q"failed" : false\E%, qr%\QThings look okay\E%],
    unlike  => [qr%\Qconf.d/commands.cfg\E%],
});

# local files should be checked on consecutive calls
TestUtils::test_command({
    cmd    => '/usr/bin/env thruk r -d "" /sites/tier3a/config/diff -vvvv',
    errlike => [qr%\Qkeeping file: /omd/sites/demo/etc/naemon/conf.d/commands.cfg\E%],
    like    => [],
});

for my $site (qw/tier1a tier2a tier3a/) {
    TestUtils::test_command({
        cmd    => '/usr/bin/env thruk r -d "" /sites/'.$site.'/config/check',
        like    => [qr%\QRead object config files okay\E%, qr%\Q"failed" : false\E%, qr%\QThings look okay\E%],
    });
}

TestUtils::test_command({
    cmd    => '/usr/bin/env thruk r -d "" /config/check',
    like    => [qr%\QRead object config files okay\E%, qr%\Q"failed" : false\E%],
});

for my $site (qw/tier1a tier2a tier3a/) {
    TestUtils::test_command({
        cmd    => '/usr/bin/env thruk r -d "" /sites/'.$site.'/config/reload',
        like    => [qr%\QReloading naemon configuration\E%, qr%\Q"failed" : false\E%],
    });
}

TestUtils::test_command({
    cmd    => '/usr/bin/env thruk r -d "" /config/reload',
    like    => [qr%\QReloading naemon configuration\E%, qr%\Q"failed" : false\E%],
});
