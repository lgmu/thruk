use warnings;
use strict;
use Cpanel::JSON::XS qw/decode_json/;
use Test::More;

use Thruk::Config 'noautoload';

BEGIN {
    plan skip_all => 'test skipped' if defined $ENV{'NO_DISABLED_PLUGINS_TEST'};

    plan tests => 18;
}

BEGIN {
    use lib('t');
    require TestUtils;
    import TestUtils;
}

###########################################################
# test modules
if(defined $ENV{'PLACK_TEST_EXTERNALSERVER_URI'}) {
    unshift @INC, 'plugins/plugins-available/agents/lib';
}

use_ok 'Thruk::Base';
use_ok 'Thruk::Config';
use_ok 'Thruk::Controller::agents';
use_ok 'Thruk::Agents::SNClient';

###########################################################
my $c = TestUtils::get_c();
my $hostname = "localhost";
my $hostobj  = undef;
my $password = "password";
my $cli_opts = {};
my $section  = "testing";
my $mode     = "http";
my $options  = {};
my $tags     = ["prod", "test"];

###########################################################
# service check
{
    my $conf = <<EOT;
<Component Thruk::Agents>
  <snclient>
    <service>
      service  = snclient
      host     = ANY
      section  ~ test
      tags     = prod
    </service>
  </snclient>
</Component>
EOT

my $inv = <<EOT;
{ "inventory" : {
    "service" : [{
      "active" : "active",
      "age" : "55550",
      "cpu" : "3.2",
      "created" : "1741410012",
      "desc" : "SNClient+ Agent",
      "name" : "snclient",
      "pid" : "2393244",
      "preset" : "enabled",
      "rss" : "21319680",
      "service" : "snclient",
      "state" : "running",
      "tasks" : "28",
      "vms" : "1276743680"
    }]
  }
}
EOT

    my $xtr = Thruk::Config::parse_config_from_text($conf);
    $c->config->{'Thruk::Agents'} = $xtr->{'Thruk::Agents'};
    undef $Thruk::Agents::SNClient::conf;
    local $cli_opts->{'cached'} = decode_json($inv);
    my $checks = Thruk::Agents::SNClient::get_services_checks(undef, $c, $hostname, $hostobj, $password, $cli_opts, $section, $mode, $options, $tags);
    $checks = Thruk::Base::array2hash($checks, "id");
    is_deeply([sort keys %{$checks}], [
        '_host',
        'inventory',
        'svc',
        'svc.snclient',
        'version'
    ], "process checks found");
    is($checks->{'inventory'}->{'svc_conf'}->{'_WORKER'}, "local", "local inventory");

    ok($checks->{'svc.snclient'}, "service check found");
    is($checks->{'svc.snclient'}->{'name'},   "service snclient", "process: name");
}

###########################################################
# process check
{
    my $conf = <<EOT;
<Component Thruk::Agents>
  <snclient>
    <proc>
      name     = ssh controlmaster %u
      match    ~ /usr/bin/ssh.*ControlMaster=yes
      user     = mon
    </proc>

    <proc>
      name     = controlmaster2
      match    = controlmaster=yes
      user     = mon
    </proc>
  </snclient>
</Component>
EOT

my $inv = <<EOT;
{ "inventory" : {
    "process" : [{
      "command_line" : "/usr/bin/ssh -t -l mon -p 22 -o ControlMaster=yes ...",
      "cpu" : "0.012833",
      "creation" : "1741431198760",
      "exe" : "ssh",
      "filename" : "/usr/bin/ssh",
      "pagefile" : "0",
      "pid" : "3089336",
      "process" : "ssh",
      "rss" : "9097216",
      "state" : "sleep",
      "uid" : "999",
      "username" : "mon",
      "virtual" : "15441920"
    }]
  }
}
EOT

    my $xtr = Thruk::Config::parse_config_from_text($conf);
    $c->config->{'Thruk::Agents'} = $xtr->{'Thruk::Agents'};
    undef $Thruk::Agents::SNClient::conf;
    local $cli_opts->{'cached'} = decode_json($inv);
    my $checks = Thruk::Agents::SNClient::get_services_checks(undef, $c, $hostname, $hostobj, $password, $cli_opts, $section, $mode, $options, $tags);
    $checks = Thruk::Base::array2hash($checks, "id");
    is_deeply([sort keys %{$checks}], [
        '_host',
        'inventory',
        'proc',
        'proc./usr/bin/ssh._ControlMaster_yes_mon',
        'proc.controlmaster_yes_mon',
        'proc.zombies',
        'version'
    ], "process checks found");

    is($checks->{'proc./usr/bin/ssh._ControlMaster_yes_mon'}->{'name'},   "ssh controlmaster mon", "process: name");
    is($checks->{'proc./usr/bin/ssh._ControlMaster_yes_mon'}->{'parent'}, "agent version", "process: parent");
    is($checks->{'proc./usr/bin/ssh._ControlMaster_yes_mon'}->{'args'},   "", "process: args");
    is($checks->{'proc./usr/bin/ssh._ControlMaster_yes_mon'}->{'current_args'}->[1], '"filter=command_line ~~ \'/usr/bin/ssh.*ControlMaster=yes\' and username = \'mon\'"', "process: filter");
    is(scalar @{$checks->{'proc./usr/bin/ssh._ControlMaster_yes_mon'}->{'current_args'}}, 2, "process: filter count");

    is($checks->{'proc.controlmaster_yes_mon'}->{'name'},   "controlmaster2", "process: name");
    is($checks->{'proc.controlmaster_yes_mon'}->{'args'},   "", "process: args");
    is($checks->{'proc.controlmaster_yes_mon'}->{'current_args'}->[1], '"filter=command_line like \'controlmaster=yes\' and username = \'mon\'"', "process: filter");
    is(scalar @{$checks->{'proc.controlmaster_yes_mon'}->{'current_args'}}, 2, "process: filter count");
}

###########################################################
