use warnings;
use strict;
use Cpanel::JSON::XS;
use Test::More;

die("*** ERROR: this test is meant to be run with PLACK_TEST_EXTERNALSERVER_URI set,\nex.: THRUK_TEST_AUTH=omdadmin:omd PLACK_TEST_EXTERNALSERVER_URI=http://localhost:60080/demo perl t/scenarios/rest_api/t/301-controller_rest_scenario.t") unless defined $ENV{'PLACK_TEST_EXTERNALSERVER_URI'};

BEGIN {
    plan tests => 490;

    use lib('t');
    require TestUtils;
    import TestUtils;
}

use_ok 'Thruk::Controller::rest_v1';
TestUtils::set_test_user_token();
my($host,$service) = ('localhost', 'Users');

my $pages = [{
        url          => '/services/localhost/Ping/cmd/schedule_forced_svc_check',
        post         => { 'start_time' => 'now' },
        like         => ['Command successfully submitted'],
    }, {
        url          => '/services/localhost/Disk%20%2F/cmd/schedule_forced_svc_check',
        post         => { 'start_time' => 'now' },
        like         => ['Command successfully submitted'],
    }, {
        url          => '/services/localhost/Disk%20%2Fvar%2Flog/cmd/schedule_forced_svc_check',
        post         => { 'start_time' => 'now' },
        like         => ['Command successfully submitted'],
    }, {
        url          => '/services/localhost/Http/cmd/schedule_forced_svc_check',
        post         => { 'start_time' => 'now' },
        like         => ['Command successfully submitted'],
    }, {
        url          => '/services/localhost/Https/cmd/schedule_forced_svc_check',
        post         => { 'start_time' => 'now' },
        like         => ['Command successfully submitted'],
    }, {
        url          => '/csv/services?q=***description ~ http and description !~ cert***&columns=description',
        like         => ['Https'],
        unlike       => ['Cert'],
        content_type => 'text/plain; charset=utf-8',
    }, {
        url          => '/csv/services/totals?q=***description ~ http and description !~ cert***&columns=total',
        like         => ['total;2'],
        content_type => 'text/plain; charset=utf-8',
    }, {
        url          => '/csv/services?columns=count(*):num,host_name&sort=-count(*)',
        like         => ['10;localhost'],
        content_type => 'text/plain; charset=utf-8',
    }, {
        url          => '/services/'.$host.'/'.$service.'/cmd/schedule_svc_downtime',
        post         => { 'start_time' => 'now', 'end_time' => '+60m', 'comment_data' => 'test comment' },
        like         => ['Command successfully submitted'],
    }, {
        url          => '/system/cmd/del_downtime_by_host_name',
        method       => 'POST',
        post         => { 'hostname' => "localhost", 'comment' => "commentfilter" },
        like         => ['DEL_DOWNTIME_BY_HOST_NAME', ';localhost;;;commentfilter'],
    }, {
        url          => '/downtimes',
        like         => ['"test comment",', 'omdadmin'],
    }, {
        url          => '/services/localhost/Ping?columns=perf_data_expanded',
        like         => ['"rta"'],
        waitfor      => '"rta"',
    }, {
        url          => '/services?columns=rta&rta[gt]=0',
        like         => ['"rta" : 0.\d+'],
    }, {
        url          => '/services?columns=rta&rta[gt]=0&_WORKER[ne]=test&_HOSTWORKER[ne]=test',
        like         => ['"rta" : 0.\d+'],
    }, {
        url          => '/logs?q=***type = "EXTERNAL COMMAND"***',
        like         => ['EXTERNAL COMMAND'],
    }, {
        url          => '/logs?q=***type = "EXTERNAL COMMAND" and time > '.(time() - 600).'***',
        like         => ['EXTERNAL COMMAND'],
    }, {
        url          => '/services/outages?q=***host = "localhost" and service = "Ping" and timeperiod = "today"***',
        like         => ['\[\]'],
    }, {
        url          => '/services/localhost/Ping/config',
        method       => 'PATCH',
        post         => { 'use' => ["generic-service", "srv-perf"] },
        like         => ['changed 1 objects successfully'],
    }, {
        url          => '/config/diff',
        like         => ['conf.d/example.cfg', 'generic\-service,srv\-perf'],
    }, {
        url          => '/config/revert',
        post         => {},
        like         => ['successfully reverted stashed changes'],
    }, {
        url          => '/services/localhost/Ping/config',
        method       => 'PATCH',
        post         => { 'use' => ["does_not_exist"] },
        like         => ['changed 1 objects successfully'],
    }, {
        url          => '/config/precheck',
        like         => ['referenced template', 'does_not_exist', 'does not exist in example.cfg', '"failed" : true'],
    }, {
        url          => '/config/revert',
        post         => {},
        like         => ['successfully reverted stashed changes'],
    }, {
        url          => '/thruk/panorama',
        like         => ['title'],
    }, {
        url          => '/thruk/panorama/1',
        like         => ['title'],
    }, {
        url          => '/thruk/panorama/1/maintenance',
        post         => { text => "test maint mode" },
        like         => ['put into maintenance mode'],
    }, {
        url          => '/thruk/panorama/1',
        like         => ['maintenance', "test maint mode"],
    }, {
        url          => '/thruk/panorama/1/maintenance',
        method       => 'DELETE',
        like         => ['maintenance mode removed'],
    }, {
        url          => '/servicegroups/?q=***name = "Http Check"***&columns=worst_service_state',
        like         => ['worst_service_state'],
    }, {
        url          => '/services/localhost/Disk%20%2F/config',
        like         => ['example.cfg:'],
    }
];

for my $test (@{$pages}) {
    $test->{'content_type'} = 'application/json; charset=utf-8' unless $test->{'content_type'};
    $test->{'url'}          = '/thruk/r'.$test->{'url'};
    my $page = TestUtils::test_page(%{$test});
}

################################################################################
# test offset
{
    my $page = TestUtils::test_page(
        url => '/thruk/r/services?columns=host_name,description',
    );
    my $tstdata = Cpanel::JSON::XS::decode_json($page->{'content'});
    is(scalar @{$tstdata}, 12, "number of services");

    $page = TestUtils::test_page(
        url => '/thruk/r/services?columns=host_name,description&offset=1',
    );
    my $data = Cpanel::JSON::XS::decode_json($page->{'content'});
    is(scalar @{$data}, 11, "number of services");
    is($data->[0]->{'host_name'}, $tstdata->[1]->{'host_name'}, "got correct index");
    is($data->[0]->{'description'}, $tstdata->[1]->{'description'}, "got correct index");

    $page = TestUtils::test_page(
        url => '/thruk/r/services?columns=host_name,description&offset=1&limit=2',
    );
    $data = Cpanel::JSON::XS::decode_json($page->{'content'});
    is(scalar @{$data}, 2, "number of services");
    is($data->[0]->{'host_name'}, $tstdata->[1]->{'host_name'}, "got correct index");
    is($data->[0]->{'description'}, $tstdata->[1]->{'description'}, "got correct index");
};

################################################################################
# test aggregation functions
{
    my $page = TestUtils::test_page(
        url => '/thruk/r/services?columns=avg(execution_time),state&sort=avg(execution_time)&host_name='.$host.'&avg(execution_time)[gte]=0.000001',
    );
    my $tstdata = Cpanel::JSON::XS::decode_json($page->{'content'});
    ok(scalar @{$tstdata} > 0, "got result");
    ok(defined $tstdata->[0]->{'state'}, "got result");

    $page = TestUtils::test_page(
        url => '/thruk/r/hosts?columns=min(state),max(state),avg(state),count(state),sum(state)',
    );
    $tstdata = Cpanel::JSON::XS::decode_json($page->{'content'});
    is(scalar keys %{$tstdata}, 5, "got result");
    is($tstdata->{'min(state)'}, 0, "got min state");
    is($tstdata->{'count(state)'}, 3, "got count state");
};

################################################################################
# test aggregation functions with alias and filter
{
    my $page = TestUtils::test_page(
        url  => '/thruk/r/services?columns=count(*):total,state&sort=total&host_name='.$host.'&total[gte]=0',
        fail => 1,
    );
    my $tstdata = Cpanel::JSON::XS::decode_json($page->{'content'});
    is(ref $tstdata, 'HASH', "got error result") or TestUtils::bail_out_req("expected HASH result", $page->{'response'}, 1);
    is($tstdata->{'failed'}, Cpanel::JSON::XS::true, "query should fail");
    like($tstdata->{'description'}, qr(alias column names cannot be used in filter), "query should fail");
};

################################################################################
# test query on custom variables
{
    TestUtils::test_page(
        'url'          => '/thruk/r/hosts?columns=name&q=***_WORKER = "local"***',
        'content_type' => 'application/json; charset=utf-8',
        'method'       => 'GET',
        'like'         => ['Test Business Process'],
    );
    TestUtils::test_page(
        'url'          => '/thruk/cgi-bin/status.cgi?explore=1&style=detail&dfl_q=_WORKER+%3D+"local"',
        'method'       => 'GET',
        'like'         => ['Test Business Process', 'Explore Services'],
    );
};

################################################################################
# test query on custom variables
{
    TestUtils::test_page(
        'url'          => '/thruk/r/hosts?columns=name&q=***_WORKER != "local"***',
        'content_type' => 'application/json; charset=utf-8',
        'method'       => 'GET',
        'like'         => ['localhost'],
    );
    TestUtils::test_page(
        'url'          => '/thruk/cgi-bin/status.cgi?explore=1&style=detail&dfl_q=_WORKER+!%3D+"local"',
        'method'       => 'GET',
        'like'         => ['localhost', 'Explore Services'],
    );
};

################################################################################
# test query with tranformation functions
{
    TestUtils::test_page(
        'url'          => '/thruk/r/csv/hosts?columns=upper(name):HOST',
        'content_type' => 'text/plain; charset=utf-8',
        'method'       => 'GET',
        'like'         => ['LOCALHOST'],
    );
    TestUtils::test_page(
        'url'          => '/thruk/r/csv/hosts?columns=upper(substr(name, 0,3)) as HOST',
        'content_type' => 'text/plain; charset=utf-8',
        'method'       => 'GET',
        'like'         => ['LOC\\n'],
    );
    TestUtils::test_page(
        'url'          => '/thruk/r/csv/hosts?columns=lc(_WORKER)',
        'content_type' => 'text/plain; charset=utf-8',
        'method'       => 'GET',
        'like'         => ['local\\n'],
    );
};

################################################################################
# test query with timeperiod from query
{
    TestUtils::test_page(
        'url'          => '/thruk/r/hosts/localhost/availability?q=***timeperiod = lastweek***',
        'method'       => 'GET',
        'content_type' => 'application/json; charset=utf-8',
        'like'         => ['time_indeterminate_nodata', '604800'],
    );
    TestUtils::test_page(
        'url'          => '/thruk/r/hosts/localhost/availability?q=***(time >= yesterday and time <= today)***',
        'method'       => 'GET',
        'content_type' => 'application/json; charset=utf-8',
        'like'         => ['time_indeterminate_nodata', '86400'],
    );
    TestUtils::test_page(
        'url'          => '/thruk/r/hosts/localhost/availability?q=***time >= yesterday and time <= today***',
        'method'       => 'GET',
        'content_type' => 'application/json; charset=utf-8',
        'like'         => ['time_indeterminate_nodata', '86400'],
    );
    TestUtils::test_page(
        'url'          => '/thruk/r/hosts/localhost/availability?q=***time >= yesterday***',
        'method'       => 'GET',
        'content_type' => 'application/json; charset=utf-8',
        'like'         => ['time_indeterminate_nodata'],
    );
    TestUtils::test_page(
        'url'          => '/thruk/r/hosts/localhost/availability?q=***(time >= yesterday)***',
        'method'       => 'GET',
        'content_type' => 'application/json; charset=utf-8',
        'like'         => ['time_indeterminate_nodata'],
    );
};

################################################################################
# test service totals / stats with host custom vars
{
    TestUtils::test_page(
        'url'          => '/thruk/r/services?columns=host_name,description&q=***description = "Disk /var/log" and _HOSTTEST = "test var host"***',
        'content_type' => 'application/json; charset=utf-8',
        'like'         => ['Disk', 'UPPERC'],
    );

    TestUtils::test_page(
        'url'          => '/thruk/r/services/totals?q=***description = "Disk /var/log" and _HOSTTEST = "test var host"***',
        'content_type' => 'application/json; charset=utf-8',
        'like'         => ['"total" : 1,'],
    );

    TestUtils::test_page(
        'url'          => '/thruk/r/services/totals?q=***_HOSTTEST = "test var host"***',
        'content_type' => 'application/json; charset=utf-8',
        'like'         => ['"total" : 1,'],
    );

    TestUtils::test_page(
        'url'          => '/thruk/r/services/totals?_HOSTTEST=test%20var%20host',
        'content_type' => 'application/json; charset=utf-8',
        'like'         => ['"total" : 1,'],
    );

    TestUtils::test_page(
        'url'          => '/thruk/r/services/totals?description=Disk%20%2Fvar%2Flog&_HOSTTEST=test%20var%20host',
        'content_type' => 'application/json; charset=utf-8',
        'like'         => ['"total" : 1,'],
    );

    TestUtils::test_page(
        'url'          => '/thruk/r/checks/stats?description=Disk%20%2Fvar%2Flog&_HOSTTEST=test%20var%20host',
        'content_type' => 'application/json; charset=utf-8',
        'like'         => ['"hosts_active_sum" : 3,', 'services_active_sum'],
        'waitfor'      => '"hosts_active_sum" : 3,',
    );
}

################################################################################
# test service perf data containing slashes
{
    TestUtils::test_page(
        'url'          => '/thruk/r/services?description=Disk%20%2Fvar%2Flog&columns=%2Fvar%2Flog',
        'content_type' => 'application/json; charset=utf-8',
        'like'         => ['/var/log', '231490977792'],
    );

    TestUtils::test_page(
        'url'          => '/thruk/r/services?description=Disk%20%2Fvar%2Flog&columns=`/var/log`',
        'content_type' => 'application/json; charset=utf-8',
        'like'         => ['/var/log', '231490977792'],
    );

    TestUtils::test_page(
        'url'          => '/thruk/r/services?description=Ping&columns=rta*0,rta/0',
        'content_type' => 'application/json; charset=utf-8',
        'like'         => ['"rta\*0" : 0', '"rta/0" : ""'],
    );
}

################################################################################
# using service_description as columns name
{
    TestUtils::test_page(
        'url'          => '/thruk/r/services/stats?service_description=Disk%20%2Fvar%2Flog',
        'content_type' => 'application/json; charset=utf-8',
        'like'         => ['"total" : 2,'],
    );
}

################################################################################
# test limit when having aggregation functions
{
    TestUtils::test_page(
        'url'          => '/thruk/r/services?columns=count(*):num&limit=3',
        'like'         => ['"num" : 12'],
    );
};

################################################################################
