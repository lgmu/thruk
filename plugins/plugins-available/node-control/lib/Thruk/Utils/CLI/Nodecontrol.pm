package Thruk::Utils::CLI::Nodecontrol;

=head1 NAME

Thruk::Utils::CLI::Nodecontrol - NodeControl CLI module

=head1 DESCRIPTION

The nodecontrol command can start node control commands.

=head1 SYNOPSIS

  Usage: thruk [globaloptions] nc <cmd> [options]

=head1 OPTIONS

=over 4

=item B<help>

    print help and exit

=item B<cmd>

    available commands are:

    - -l|list <backendid|all>                        list available backends.
    - facts   <backendid|all>  [-w|--worker=<nr>]    update facts for given backend.
    - runtime <backendid|all>  [-w|--worker=<nr>]    update runtime data for given backend.
    - setversion <version>                           set new default omd version
    - install <backendid|all>  [--version=<version]  install default omd version for given backend.
    - update  <backendid|all>  [--version=<version]  update default omd version for given backend.
    - cleanup <backendid|all>                        cleanup unused omd versions for given backend.

=back

=cut

use warnings;
use strict;
use Carp;
use Getopt::Long ();
use Time::HiRes qw/gettimeofday tv_interval/;

use Thruk::Utils ();
use Thruk::Utils::CLI ();
use Thruk::Utils::Log qw/:all/;

##############################################

=head1 METHODS

=head2 cmd

    cmd([ $options ])

=cut
sub cmd {
    my($c, $action, $commandoptions, $data, $src, $global_options) = @_;
    $data->{'all_stdout'} = 1;

    $c->stats->profile(begin => "_cmd_nc()");

    if(!$c->check_user_roles('authorized_for_admin')) {
        return("ERROR - authorized_for_admin role required", 1);
    }

    if(scalar @{$commandoptions} == 0) {
        return(Thruk::Utils::CLI::get_submodule_help(__PACKAGE__));
    }

    eval {
        require Thruk::NodeControl::Utils;
    };
    if($@) {
        _debug($@);
        return("node control plugin is not enabled.\n", 1);
    }

    my $config = Thruk::NodeControl::Utils::config($c);
    # parse options
    my $opt = {
      'worker'    => $config->{'parallel_tasks'} // 3,
      'version'   => $config->{'version'},
      'mode_list' => 0,
    };
    Getopt::Long::Configure('no_ignore_case');
    Getopt::Long::Configure('bundling');
    Getopt::Long::Configure('pass_through');
    Getopt::Long::GetOptionsFromArray($commandoptions,
       "w|worker=i"     => \$opt->{'worker'},
       "l|list"         => \$opt->{'mode_list'},
       "version=s"      => \$opt->{'version'},
    ) or do {
        return(Thruk::Utils::CLI::get_submodule_help(__PACKAGE__));
    };

    my $mode;
    if($opt->{'mode_list'}) {
        $mode = 'list';
    } else {
        $mode = shift @{$commandoptions};
    }
    Thruk::Base->config->{'no_external_job_forks'} = 0; # must be enabled, would break job control

    if($mode eq 'setversion') {
        return(_action_setversion($c, $commandoptions));
    }
    elsif($mode eq 'list') {
        return(_action_list($c, $opt, $commandoptions, $config, $global_options));
    }
    elsif($mode eq 'facts' || $mode eq 'runtime') {
        # this function must be run on one cluster node only
        if(my $msg = $c->cluster->run_cluster("once", "cmd: $mode ".join(" ",@{$commandoptions}))) {
            return($msg, 0);
        }
        my $lock_file;
        if($ENV{'THRUK_CRON'}) {
            $lock_file = $c->config->{'tmp_path'}.'/node_control_lock.json';
            my($pid, $ts) = Thruk::Utils::CLI::check_lock($lock_file, "nc_".$mode, undef, 3600);
            return(sprintf("update for %s already running (duration: %s) with pid: %s\n", $mode, Thruk::Utils::Filter::duration(Time::HiRes::time() - $ts, 6), $pid), 0) if $pid;
        }
        my($rc, $msg) = _action_facts($c, $mode, $opt, $commandoptions, $config, $global_options);
        Thruk::Utils::CLI::check_lock_unlock($lock_file, "nc_".$mode) if $lock_file;
        return($rc, $msg);
    }
    elsif($mode eq 'cleanup') {
        return(_action_cleanup($c, $opt, $commandoptions, $config, $global_options));
    }
    elsif($mode eq 'install') {
        return(_action_install($c, $opt, $commandoptions, $config, $global_options));
    }
    elsif($mode eq 'update') {
        return(_action_update($c, $opt, $commandoptions, $config, $global_options));
    }

    $c->stats->profile(end => "_cmd_nc()");
    return(Thruk::Utils::CLI::get_submodule_help(__PACKAGE__));
}

##############################################
sub _action_setversion {
    my($c, $commandoptions) = @_;
    my $version = shift @{$commandoptions};
    if(!$version) {
        return("ERROR - no version specified\n", 1);
    }
    my $omd_available_versions = Thruk::NodeControl::Utils::get_available_omd_versions($c);
    if(@{$omd_available_versions} == 0) {
        return("ERROR - no OMD versions available (yet) - please update facts first.\n", 1);
    }
    my @sel = grep { $_ =~ m/^\Q$version\E/mx } @{$omd_available_versions};
    if(scalar @sel == 0) {
        return("ERROR - no such version available\navailable versions:\n - ".join("\n - ", @{$omd_available_versions})."\n", 1);
    }
    $version = $sel[0];
    Thruk::NodeControl::Utils::save_config($c, {
        'omd_default_version'   => $version,
    });
    return("default version successfully set to: $version\n", 0);
}

##############################################
sub _action_list {
    my($c, $opt, $commandoptions, $config, $global_options) = @_;
    my @data;

    for my $peer (@{Thruk::NodeControl::Utils::get_peers($c)}) {
        my $s = Thruk::NodeControl::Utils::get_server($c, $peer, $config);
        my $v = $s->{'omd_version'};
        $v =~ s/-labs-edition//gmx;
        if(defined $opt->{'version'} && $v ne $opt->{'version'}) { next; }
        my $found = 1;
        if(defined $commandoptions && scalar @{$commandoptions} > 0)  {
            $found = 0;
            for my $pat (@{$commandoptions}) {
                if(lc($pat) eq 'ALL' || $peer->{'name'} =~ m/$pat/mx || $peer->{'key'} =~ m/$pat/mx || $peer->{'section'} =~ m/$pat/mx) {
                    $found = 1;
                    last;
                }
            }
        }
        next unless $found;
        push @data, {
            Section => $s->{'section'} eq 'Default' ? '' : $s->{'section'},
            Name    => $peer->{'name'},
            ID      => $peer->{'key'},
            Host    => $s->{'host_name'},
            Site    => $s->{'omd_site'},
            Version => $v,
            OS      => sprintf("%s %s", $s->{'os_name'}, $s->{'os_version'}),
            Status  => _status($s),
        };
    }
    my $output = Thruk::Utils::text_table(
        keys => ['Name', 'Section', 'ID', 'Host', 'Site', 'Version', 'OS', 'Status'],
        data => \@data,
    );
    return($output, 0);
}

##############################################
sub _action_facts {
    my($c, $mode, $opt, $commandoptions, $config, $global_options) = @_;

    my $t1  = [gettimeofday()];
    my $peers = _get_selected_peers($c, $commandoptions, $config, $global_options);
    _scale_peers($c, $opt->{'worker'}, $peers, sub {
        my($peer_key) = @_;
        my $peer = $c->db->get_peer_by_key($peer_key);
        my $facts;
        _debug("%s start fetching %s data...\n", $peer->{'name'}, $mode);
        eval {
            alarm(300);
            local $SIG{'ALRM'} = sub { confess(sprintf("timeout while updating %s on %s", $mode, $peer->{'name'})); };

            if($mode eq 'facts') {
                $facts = Thruk::NodeControl::Utils::ansible_get_facts($c, $peer, 1);
            }
            if($mode eq 'runtime') {
                $facts = Thruk::NodeControl::Utils::update_runtime_data($c, $peer);
                if(!$facts->{'ansible_facts'}) {
                    $facts = Thruk::NodeControl::Utils::ansible_get_facts($c, $peer, 1);
                }
            }
        };
        my $err = $@;
        alarm(0);
        _warn($err) if($err);

        if(!$facts || $facts->{'last_error'}) {
            $err = sprintf("%s updating %s failed: %s\n", $peer->{'name'}, $mode, ($err||$facts->{'last_error'}//'unknown error'));
            _cronerror(_strip_line($err, 1)); # don't fill the log with errors from cronjobs
        } else {
            _info("%s updated %s successfully: OK\n", $peer->{'name'}, $mode);
        }
    });
    $c->stats->profile(end => "_cmd_nc()");
    _info(sprintf("updating %s data finished in %s\n", $mode, Thruk::Utils::Filter::duration(tv_interval($t1), 6)));
    return("", 0);
}

##############################################
sub _action_install {
    my($c, $opt, $commandoptions, $config, $global_options) = @_;

    my $version = $opt->{'version'} || $config->{'omd_default_version'};
    my $errors = 0;
    my $peers = _get_selected_peers($c, $commandoptions, $config, $global_options);
    for my $peer_key (@{$peers}) {
        my $peer = $c->db->get_peer_by_key($peer_key);
        local $ENV{'THRUK_LOG_PREFIX'} = sprintf("[%s] ", $peer->{'name'});
        _debug("start installing...\n");
        my($job) = Thruk::NodeControl::Utils::omd_install($c, $peer, $version);
        if(!$job) {
            _error("failed to start install");
            $errors++;
            next;
        }
        my $jobdata = Thruk::Utils::External::wait_for_peer_job($c, $peer, $job, 3, 1800);
        if(!$jobdata) {
            _error("failed to install");
            $errors++;
            next;
        }
        if($jobdata->{'rc'} ne '0') {
            _error("failed to install\n");
            _error("%s\n", $jobdata->{'stdout'}) if $jobdata->{'stdout'};
            _error("%s\n", $jobdata->{'stderr'}) if $jobdata->{'stderr'};
            $errors++;
            next;
        }
        _info("%s\n", $jobdata->{'stdout'}) if $jobdata->{'stdout'};
        _info("%s\n", $jobdata->{'stderr'}) if $jobdata->{'stderr'};
        _info("%s install successfully: OK\n", $peer->{'name'});
    }
    $c->stats->profile(end => "_cmd_nc()");
    return("", $errors > 0 ? 1 : 0);
}

##############################################
sub _action_update {
    my($c, $opt, $commandoptions, $config, $global_options) = @_;

    my $version = $opt->{'version'} || $config->{'omd_default_version'};
    my $errors = 0;
    my $peers = _get_selected_peers($c, $commandoptions, $config, $global_options);
    for my $peer_key (@{$peers}) {
        my $peer = $c->db->get_peer_by_key($peer_key);
        local $ENV{'THRUK_LOG_PREFIX'} = sprintf("[%s] ", $peer->{'name'});
        _debug("start update...\n");
        my($job) = Thruk::NodeControl::Utils::omd_update($c, $peer, $version);
        if(!$job) {
            _error("failed to start update");
            $errors++;
            next;
        }
        my $jobdata = Thruk::Utils::External::wait_for_peer_job($c, $peer, $job, 3, 1800);
        if(!$jobdata) {
            _error("failed to update");
            $errors++;
            next;
        }
        if($jobdata->{'rc'} ne '0') {
            _error("failed to update\n");
            _error("%s\n", $jobdata->{'stdout'}) if $jobdata->{'stdout'};
            _error("%s\n", $jobdata->{'stderr'}) if $jobdata->{'stderr'};
            $errors++;
            next;
        }
        _info("%s\n", $jobdata->{'stdout'}) if $jobdata->{'stdout'};
        _info("%s\n", $jobdata->{'stderr'}) if $jobdata->{'stderr'};
        _info("%s update successfully: OK\n", $peer->{'name'});
    }
    $c->stats->profile(end => "_cmd_nc()");
    return("", $errors > 0 ? 1 : 0);
}

##############################################
sub _action_cleanup {
    my($c, $opt, $commandoptions, $config, $global_options) = @_;

    my $errors = 0;
    my $peers = _get_selected_peers($c, $commandoptions, $config, $global_options);
    for my $peer_key (@{$peers}) {
        my $peer = $c->db->get_peer_by_key($peer_key);
        local $ENV{'THRUK_LOG_PREFIX'} = sprintf("[%s] ", $peer->{'name'});
        _debug("start cleaning up...\n");
        my($job) = Thruk::NodeControl::Utils::omd_cleanup($c, $peer);
        if(!$job) {
            _error("failed to start cleanup");
            $errors++;
            next;
        }
        my $jobdata = Thruk::Utils::External::wait_for_peer_job($c, $peer, $job, 3, 1800);
        if(!$jobdata) {
            _error("failed to cleanup");
            $errors++;
            next;
        }
        if($jobdata->{'rc'} ne '0') {
            _error("failed to cleanup\n");
            _error("%s\n", $jobdata->{'stdout'}) if $jobdata->{'stdout'};
            _error("%s\n", $jobdata->{'stderr'}) if $jobdata->{'stderr'};
            $errors++;
            next;
        }
        _info("%s\n", $jobdata->{'stdout'}) if $jobdata->{'stdout'};
        _info("%s\n", $jobdata->{'stderr'}) if $jobdata->{'stderr'};
        _info("%s cleanup successfully: OK\n", $peer->{'name'});
    }
    $c->stats->profile(end => "_cmd_nc()");
    return("", $errors > 0 ? 1 : 0);
}

##############################################
sub _get_selected_peers {
    my($c, $commandoptions, $config, $global_options) = @_;

    # peer list can be extended from addons
    my $peers = Thruk::NodeControl::Utils::get_peers($c);
    my $servers = [];
    for my $peer (@{$peers}) {
        push @{$servers}, Thruk::NodeControl::Utils::get_server($c, $peer, $config);
    }
    Thruk::Action::AddDefaults::set_possible_backends($c, $c->stash->{'disabled_backends'}, $peers);

    $peers = [];
    my $backend = shift @{$commandoptions};
    if($backend && $backend ne 'all') {
        my $peer = $c->db->get_peer_by_key($backend);
        if(!$peer) {
            _fatal("no such peer: ".$backend);
        }
        push @{$peers}, $backend;
    }
    elsif($global_options->{'backends'} && scalar @{$global_options->{'backends'}} > 0) {
        for my $backend (@{$global_options->{'backends'}}) {
            my $peer = $c->db->get_peer_by_key($backend);
            if(!$peer) {
                _fatal("no such peer: ".$backend);
            }
            push @{$peers}, $backend;
        }
    } else {
        for my $peer (@{Thruk::NodeControl::Utils::get_peers($c)}) {
            push @{$peers}, $peer->{'key'};
        }
    }
    return($peers);
}

##############################################
sub _scale_peers {
    my($c, $workernum, $peers, $sub) = @_;
    Thruk::Utils::scale_out(
        scale  => $workernum,
        jobs   => $peers,
        worker => $sub,
        collect => sub {},
    );
    return;
}

##############################################
sub _status {
    my($s) = @_;

    if($s->{'last_error'}) {
        my $err = ([split(/\n/mx, $s->{'last_error'})])->[0];
        return("failed: ".$err);
    }

    my $status = $s->{'omd_status'};

    return "" unless defined $status->{'OVERALL'};
    return "OK" if $status->{'OVERALL'} == 0;

    my @failed;
    for my $key (keys %{$status}) {
        next if $key eq 'OVERALL';
        if($status->{$key} == 1) {
            push @failed, $key;
        }
    }
    return "failed: ".join(', ', @failed);
}

##############################################

=head1 EXAMPLES

Update facts for specific backend.

  %> thruk nc facts backendid

=cut

##############################################

1;
