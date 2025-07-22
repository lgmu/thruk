use warnings;
use strict;
use Cpanel::JSON::XS ();
use Test::More;
use utf8;

plan tests => 59;

BEGIN {
    use lib('t');
    require TestUtils;
    import TestUtils;
}

undef $ENV{'THRUK_MODE'}; # do not die on backend errors

use_ok('Thruk::Utils');
use_ok('Thruk::Utils::Status');
use_ok('Monitoring::Livestatus::Class::Lite');

my $c = TestUtils::get_c();

my $query = "name = 'test'";
_test_filter($query, 'Filter: name = test');
is($query, "name = 'test'", "original string unchanged");
_test_filter('name ~~ "test"',
             'Filter: name ~~ test',
             "name ~~ 'test'");
_test_filter('groups >= "test"', 'Filter: groups >= test', "groups >= 'test'");
_test_filter('check_interval != 5', 'Filter: check_interval != 5');
_test_filter('host_name = "a" AND host_name = "b"',
             "Filter: host_name = a\nFilter: host_name = b\nAnd: 2",
             "host_name = 'a' and host_name = 'b'");
_test_filter('host_name = "a" AND host_name = "b" AND host_name = "c"',
             "Filter: host_name = a\nFilter: host_name = b\nFilter: host_name = c\nAnd: 3",
             "host_name = 'a' and host_name = 'b' and host_name = 'c'");
_test_filter('host_name = "a" OR host_name = "b"',
             "Filter: host_name = a\nFilter: host_name = b\nOr: 2",
             "host_name = 'a' or host_name = 'b'");
_test_filter('host_name = "a" OR host_name = "b" OR host_name = "c"',
             "Filter: host_name = a\nFilter: host_name = b\nFilter: host_name = c\nOr: 3",
             "host_name = 'a' or host_name = 'b' or host_name = 'c'");
_test_filter("(name = 'test')",
             'Filter: name = test',
             "name = 'test'");
_test_filter('(host_name = "a" OR host_name = "b") AND host_name = "c"',
             "Filter: host_name = a\nFilter: host_name = b\nOr: 2\nFilter: host_name = c\nAnd: 2",
             "(host_name = 'a' or host_name = 'b') and host_name = 'c'");
_test_filter("name = 'te\"st'", 'Filter: name = te"st');
_test_filter("name = 'te(st)'", 'Filter: name = te(st)');
_test_filter("host_name = \"test\" or host_name = \"localhost\" and status = 0",
             "Filter: host_name = test\nFilter: host_name = localhost\nOr: 2\nFilter: status = 0\nAnd: 2",
             "(host_name = 'test' or host_name = 'localhost') and status = 0");
_test_filter(' name ~~  "test"  ',
             'Filter: name ~~ test',
             "name ~~ 'test'");
_test_filter('host_name = "localhost" AND time > 1 AND time < 10',
             "Filter: host_name = localhost\nFilter: time > 1\nFilter: time < 10\nAnd: 3",
             "host_name = 'localhost' and time > 1 and time < 10");
_test_filter('host_name = "localhost" AND (time > 1 AND time < 10)',
             "Filter: host_name = localhost\nFilter: time > 1\nFilter: time < 10\nAnd: 2\nAnd: 2",
             "host_name = 'localhost' and (time > 1 and time < 10)");
_test_filter('last_check <= "-7d"', sub { return('Filter: last_check <= '.(time() - 86400*7)); });
_test_filter('last_check <= "now + 2h"', sub { return('Filter: last_check <= '.(time() + 7200)); });
_test_filter('last_check <= "lastyear"', 'Filter: last_check <= '.Thruk::Utils::_expand_timestring("lastyear"));
_test_filter('(host_groups ~~ "g1" AND host_groups ~~ "g2")  OR (host_name = "h1" and display_name ~~ ".*dn.*")',
             "Filter: host_groups ~~ g1\nFilter: host_groups ~~ g2\nAnd: 2\nFilter: host_name = h1\nFilter: display_name ~~ .*dn.*\nAnd: 2\nOr: 2",
             "(host_groups ~~ 'g1' and host_groups ~~ 'g2') or (host_name = 'h1' and display_name ~~ '.*dn.*')");
_test_filter('(host_name = 1) or (host_name = 2) or (host_name = 3)',
             "Filter: host_name = 1\nFilter: host_name = 2\nFilter: host_name = 3\nOr: 3",
             "host_name = 1 or host_name = 2 or host_name = 3");

sub _test_filter {
    my($filter, $expect, $exp_ftext) = @_;
    my($f, $s, $exp);
    # add retry, check depends on time
    for(1..3) {
        $f = Thruk::Utils::Status::parse_lexical_filter($filter);
        $s = Monitoring::Livestatus::Class::Lite->new('test.sock')->table('hosts')->filter($f)->statement(1);
        $s = join("\n", @{$s});
        $exp = $expect;
        if(ref $exp) {
            $exp = &{$expect}();
        }
        $s =~ s/(\d{10})/&_round_timestamps($1)/gemxs;
        $exp =~ s/(\d{10})/&_round_timestamps($1)/gemxs;
        if($s eq $exp) {
            last;
        }
        sleep(1);
    }

    is($s, $exp, 'got correct statement');

    my $txt = Thruk::Utils::Status::filter2text($c, "service", $f);
    is($txt, $exp_ftext//$filter, "filter text is fine") if $filter !~ m/last_check/mx;
}

# round timestamp by 30 seconds to avoid test errors on slow machines
sub _round_timestamps {
    my($x) = @_;
    $x = int($x / 30) * 30;
    return($x);
}

################################################################################
{
    my $params = {
        'dfl_s0_hostprops' => '0',
        'dfl_s0_hoststatustypes' => '15',
        'dfl_s0_op' => [
                        '=',
                        '~'
                        ],
        'dfl_s0_serviceprops' => '0',
        'dfl_s0_servicestatustypes' => '31',
        'dfl_s0_type' => [
                            'host',
                            'service'
                        ],
        'dfl_s0_val_pre' => [
                            '',
                            ''
                            ],
        'dfl_s0_value' => [
                            'localhost',
                            'http'
                        ],
        'dfl_s1_hostprops' => '0',
        'dfl_s1_hoststatustypes' => '15',
        'dfl_s1_op' => '=',
        'dfl_s1_serviceprops' => '0',
        'dfl_s1_servicestatustypes' => '31',
        'dfl_s1_type' => 'host',
        'dfl_s1_val_pre' => '',
        'dfl_s1_value' => 'test'
    };
    my $exp = [{
            'host_prop_filtername'          => 'Any',
            'host_statustype_filtername'    => 'All',
            'hostprops'                     => 0,
            'hoststatustypes'               => 15,
            'service_prop_filtername'       => 'Any',
            'service_statustype_filtername' => 'All',
            'serviceprops'                  => 0,
            'servicestatustypes'            => 31,
            'text_filter'                   => [{
                    'op'        => '=',
                    'type'      => 'host',
                    'val_pre'   => '',
                    'value'     => 'localhost'
                },
                {
                    'op'        => '~',
                    'type'      => 'service',
                    'val_pre'   => '',
                    'value'     => 'http'
                }]
        }, {
            'host_prop_filtername' => 'Any',
            'host_statustype_filtername' => 'All',
            'hostprops' => 0,
            'hoststatustypes' => 15,
            'service_prop_filtername' => 'Any',
            'service_statustype_filtername' => 'All',
            'serviceprops' => 0,
            'servicestatustypes' => 31,
            'text_filter' => [{
                    'op'        => '=',
                    'type'      => 'host',
                    'val_pre'   => '',
                    'value'     => 'test'
                }],
    }];
    my $got = Thruk::Utils::Status::get_searches($c, '', $params);
    is_deeply($got, $exp, "parsed search items from params");
    my $txt = Thruk::Utils::Status::search2text($c, "service", $got);
    my $ext_text = "((host_name = 'localhost' and (description ~~ 'http' or display_name ~~ 'http')) or host_name = 'test')";
    is($txt, $ext_text, "search2text worked")
};

################################################################################
{
    local $ENV{'THRUK_USE_LMD'} = undef;
    my $params = {'dfl_s0_hostprops' => '0','dfl_s0_hoststatustypes' => '15','dfl_s0_op' => '~','dfl_s0_serviceprops' => '0','dfl_s0_servicestatustypes' => '31','dfl_s0_type' => 'hostgroup','dfl_s0_value' => 'test123noneexisting','dfl_s0_value_sel' => '5','style' => 'detail'};
    my $exp = [
          {
            'host_prop_filtername' => 'Any',
            'host_statustype_filtername' => 'All',
            'hostprops' => 0,
            'hoststatustypes' => 15,
            'service_prop_filtername' => 'Any',
            'service_statustype_filtername' => 'All',
            'serviceprops' => 0,
            'servicestatustypes' => 31,
            'text_filter' => [
                               {
                                 'op' => '~',
                                 'type' => 'hostgroup',
                                 'val_pre' => '',
                                 'value' => 'test123noneexisting'
                               }
                             ]
          }
        ];
    my $got = Thruk::Utils::Status::get_searches($c, '', $params);
    is_deeply($got, $exp, "parsed search items from params");
    my $txt = Thruk::Utils::Status::search2text($c, "service", $got);
    my $ext_text = "host_groups >= 'test123noneexisting'";
    is($txt, $ext_text, "search2text worked")
};

################################################################################
{
    my $filter = [
          { '-or' => { 'host_groups' => { '>=' => [ 'test' ] } } }
    ];
    my $txt = Thruk::Utils::Status::filter2text($c, "service", $filter);
    my $ext_text = "host_groups >= 'test'";
    is($txt, $ext_text, "search2text worked")
};

################################################################################
{
    my $filter = [
          { 'name' => ["a", "b", "c"] }
    ];
    my $txt = Thruk::Utils::Status::filter2text($c, "service", $filter);
    my $ext_text = "name = 'a' and name = 'b' and name = 'c'";
    is($txt, $ext_text, "search2text worked")
};

################################################################################
# test broken filter
my $broken = [
    ['_CITY = "Munich" and rta', "/unexpected end of query after/"],
    ['_CITY = "Munich and rta', "/parse error at/"],
    ['_CITY = "Munich" ( and rta', "/unexpected AND at/"],
    ['_CITY = "Munich" ( rta = 1', "/expected closing bracket/"],
];
for my $b (@{$broken}) {
    my $f;
    eval {
        $f = Thruk::Utils::Status::parse_lexical_filter($b->[0]);
    };
    my $err = $@;
    like($err, $b->[1], "query failed to parse");
    is($f, undef, "no filter returned");
}

################################################################################
# test query optimizer
{
    my $filter = {
        '-or' => [
            {
                '-and' => [
                    { 'host_groups' => { '>=' => 'hostgroup_01' } },
                    {
                        '-or' => [
                                    'plugin_output', { '~~' => 'checked' },
                                    'long_plugin_output', { '~~' => 'checked' }
                                ]
                    }
                ]
            }, {
                '-and' => [
                    {
                        'host_groups' => { '>=' => 'hostgroup_01' }
                    },
                    {
                        '-or' => [
                                    'plugin_output', { '~~' => 'checked' },
                                    'long_plugin_output', { '~~' => 'checked' }
                                ]
                    },
                    {
                        '-and' => [
                                    'plugin_output', { '!~~' => 'random' },
                                    'long_plugin_output', { '!~~' => 'random' }
                                ]
                    }
                ]
            }
        ]
    };
    my $exp = {
          '-and' => [
                { '-and' => [ { 'host_groups' => { '>=' => 'hostgroup_01' } } ] },
                {
                '-or' => [
                            {
                                '-and' => [
                                            {
                                            '-or' => [
                                                        'plugin_output', { '~~' => 'checked' },
                                                        'long_plugin_output', { '~~' => 'checked' }
                                                    ]
                                            }
                                        ]
                            },
                            {
                                '-and' => [
                                            {
                                            '-or' => [
                                                        'plugin_output', { '~~' => 'checked' },
                                                        'long_plugin_output', { '~~' => 'checked' }
                                                    ]
                                            },
                                            {
                                            '-and' => [
                                                        'plugin_output', { '!~~' => 'random' },
                                                        'long_plugin_output', { '!~~' => 'random' }
                                                        ]
                                            }
                                        ]
                            }
                            ]
                }
            ]
        };
    my $json = Cpanel::JSON::XS->new->utf8->canonical;
    my $enc  = $json->encode($filter);
    my $optimized = Thruk::Utils::Status::improve_filter($filter);
    my $enc2 = $json->encode($optimized);
    ok($enc ne $enc2, "query can be optimized");
    is_deeply($optimized, $exp, "optimized query is correct");
};
