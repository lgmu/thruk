#!/usr/bin/env perl

use warnings;
use strict;
use Cpanel::JSON::XS qw/encode_json decode_json/;
use Data::Dumper;
use URI::Escape qw/uri_escape/;

use Thruk ();
use Thruk::Action::AddDefaults ();
use Thruk::Controller::cmd ();
use Thruk::Controller::rest_v1 ();
use Thruk::Utils::CLI ();
use Thruk::Utils::Log qw/:all/;
use Thruk::Utils::OAuth ();

################################################################################
my $c = Thruk::Utils::CLI->new()->get_c();
Thruk::Utils::set_user($c, username => '(cli)', auth_src => "scripts", internal => 1, superuser => 1);
$c->stash->{'is_admin'} = 1;
$c->config->{'cluster_enabled'} = 1; # fake cluster
Thruk::setup_cluster() unless defined $Thruk::Globals::NODE_ID;
$c->app->cluster->register($c);
$c->app->cluster->load_statefile();
unlink(glob($c->{'config'}->{'var_path'}.'/obj_retention.*'));
my $res = $c->sub_request('/r/config/objects', 'POST', {':TYPE' => 'host', ':FILE' => 'docs-update-test.cfg', 'name' => 'docs-update-test'});
die("request failed: ".Dumper($res)) unless(ref $res eq 'HASH' && $res->{'message'} && $res->{'message'} =~ m/objects\ successfully/mx);

# get sample host and service
my $test_svc = $c->sub_request('/r/services', 'GET', {'limit' => '1', 'columns' => 'host_name,description,host_groups,groups', 'host_groups[ne]' => '', 'groups[ne]' => '' })->[0] || die("need at least one service which has a hostgroup and a servicegroup");
my $host_name           = $test_svc->{'host_name'};
my $service_description = $test_svc->{'description'};
my $host_group          = $test_svc->{'host_groups'}->[0];
my $service_group       = $test_svc->{'groups'}->[0];

# create example session
Thruk::Utils::OAuth::store_oauth_session($c, "docs-update", ["example-team"]);

my $cmds = _update_cmds($c);
_update_docs($c, "docs/documentation/rest.asciidoc", "lib/Thruk/Controller/Rest/V1/docs.pm");
_update_docs($c, "docs/documentation/rest_commands.asciidoc");
_update_cmds_list($c, "docs/documentation/commands.html", $cmds);
unlink('var/cluster/nodes');
$c->sub_request('/r/config/revert', 'POST', {});
exit 0;

################################################################################
sub _update_cmds {
    my($c) = @_;
    my $output_file = "lib/Thruk/Controller/Rest/V1/cmd.pm";
    my $content = Thruk::Utils::IO::read($output_file);
    $content =~ s/^__DATA__\n.*$/__DATA__\n/gsmx;

    my $input_files = [glob(join(" ", (
                        $c->config->{'project_root'}."/templates/cmd/*.tt",
                        $c->config->{'plugin_path'}."/plugins-enabled/*/templates/cmd/*.tt",
                    )))];

    # add some hard coded extra commands
    my $cmds = {
        'contacts' => {
            'ENABLE_CONTACT_HOST_NOTIFICATIONS'           => {"docs" => "Enables host notifications for a particular contact."},
            'ENABLE_CONTACT_SVC_NOTIFICATIONS'            => {"docs" => "Disables service notifications for a particular contact."},
            'DISABLE_CONTACT_SVC_NOTIFICATIONS'           => {"docs" => "Disables service notifications for a particular contact."},
            'DISABLE_CONTACT_HOST_NOTIFICATIONS'          => {"docs" => "Disables host notifications for a particular contact."},
            'CHANGE_CUSTOM_CONTACT_VAR'                   => {"args" => ["name", "value"], "required" => ["name", "value"], "docs" => "Changes the value of a custom contact variable."},
            'CHANGE_CONTACT_SVC_NOTIFICATION_TIMEPERIOD'  => {"args" => ["timeperiod"], "required" => ["timeperiod"], "docs" => "Changes the service notification timeperiod for a particular contact to what is specified by the \'notification_timeperiod\' option. The \'notification_timeperiod\' option should be the short name of the timeperiod that is to be used as the contact\'s service notification timeperiod. The timeperiod must have been configured in Naemon before it was last (re)started."},
            'CHANGE_CONTACT_HOST_NOTIFICATION_TIMEPERIOD' => {"args" => ["timeperiod"], "required" => ["timeperiod"], "docs" => "Changes the host notification timeperiod for a particular contact to what is specified by the \'notification_timeperiod\' option. The \'notification_timeperiod\' option should be the short name of the timeperiod that is to be used as the contact\'s host notification timeperiod. The timeperiod must have been configured in Naemon before it was last (re)started."},
            # unimplemented in naemon
            #'CHANGE_CONTACT_MODSATTR'                     => {"args" => ["value"], "required" => ["value"], "docs" => "This command changes the modified service attributes value for the specified contact. Modified attributes values are used by Naemon to determine which object properties should be retained across program restarts. Thus, modifying the value of the attributes can affect data retention. This is an advanced option and should only be used by people who are intimately familiar with the data retention logic in Naemon."},
            #'CHANGE_CONTACT_MODHATTR'                     => {"args" => ["value"], "required" => ["value"], "docs" => "This command changes the modified host attributes value for the specified contact. Modified attributes values are used by Naemon to determine which object properties should be retained across program restarts. Thus, modifying the value of the attributes can affect data retention. This is an advanced option and should only be used by people who are intimately familiar with the data retention logic in Naemon."},
            #'CHANGE_CONTACT_MODATTR'                      => {"args" => ["value"], "required" => ["value"], "docs" => "This command changes the modified attributes value for the specified contact. Modified attributes values are used by Naemon to determine which object properties should be retained across program restarts. Thus, modifying the value of the attributes can affect data retention. This is an advanced option and should only be used by people who are intimately familiar with the data retention logic in Naemon."},
        },
        'contactgroups' => {
            'ENABLE_CONTACTGROUP_HOST_NOTIFICATIONS'      => {"docs" => "Enables host notifications for all contacts in a particular contactgroup."},
            'ENABLE_CONTACTGROUP_SVC_NOTIFICATIONS'       => {"docs" => "Enables service notifications for all contacts in a particular contactgroup."},
            'DISABLE_CONTACTGROUP_SVC_NOTIFICATIONS'      => {"docs" => "Disables service notifications for all contacts in a particular contactgroup."},
            'DISABLE_CONTACTGROUP_HOST_NOTIFICATIONS'     => {"docs" => "Disables host notifications for all contacts in a particular contactgroup."},
        },
        'hosts' => {
            'DEL_ACTIVE_HOST_DOWNTIMES'                   => {"docs" => "Removes all currently active downtimes for this host.", "thrukcmd" => 1 },
            'DEL_DOWNTIME'                                => {"args" => ["downtime_id"], "required" => ["downtime_id"], "docs" => "Removes downtime by id for this host.", "thrukcmd" => 1 },
            'DEL_COMMENT'                                 => {"args" => ["comment_id"], "required" => ["comment_id"], "docs" => "Removes downtime by id for this host.", "thrukcmd" => 1 },
            'SET_HOST_NOTIFICATION_NUMBER'                => {"args" => ["number"], "required" => ["number"], "docs" => "Sets the current notification number for a particular host. A value of 0 indicates that no notification has yet been sent for the current host problem. Useful for forcing an escalation (based on notification number) or replicating notification information in redundant monitoring environments. Notification numbers greater than zero have no noticeable affect on the notification process if the host is currently in an UP state."},
            'CHANGE_RETRY_HOST_CHECK_INTERVAL'            => {"args" => ["interval"], "required" => ["interval"], "docs" => "Changes the retry check interval for a particular host."},
            'CHANGE_NORMAL_HOST_CHECK_INTERVAL'           => {"args" => ["interval"], "required" => ["interval"], "docs" => "Changes the normal (regularly scheduled) check interval for a particular host."},
            'CHANGE_MAX_HOST_CHECK_ATTEMPTS'              => {"args" => ["interval"], "required" => ["interval"], "docs" => "Changes the maximum number of check attempts (retries) for a particular host."},
            'CHANGE_HOST_NOTIFICATION_TIMEPERIOD'         => {"args" => ["timeperiod"], "required" => ["timeperiod"], "docs" => "Changes the host notification timeperiod to what is specified by the \'notification_timeperiod\' option. The \'notification_timeperiod\' option should be the short name of the timeperiod that is to be used as the service notification timeperiod. The timeperiod must have been configured in Naemon before it was last (re)started."},
            'CHANGE_HOST_CHECK_TIMEPERIOD'                => {"args" => ["timeperiod"], "required" => ["timeperiod"], "docs" => "Changes the valid check period for the specified host."},
            # not implemented in naemon-core
            #'CHANGE_HOST_EVENT_HANDLER'                   => {"args" => ["eventhandler"], "required" => ["eventhandler"], "docs" => "Changes the event handler command for a particular host to be that specified by the \'event_handler_command\' option. The \'event_handler_command\' option specifies the short name of the command that should be used as the new host event handler. The command must have been configured in Naemon before it was last (re)started."},
            #'CHANGE_HOST_CHECK_COMMAND'                   => {"args" => ["checkcommand"], "required" => ["checkcommand"], "docs" => "Changes the check command for a particular host to be that specified by the \'check_command\' option. The \'check_command\' option specifies the short name of the command that should be used as the new host check command. The command must have been configured in Naemon before it was last (re)started."},
            'CHANGE_CUSTOM_HOST_VAR'                      => {"args" => ["name", "value"], "required" => ["name", "value"], "docs" => "Changes the value of a custom host variable."},
            'NOTE'                                        => {"args" => ["log"], "required" => ["log"], "docs" => "Add host note to core log.", "thrukcmd" => 1, 'cmdname' => 'LOG;HOST NOTE: '  },
        },
        'hostgroups' => {
            'ENABLE_HOSTGROUP_PASSIVE_SVC_CHECKS'         => {"docs" => "Enables passive checks for all services associated with hosts in a particular hostgroup."},
            'ENABLE_HOSTGROUP_PASSIVE_HOST_CHECKS'        => {"docs" => "Enables passive checks for all hosts in a particular hostgroup."},
            'DISABLE_HOSTGROUP_PASSIVE_SVC_CHECKS'        => {"docs" => "Disables passive checks for all services associated with hosts in a particular hostgroup."},
            'DISABLE_HOSTGROUP_PASSIVE_HOST_CHECKS'       => {"docs" => "Disables passive checks for all hosts in a particular hostgroup."},
        },
        'services' => {
            'DEL_ACTIVE_SERVICE_DOWNTIMES'                => {"docs" => "Removes all currently active downtimes for this service.", "thrukcmd" => 1 },
            'DEL_DOWNTIME'                                => {"args" => ["downtime_id"], "required" => ["downtime_id"], "docs" => "Removes downtime by id for this service.", "thrukcmd" => 1 },
            'DEL_COMMENT'                                 => {"args" => ["comment_id"], "required" => ["comment_id"], "docs" => "Removes downtime by id for this service.", "thrukcmd" => 1 },
            'SET_SVC_NOTIFICATION_NUMBER'                 => {"args" => ["number"], "required" => ["number"], "docs" => "Sets the current notification number for a particular service. A value of 0 indicates that no notification has yet been sent for the current service problem. Useful for forcing an escalation (based on notification number) or replicating notification information in redundant monitoring environments. Notification numbers greater than zero have no noticeable affect on the notification process if the service is currently in an OK state."},
            'CHANGE_SVC_NOTIFICATION_TIMEPERIOD'          => {"args" => ["timeperiod"], "required" => ["timeperiod"], "docs" => "Changes the service notification timeperiod to what is specified by the \'notification_timeperiod\' option. The \'notification_timeperiod\' option should be the short name of the timeperiod that is to be used as the service notification timeperiod. The timeperiod must have been configured in Naemon before it was last (re)started."},
            'CHANGE_SVC_CHECK_TIMEPERIOD'                 => {"args" => ["timeperiod"], "required" => ["timeperiod"], "docs" => "Changes the check timeperiod for a particular service to what is specified by the \'check_timeperiod\' option. The \'check_timeperiod\' option should be the short name of the timeperod that is to be used as the service check timeperiod. The timeperiod must have been configured in Naemon before it was last (re)started."},
            # not implemented in naemon-core
            #'CHANGE_SVC_EVENT_HANDLER'                    => {"args" => ["eventhandler"], "required" => ["eventhandler"], "docs" => "Changes the event handler command for a particular service to be that specified by the \'event_handler_command\' option. The \'event_handler_command\' option specifies the short name of the command that should be used as the new service event handler. The command must have been configured in Naemon before it was last (re)started."},
            #'CHANGE_SVC_CHECK_COMMAND'                    => {"args" => ["checkcommand"], "required" => ["checkcommand"], "docs" => "Changes the check command for a particular service to be that specified by the \'check_command\' option. The \'check_command\' option specifies the short name of the command that should be used as the new service check command. The command must have been configured in Naemon before it was last (re)started."},
            'CHANGE_RETRY_SVC_CHECK_INTERVAL'             => {"args" => ["interval"], "required" => ["interval"], "docs" => "Changes the retry check interval for a particular service."},
            'CHANGE_NORMAL_SVC_CHECK_INTERVAL'            => {"args" => ["interval"], "required" => ["interval"], "docs" => "Changes the normal (regularly scheduled) check interval for a particular service"},
            'CHANGE_MAX_SVC_CHECK_ATTEMPTS'               => {"args" => ["attempts"], "required" => ["attempts"], "docs" => "Changes the maximum number of check attempts (retries) for a particular service."},
            'CHANGE_CUSTOM_SVC_VAR'                       => {"args" => ["name", "value"], "required" => ["name", "value"], "docs" => "Changes the value of a custom service variable."},
            'NOTE'                                        => {"args" => ["log"], "required" => ["log"], "docs" => "Add service note to core log.", "thrukcmd" => 1, 'cmdname' => 'LOG;SERVICE NOTE: ' },
        },
        'servicegroups' => {
            'ENABLE_SERVICEGROUP_PASSIVE_SVC_CHECKS'      => {"docs" => "Enables the acceptance and processing of passive checks for all services in a particular servicegroup."},
            'ENABLE_SERViCEGROUP_PASSIVE_HOST_CHECKS'     => {"docs" => "Enables the acceptance and processing of passive checks for all hosts that have services that are members of a particular service group."},
            'DISABLE_SERVICEGROUP_PASSIVE_SVC_CHECKS'     => {"docs" => "Disables the acceptance and processing of passive checks for all services in a particular servicegroup."},
            'DISABLE_SERVICEGROUP_PASSIVE_HOST_CHECKS'    => {"docs" => "Disables the acceptance and processing of passive checks for all hosts that have services that are members of a particular service group."},
        },
        'system' => {
            'READ_STATE_INFORMATION'                      => {"docs" => "Causes Naemon to load all current monitoring status information from the state retention file. Normally, state retention information is loaded when the Naemon process starts up and before it starts monitoring. WARNING: This command will cause Naemon to discard all current monitoring status information and use the information stored in state retention file! Use with care."},
            'RESTART_PROGRAM'                             => {"docs" => "Restarts the Naemon process."},
            'SAVE_STATE_INFORMATION'                      => {"docs" => "Causes Naemon to save all current monitoring status information to the state retention file. Normally, state retention"},
            'SHUTDOWN_PROGRAM'                            => {"docs" => "Shuts down the Naemon process."},
            'ENABLE_SERVICE_FRESHNESS_CHECKS'             => {"docs" => "Enables freshness checks of all services on a program-wide basis. Individual services that have freshness checks disabled will not be checked for freshness."},
            'ENABLE_HOST_FRESHNESS_CHECKS'                => {"docs" => "Enables freshness checks of all services on a program-wide basis. Individual services that have freshness checks disabled will not be checked for freshness."},
            'DISABLE_SERVICE_FRESHNESS_CHECKS'            => {"docs" => "Disables freshness checks of all services on a program-wide basis."},
            'DISABLE_HOST_FRESHNESS_CHECKS'               => {"docs" => "Disables freshness checks of all hosts on a program-wide basis."},
            'CHANGE_GLOBAL_SVC_EVENT_HANDLER'             => {"args" => ["eventhandler"], "required" => ["eventhandler"], "docs" => "Changes the global service event handler command to be that specified by the \'event_handler_command\' option. The \'event_handler_command\' option specifies the short name of the command that should be used as the new service event handler. The command must have been configured in Naemon before it was last (re)started."},
            'CHANGE_GLOBAL_HOST_EVENT_HANDLER'            => {"args" => ["eventhandler"], "required" => ["eventhandler"], "docs" => "Changes the global host event handler command to be that specified by the \'event_handler_command\' option. The \'event_handler_command\' option specifies the short name of the command that should be used as the new host event handler. The command must have been configured in Naemon before it was last (re)started."},
            'LOG'                                         => {"args" => ["log"], "required" => ["log"], "docs" => "Add custom log entry to core log."},
        },
        'all_host_service' => {
            'DEL_DOWNTIME_BY_START_TIME_COMMENT'          => {"args" => ["start_time", "comment"], "required" => [], "docs" => "This command deletes all downtimes matching the specified filters."},
            'DEL_DOWNTIME_BY_HOST_NAME'                   => {"args" => ["hostname", "service_desc", "start_time", "comment"], "required" => [], "docs" => "This command deletes all downtimes matching the specified filters."},
            'DEL_DOWNTIME_BY_HOSTGROUP_NAME'              => {"args" => ["hostgroup_name", "hostname", "service_desc", "start_time", "comment"], "required" => [], "docs" => "This command deletes all downtimes matching the specified filters."},
        }
    };
    for my $category (sort keys %{$cmds}) {
        for my $cmd (sort keys %{$cmds->{$category}}) {
            $cmds->{$category}->{$cmd}->{'name'}     = lc $cmd;
            $cmds->{$category}->{$cmd}->{'args'}     = [] unless $cmds->{$category}->{$cmd}->{'args'};
            $cmds->{$category}->{$cmd}->{'required'} = [] unless $cmds->{$category}->{$cmd}->{'required'};
            $cmds->{$category}->{$cmd}->{'nr'}       = -1 unless defined $cmds->{$category}->{$cmd}->{'nr'};
            $cmds->{$category}->{lc $cmd} = delete $cmds->{$category}->{$cmd};
        }
    }
    for my $file (@{$input_files}) {
        next if $file =~ m/cmd_typ_c\d+/gmx;
        my $nr;
        if($file =~ m/cmd_typ_(\d+)\./gmx) {
            $nr = $1;
        }
        $c->stash->{'require_comments_for_disable_cmds'} = 0;
        my $template = Thruk::Utils::IO::read($file);
        next if $template =~ m/enable_shinken_features/gmx;
        my $fields   = Thruk::Controller::cmd::get_fields_from_template($c, 'cmd/cmd_typ_' . $nr . '.tt', 0, 0);
        my @matches = $template =~ m%^\s*([A-Z_]+)\s*(;|$|)(.*sprintf.*|$)%gmx;
        die("got no command in ".$file) if scalar @matches == 0;
        my $require_comments = $template =~ m/cmd_form_disable_cmd_comment/gmx ? 1 : 0;
        while(scalar @matches > 0) {
            my $name = shift @matches;
            shift @matches;
            my $arg  = shift @matches;
            my $cmd = {
                name => lc $name,
            };

            my @args;
            if($arg) {
                if($arg =~ m/"\s*,([^\)]+)\)/gmx) {
                    @args = split(/\s*,\s*/mx, $1);
                } else {
                    die("cannot parse arguments in ".$file);
                }
            }
            my @required_args;
            for my $field (@{$fields}) {
                next unless $field->{'required'};
                my $key = $field->{'name'};

                # unfortunatly naming is different, so we need to translate some names
                $key = 'triggered_by'       if $key eq 'trigger';
                $key = 'comment_data'       if $key eq 'com_data';
                $key = 'comment_data'       if $key eq 'com_data_disable_cmd';
                $key = 'comment_author'     if $key eq 'com_author';
                $key = 'persistent_comment' if $key eq 'persistent';
                $key = 'sticky_ack'         if $key eq 'sticky';
                $key = 'notification_time'  if $key eq 'not_dly';
                $key = 'downtime_id'        if $key eq 'down_id';
                $key = 'comment_id'         if $key eq 'com_id';
                # some are required but have defaults, so they are not strictly required
                next if $key eq 'comment_author';
                next if $key eq 'start_time';
                next if $key eq 'end_time';

                # comment_data is a false positive if comments are added to other commands
                next if($require_comments && $key eq 'comment_data');
                push @required_args, $key;
            }

            next if $require_comments && $cmd->{'name'} =~ m/add_.*_comment/;

            map {s/_unix$//gmx; } @args;
            if($args[0] && $args[0] eq 'host_name') {
                shift @args;
                shift @required_args;
                if($args[0] && $args[0] eq 'service_desc') {
                    shift @args;
                    shift @required_args;
                    $cmds->{'services'}->{$cmd->{'name'}} = $cmd;
                } else {
                    $cmds->{'hosts'}->{$cmd->{'name'}} = $cmd;
                }
            }
            elsif($args[0] && $args[0] eq 'hostgroup_name') {
                shift @args;
                shift @required_args;
                $cmds->{'hostgroups'}->{$cmd->{'name'}} = $cmd;
            }
            elsif($args[0] && $args[0] eq 'servicegroup_name') {
                shift @args;
                shift @required_args;
                $cmds->{'servicegroups'}->{$cmd->{'name'}} = $cmd;
            } else {
                my $cat = "system";
                if($args[0] && $args[0] =~ m/^(downtime_id|comment_id)$/mx) {
                    $cat = "all_host_service";
                }
                $cmds->{$cat}->{$cmd->{'name'}} = $cmd;
            }
            $cmd->{'args'}     = \@args;
            $cmd->{'required'} = \@required_args;
            # sanity check, there should not be any required parameters which cannot be found in the args list
            my $args_hash = Thruk::Base::array2hash(\@args);
            for my $r (@required_args) {
                die("cannot find required $r in args list for file: ".$file) unless $args_hash->{$r};
            }
            $cmd->{'requires_comment'} = 1 if $require_comments;
            $cmd->{'nr'} = $nr;
        }
    }

    for my $category (qw/hosts services all_host_service hostgroups servicegroups contacts contactgroups system/) {
        for my $name (sort keys %{$cmds->{$category}}) {
            my $cmd = $cmds->{$category}->{$name};
            if($category =~ m/^(hosts|hostgroups|servicegroups|contacts|contactgroups)$/mx) {
                $content .= "# REST PATH: POST /$category/<name>/cmd/$name\n";
            }
            elsif($category =~ m/^(services)$/mx) {
                $content .= "# REST PATH: POST /$category/<host>/<service>/cmd/$name\n";
            }
            elsif($category =~ m/^(system|all_host_service)$/mx) {
                $content .= "# REST PATH: POST /system/cmd/$name\n";
            } else {
                confess("unknown category: ".$category);
            }
            if($cmd->{'docs'}) {
                $content .= "# ".join("\n# ", split/\n/mx, $cmd->{'docs'})."\n#\n";
            } else {
                $content .= "# Sends the ".uc($name)." command.\n#\n";
            }
            if(scalar @{$cmd->{'args'}} > 0) {
                my $optional = [];
                my $required = Thruk::Base::array2hash($cmd->{'required'});
                for my $a (@{$cmd->{'args'}}) {
                    next if $required->{$a};
                    push @{$optional}, $a;
                }
                if(scalar @{$cmd->{'required'}} > 0) {
                    $content .= "# Required arguments:\n#\n#   * ".join("\n#   * ", @{$cmd->{'required'}})."\n";
                    if(scalar @{$optional} > 0) {
                        $content .= "#\n";
                    }
                }
                if(scalar @{$optional} > 0) {
                    $content .= "# Optional arguments:\n#\n#   * ".join("\n#   * ", @{$optional})."\n";
                }
            } else {
                $content .= "# This command does not require any arguments.\n";
            }
            $content .= "#\n";
            if(!$cmd->{'thrukcmd'}) {
                $content .= "# See https://www.naemon.io/documentation/developer/externalcommands/$name.html for details.\n";
                $content .= "\n";
            }
        }
    }

    my $cmd_dump = Cpanel::JSON::XS->new->utf8->canonical->encode($cmds);
    $cmd_dump    =~ s/\},/},\n  /gmx;
    $cmd_dump    =~ s/\ *"(hostgroups|hosts|services|all_host_service|servicegroups|system|contacts|contactgroups)":\{/"$1":{\n  /gmx;
    $cmd_dump    =~ s/\}$/\n}/gmx;
    $cmd_dump    =~ s/\}\},$/}\n},/gmx;
    $content .= $cmd_dump;

    $output_file = 'cmd.pm.tst' if $ENV{'TEST_MODE'};
    open(my $fh, '>', $output_file) or die("cannot write to ".$output_file.': '.$@);
    print $fh $content;
    close($fh);

    return($cmds);
}

################################################################################
sub _update_docs {
    my($c, $output_file, $json_file) = @_;

    if($ENV{'THRUK_USE_LMD'}) {
        require Thruk::Utils::LMD;
        Thruk::Utils::LMD::check_changed_lmd_config($c, $c->config);
    }

    my($paths, $keys, $docs) = Thruk::Controller::rest_v1::get_rest_paths();
    `mkdir -p bp;            cp t/scenarios/cli_api/omd/1.tbp bp/9999.tbp`;
    `mkdir -p panorama;      cp t/scenarios/cli_api/omd/1.tab panorama/9999.tab`;
    `mkdir -p var/broadcast; cp t/scenarios/rest_api/omd/broadcast.json var/broadcast/broadcast.json`;
    `mkdir -p var/downtimes; cp t/scenarios/cli_api/omd/1.tsk var/downtimes/9999.tsk`;
    `mkdir -p var/reports;   cp t/scenarios/cli_api/omd/1.rpt var/reports/9999.rpt`;
    my $system_api_key = decode_json(`./script/thruk r -d "comment=test" -d "system=1" -d "roles=admin" -d "force_user=test" /thruk/api_keys`);
    my $api_key = decode_json(`./script/thruk r -d "comment=test" -d "username=restapidocs" /thruk/api_keys`);
    # fake usage
    Thruk::Utils::IO::json_lock_store($api_key->{'file'}.".stats", { last_used => time(), last_from => "127.0.0.1" });
    # fake error message
    Thruk::Utils::IO::json_lock_patch('var/downtimes/9999.tsk', { error => "test" });
    # fake error message
    Thruk::Utils::IO::json_lock_patch('var/reports/9999.rpt', { error => "test" });
    # fake panorama maintmode
    Thruk::Utils::IO::json_lock_patch('panorama/9999.tab', { maintenance => "test" });

    my $login = "thrukadmin";
    my $userdata = Thruk::Utils::get_user_data($c, $login);
    $userdata->{'login'}->{'last_success'} = { time => time(), ip => "127.0.0.1", forwarded_for => "" };
    Thruk::Utils::store_user_data($c, $userdata, $login);

    # set fake logcache
    $c->config->{'logcache'} = 'mysql://user:pw@localhost:3306/thruk' unless $c->config->{'logcache'};

    # create fake outages
    if($output_file =~ m/rest.asciidoc/mx) {
        local $ENV{'THRUK_TEST_NO_AUDIT_LOG'} = 1;
        local $ENV{'THRUK_TEST_NO_LOG'}       = "";
        my $host         = uri_escape($host_name);
        my $service      = uri_escape($service_description);
        my $hostgroup    = uri_escape($host_group);
        my $servicegroup = uri_escape($service_group);
        Thruk::Action::AddDefaults::set_enabled_backends($c);
        $c->req->parameters->{'plugin_state'}  = 2;
        $c->req->parameters->{'plugin_output'} = "$0 test";
        Thruk::Controller::rest_v1::process_rest_request($c, "/hosts/".$host."/cmd/process_host_check_result", "POST");
        Thruk::Controller::rest_v1::process_rest_request($c, "/services/".$host."/".$service."/cmd/process_service_check_result", "POST");
        sleep(1);
        Thruk::Controller::rest_v1::process_rest_request($c, "/hosts/".$host."/cmd/schedule_forced_host_check", "POST");
        Thruk::Controller::rest_v1::process_rest_request($c, "/services/".$host."/".$service."/cmd/schedule_forced_svc_check", "POST");
        sleep(1);
        # run logcache update if applicable
        Thruk::Controller::rest_v1::process_rest_request($c, "/thruk/logcache/update", "POST") if $c->config->{'logcache'};
    };

    my $content    = Thruk::Utils::IO::read($output_file);
    my $attributes = _parse_attribute_docs($content);
    $content =~ s/^(\QSee examples and detailed description for\E.*?:).*$/$1\n\n/gsmx;

    # add generic cmd url with cross links to command page
    my $raw_json = {};
    my $command_urls = {};
    for my $url (sort keys %{$paths}) {
        next if $url !~ m%/cmd/%mx;
        my $baseurl = $url;
        $baseurl =~ s%/cmd/.*%/cmd%gmx;
        $command_urls->{$baseurl} = [] unless defined $command_urls->{$baseurl};
        push @{$command_urls->{$baseurl}}, $url;
    }
    for my $url (sort keys %{$command_urls}) {
        my $doc = [
            "external commands are documented in detail on a separate commands page.",
            "list of supported commands:",
            "",
        ];
        for my $cmd (@{$command_urls->{$url}}) {
            my $name = $cmd;
            $name =~ s%.*/cmd/%%gmx;
            my $link = $cmd;
            $link =~ s%[/<>]+%%gmx;
            $link =~ s%[^a-z_]+%-%gmx;
            push @{$doc}, " - link:rest_commands.html#post-".$link."[".$name."]";
        }
        $docs->{$url.'/...'}->{'POST'} = $doc;
        $paths->{$url.'/...'}->{'POST'} = 1;
    }

    for my $url (sort keys %{$paths}) {
        if($output_file =~ m/_commands/mx) {
            next if($url !~ m%/cmd/%mx || $url =~ m%/cmd/\.\.\.%mx);
        } else {
            next if($url =~ m%/cmd/%mx && $url !~ m%/cmd/\.\.\.%mx);
        }
        for my $proto (sort _sort_by_proto (keys %{$paths->{$url}})) {
            $content .= "=== $proto $url\n\n";
            my $doc   = $docs->{$url}->{$proto} ? join("\n", @{$docs->{$url}->{$proto}})."\n\n" : '';
            $content .= $doc;

            if(!$keys->{$url}->{$proto}) {
                $keys->{$url}->{$proto} = _fetch_keys($c, $proto, $url, $doc);
            }
            if(!$keys->{$url}->{$proto} && $attributes->{$url}->{$proto}) {
                $keys->{$url}->{$proto} = [];
                for my $key (sort keys %{$attributes->{$url}->{$proto}}) {
                    push @{$keys->{$url}->{$proto}}, [$key, @{$attributes->{$url}->{$proto}->{$key}}];
                }
            }
            if($keys->{$url}->{$proto}) {
                $raw_json->{$url}->{$proto} = { columns => [] };
                $content .= '[options="header"]'."\n";
                $content .= "|===========================================\n";
                $content .= sprintf("|%-33s | %-10s | %-8s | %s\n", 'Attribute', 'Type', 'Unit', 'Description');
                for my $doc (@{$keys->{$url}->{$proto}}) {
                    my $name =  $doc->[0];
                    my $typ  = Thruk::Base::trim_whitespace($doc->[1] || $attributes->{$url}->{$proto}->{$name}->[0] || '' );
                    my $unit = Thruk::Base::trim_whitespace($doc->[2] || $attributes->{$url}->{$proto}->{$name}->[1] || '' );
                    my $desc = Thruk::Base::trim_whitespace($doc->[3] || $attributes->{$url}->{$proto}->{$name}->[2] || '' );
                    if(!$typ && !$unit) {
                        ($typ, $unit) = Thruk::Controller::rest_v1::guess_field_type($url, $name);
                    }
                    if($typ && $typ ne 'time' && $typ ne 'number') {
                        die("unknown typ in $url ($name): $typ");
                    }

                    if($name eq 'peer_key')     { $desc = "id as defined in Thruk::Backend component configuration"; }
                    if($name eq 'peer_name')    { $desc = "name as defined in Thruk::Backend component configuration"; }
                    if($name eq 'peer_section') { $desc = "section as defined in Thruk::Backend component configuration"; }
                    if($url eq '/thruk/stats') {
                        my $help = Thruk::Utils::IO::json_lock_retrieve($c->{'config'}->{'var_path'}.'/thruk.stats.help');
                        $desc = $help->{$name};
                    }
                    next if $name eq 'page_profiles';
                    _warn("no documentation on url %s for attribute %s\n", $url, $name) unless $desc;
                    $content .= sprintf("|%-33s | %-10s | %-8s | %s\n", $name, $typ, $unit, $desc);
                    push @{$raw_json->{$url}->{$proto}->{'columns'}}, { 'type' => $typ, 'unit' => $unit, 'name' => $name, 'description' => $desc };
                }
                $content .= "|===========================================\n\n\n";
            }
        }
    }

    # trim trailing whitespace
    $content =~ s/\ +$//gmx;

    $output_file = $output_file.'.tst' if $ENV{'TEST_MODE'};
    open(my $fh, '>', $output_file) or die("cannot write to ".$output_file.': '.$@);
    print $fh $content;
    close($fh);

    if($json_file && !$ENV{'TEST_MODE'}) {
        my $content = Thruk::Utils::IO::read($json_file);
        $content =~ s/^__DATA__\n.*$/__DATA__\n/gsmx;
        open(my $fh, '>', $json_file) or die("cannot write to ".$json_file.': '.$@);
        my $raw_dump = Cpanel::JSON::XS->new->utf8->canonical->pretty->indent_length(1)->space_before(0)->encode($raw_json);
        print $fh $content;
        print $fh $raw_dump;
        close($fh);
    }

    unlink('bp/9999.tbp');
    unlink('panorama/9999.tab');
    unlink('var/broadcast/broadcast.json');
    unlink('var/downtimes/9999.tsk');
    unlink('var/reports/9999.rpt');
    unlink($api_key->{'file'});
    unlink($api_key->{'file'}.'.stats');
    unlink($system_api_key->{'file'});
}

################################################################################
sub _update_cmds_list {
    my($c, $file, $cmds) = @_;
    my $content = Thruk::Utils::IO::read($file);
    $content =~ s/^<\!\-\-DATA\-\->\n.*$/<!--DATA-->\n/gsmx;

    $content .= "<tbody>\n";
    for my $cat (qw/hosts services all_host_service hostgroups servicegroups contacts contactgroups system/) {
        for my $name (sort keys %{$cmds->{$cat}}) {
            my $cmd = $cmds->{$cat}->{$name};
            next if !$cmd->{'nr'};
            next if $cmd->{'nr'} == -1;
            $content .= "<tr>";
            $content .= sprintf("<td>%s</td>", $cmd->{'nr'});
            $content .= sprintf("<td>%s</td>", $cat);
            $content .= sprintf("<td>%s</td>", $name);
            $content .= sprintf("<td><a href=\"https://www.naemon.io/documentation/developer/externalcommands/%s.html\" target=\"_blank\">details</a></td>", $name);
            $content .= "</tr>\n";
        }
    }
    $content .= "</tbody>\n";
    $content .= "</table>\n";

    $file = $file.'.tst' if $ENV{'TEST_MODE'};
    open(my $fh, '>', $file) or die("cannot write to ".$file.': '.$@);
    print $fh $content;
    close($fh);
}

################################################################################
sub _fetch_keys {
    my($c, $proto, $url, $doc) = @_;

    return if $proto ne 'GET';
    return if $doc =~ m/alias|https?:/mxi;
    return if $url eq '/thruk/jobs/<id>/output';
    return if $url eq '/thruk/reports/<nr>/report';
    return if $url eq '/thruk/cluster/heartbeat';
    return if $url eq '/thruk/config';
    return if $url =~ '/thruk/editor';
    return if $url =~ '/thruk/nc';
    return if $url =~ '/thruk/node-control';
    return if $url eq '/config/objects';
    return if $url eq '/config/fullobjects';
    return if($url eq '/lmd/sites' && !$ENV{'THRUK_USE_LMD'});
    return if $doc =~ m/see\ /mxi;

    my $host         = uri_escape($host_name);
    my $service      = uri_escape($service_description);
    my $hostgroup    = uri_escape($host_group);
    my $servicegroup = uri_escape($service_group);

    my $keys = {};
    $c->{'rendered'} = 0;
    for my $param (sort keys %{$c->req->parameters}) {
        delete $c->req->parameters->{$param};
    }
    _info("fetching keys for %s", $url);
    my $tst_url = $url;
    $tst_url =~ s|<nr>|9999|gmx;
    $tst_url =~ s|<id>|$Thruk::Globals::NODE_ID|gmx if $tst_url =~ m%/cluster/%mx;
    $tst_url =~ s|/hostgroups/<name>|/hostgroups/$hostgroup|gmx;
    $tst_url =~ s|/servicegroups/<name>|/servicegroups/$servicegroup|gmx;
    $tst_url =~ s|<name>|$host|gmx;
    $tst_url =~ s|<host>|$host|gmx;
    $tst_url =~ s|<service>|$service|gmx;
    if($tst_url eq "/config/files") {
        # column would be optimized away otherwise
        $c->req->parameters->{'sort'} = "content";
    }
    if($tst_url =~ "/outages") {
        $c->req->parameters->{'includesoftstates'} = 1;
    }
    Thruk::Action::AddDefaults::set_enabled_backends($c);
    my $data = Thruk::Controller::rest_v1::process_rest_request($c, $tst_url);
    if($data && ref($data) eq 'ARRAY' && $data->[0] && ref($data->[0]) eq 'HASH') {
        # combine keys from all results
        for my $d (@{$data}) {
            for my $k (sort keys %{$d}) {
                $k =~ s/^panlet_\d+/panlet_<nr>/mx;
                $keys->{$k} = 1;
            }
        }
    }
    elsif($data && ref($data) eq 'HASH' && !$data->{'code'}) {
        for my $k (sort keys %{$data}) {
            $keys->{$k} = 1;
        }
    }
    else {
        _warn("got no usable data in url %s", $tst_url);
        _warn($data);
        return;
    }
    my $list = [];
    for my $k (sort keys %{$keys}) {
        push @{$list}, [$k, "", "", ""];
    }
    return $list;
}

################################################################################
sub _sort_by_proto {
    my $weight = {
        'GET'    => 1,
        'POST'   => 2,
        'PATCH'  => 3,
        'DELETE' => 4,
    };
    ($weight->{$a}//99) <=> ($weight->{$b}//99);
}

################################################################################
sub _parse_attribute_docs {
    my($content) = @_;
    my $attributes = {};
    my($url, $proto);
    for my $line (split/\n/mx, $content) {
        if($line =~ m%^=%mx) {
            $url = undef;
        }
        if($line =~ m%^===\ (\w+)\ (/.*)$%mx) {
            $proto = $1;
            $url   = $2;
        }
        if($url && $line =~ m%^\|([^\|]+?)\s*\|([^\|]+?)\s*\|([^\|]+?)\s*\|\s*(.*)$%mx) {
            next if $1 eq 'Attribute';
            $attributes->{$url}->{$proto}->{$1} = [$2, $3, $4];
        }
        elsif($url && $line =~ m%^\|([^\|]+?)\s*\|\s*(.*)$%mx) {
            next if $1 eq 'Attribute';
            $attributes->{$url}->{$proto}->{$1} = ["", "", $2];
        }
    }
    return $attributes;
}

################################################################################
