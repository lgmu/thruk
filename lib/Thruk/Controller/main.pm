package Thruk::Controller::main;

use warnings;
use strict;
use Cpanel::JSON::XS ();

use Thruk::Constants qw/:add_defaults :peer_states/;
use Thruk::Utils ();
use Thruk::Utils::Auth ();
use Thruk::Utils::Cache ();
use Thruk::Utils::Status ();

=head1 NAME

Thruk::Controller::main - Langing Page Controller

=head1 DESCRIPTION

Thruk Controller

=head1 METHODS

=head2 index

=cut

##########################################################

sub index {
    my($c) = @_;

    return unless Thruk::Action::AddDefaults::add_defaults($c, Thruk::Constants::ADD_CACHED_DEFAULTS);

    $c->stash->{'title'}         = 'Thruk';
    $c->stash->{'infoBoxTitle'}  = 'Landing Page';
    $c->stash->{'page'}          = 'main';
    $c->stash->{'template'}      = 'main.tt';
    $c->stash->{has_jquery_ui}   = 1;

    Thruk::Utils::Status::set_default_stash($c);

    my $userdata    = Thruk::Utils::get_user_data($c);
    my $defaultView = {
        'name'   => 'All Hosts',
        'filter' => _get_default_filter($c) // undef, # results in odd number otherwise
        'locked' => 1,
    };

    # strip locked ones from user data, they should have never been saved
    my $views = $userdata->{'main_views'} || [];
    @{$views} = grep { ! $_->{'locked'} } @{$views};

    unshift @{$views}, $defaultView;
    $c->stash->{'mainviews'} = $views;

    if($c->req->parameters->{'v'}) {
        for my $v (@{$views}) {
            if($v->{'name'} eq $c->req->parameters->{'v'}) {
                $c->stash->{'currentview'} = $v;
                last;
            }
        }
    }
    $c->stash->{'currentview'} = $views->[0] unless $c->stash->{'currentview'};

    ############################################################################
    # remove existing view
    if($c->req->parameters->{'remove'}) {
        return unless Thruk::Utils::check_csrf($c);
        if($c->stash->{'currentview'}->{'locked'}) {
            Thruk::Utils::set_message( $c, { style => 'fail_message', msg => 'this view cannot be removed' });
            return $c->redirect_to($c->stash->{'url_prefix'}."cgi-bin/main.cgi?v=".Thruk::Utils::Filter::as_url_arg($c->stash->{'currentview'}->{'name'}));
        }

        my $newviews = [];
        for my $v (@{$views}) {
            if($v->{'name'} ne $c->stash->{'currentview'}->{'name'}) {
                push @{$newviews}, $v;
            }
        }
        $userdata->{'main_views'} = $newviews;
        if(Thruk::Utils::store_user_data($c, $userdata)) {
            Thruk::Utils::set_message( $c, { style => 'success_message', msg => 'view removed successfully' });
        }
        return $c->redirect_to($c->stash->{'url_prefix'}."cgi-bin/main.cgi");
    }

    ############################################################################
    # create new view
    my $f = _get_filter_from_params($c->req->parameters);
    if($c->req->parameters->{'new'}) {
        return unless Thruk::Utils::check_csrf($c);
        push @{$views}, {
            name   => $c->req->parameters->{'name'},
            filter => $f,
            locked => 0,
        };
        $userdata->{'main_views'} = $views;
        if(Thruk::Utils::store_user_data($c, $userdata)) {
            Thruk::Utils::set_message( $c, { style => 'success_message', msg => 'new view created' });
        }
        return $c->redirect_to($c->stash->{'url_prefix'}."cgi-bin/main.cgi?v=".Thruk::Utils::Filter::as_url_arg($c->req->parameters->{'name'}));
    }

    ############################################################################
    # update existing view
    if($c->req->parameters->{'save'}) {
        return unless Thruk::Utils::check_csrf($c);
        if($c->stash->{'currentview'}->{'locked'}) {
            Thruk::Utils::set_message( $c, { style => 'fail_message', msg => 'this view cannot be changed' });
            return $c->redirect_to($c->stash->{'url_prefix'}."cgi-bin/main.cgi?v=".Thruk::Utils::Filter::as_url_arg($c->stash->{'currentview'}->{'name'}));
        }
        $c->stash->{'currentview'}->{'filter'} = $f;
        # only save unlocked views
        @{$views} = grep { ! $_->{'locked'} } @{$views};
        $userdata->{'main_views'} = $views;
        if(Thruk::Utils::store_user_data($c, $userdata)) {
            Thruk::Utils::set_message( $c, { style => 'success_message', msg => 'view saved' });
        }
        return $c->redirect_to($c->stash->{'url_prefix'}."cgi-bin/main.cgi?v=".Thruk::Utils::Filter::as_url_arg($c->req->parameters->{'v'}));
    }

    if($c->req->parameters->{'reorder'}) {
        my $order = $c->req->parameters->{'order[]'};
        my $newviews = [];
        for my $tab (@{$order}) {
            for my $v (@{$views}) {
                if($v->{'name'} eq $tab) {
                    push @{$newviews}, $v;
                    last;
                }
            }
        }
        $userdata->{'main_views'} = $newviews;
        Thruk::Utils::store_user_data($c, $userdata);
        return($c->render(json => {'success' => 1}));
    }

    ############################################################################
    # show save button?
    $c->stash->{'view_save_required'} = 0;
    if(defined $c->stash->{'currentview'}->{'filter'} && !_compare_filter($c->stash->{'currentview'}->{'filter'}, $f)) {
        $c->stash->{'view_save_required'} = 1;
    }

    ############################################################################
    # merge current filter into params unless already set
    if(defined $c->stash->{'currentview'}->{'filter'} && (!defined $f || scalar keys %{$f} == 0)) {
        for my $key (sort keys %{$c->stash->{'currentview'}->{'filter'}}) {
            $c->req->parameters->{$key} = $c->stash->{'currentview'}->{'filter'}->{$key};
        }
        $c->stash->{'view_save_required'} = 0;
    }

    ############################################################################
    my($hostfilter, $servicefilter) = Thruk::Utils::Status::do_filter($c, undef, undef, 1);
    return 1 if $c->stash->{'has_error'};

    ############################################################################
    # contact statistics
    $c->stash->{'contacts'} = _get_contacts($c);

    ############################################################################
    # host statistics
    $c->stash->{'host_stats'} = $c->db->get_host_totals_stats(
            filter     => [ Thruk::Utils::Auth::get_auth_filter($c, 'hosts'), $hostfilter],
            debug_hint => "hosts gauge",
    );

    # service statistics
    $c->stash->{'service_stats'} = $c->db->get_service_totals_stats(
            filter     => [ Thruk::Utils::Auth::get_auth_filter($c, 'services'), $servicefilter],
            debug_hint => "services gauge",
    );

    ############################################################################
    # top 5 hostgroups
    my $hostgroups = _get_top5_hostgroups($c, $hostfilter);
    # exclude some hostgroups
    if($c->config->{'main_exclude_top5_hostgroups'}) {
        my $excludes = Thruk::Base::comma_separated_list($c->config->{'main_exclude_top5_hostgroups'});
        for my $ex (@{$excludes}) {
            if(Thruk::Base::looks_like_regex($ex)) {
                for my $key (sort keys %{$hostgroups}) {
                    ## no critic
                    if($key =~ /$ex/) {
                        delete $hostgroups->{$key};
                    }
                    ## use critic
                }
            } else {
                delete $hostgroups->{$ex};
            }
        }
    }
    my $top5_hg = [];
    my @hashkeys_hg = sort { $hostgroups->{$b} <=> $hostgroups->{$a} || $a cmp $b } keys %{$hostgroups};
    splice(@hashkeys_hg, 5) if scalar(@hashkeys_hg) > 5;
    for my $key (@hashkeys_hg) {
        push(@{$top5_hg}, { 'name' => $key, 'value' => $hostgroups->{$key} } )
    }
    $c->stash->{'hostgroups'} = $top5_hg;

    ############################################################################
    my $host_lookup = {};
    if($hostfilter) {
        my $hosts = $c->db->get_hosts(
            filter     => [ Thruk::Utils::Auth::get_auth_filter($c, 'hosts'), $hostfilter, ],
            columns    => ['name'],
            debug_hint => 'host lookup',
        );
        for my $host ( @{$hosts} ) {
            $host_lookup->{$host->{'name'}} = 1;
        }
    }

    ############################################################################
    # notifications
    $c->stash->{'notifications'} = _get_notifications($c, $hostfilter, $host_lookup);

    $c->stash->{'notification_pattern'} = "";
    if($hostfilter && $c->stash->{'hosts_with_notifications'} && scalar keys %{$c->stash->{'hosts_with_notifications'}} < 30) {
        $c->stash->{'notification_pattern'} = join('|', sort keys %{$c->stash->{'hosts_with_notifications'}});
    }

    ############################################################################
    # host and service problems
    my $problemhosts    = $c->db->get_hosts(
        filter     => [ Thruk::Utils::Auth::get_auth_filter($c, 'hosts'),    $hostfilter,    'last_hard_state_change' => { ">" => 0 }, 'state' => 1, 'has_been_checked' => 1, 'acknowledged' => 0, 'hard_state' => 1, 'scheduled_downtime_depth' => 0 ],
        columns    => ['name','state','plugin_output','last_hard_state_change'],
        sort       => { ASC => 'last_hard_state_change' },
        limit      => 5,
        debug_hint => 'host problems',
     );
    my $problemservices = $c->db->get_services(
        filter     => [ Thruk::Utils::Auth::get_auth_filter($c, 'services'), $servicefilter, 'last_hard_state_change' => { ">" => 0 }, 'state' => { "!=" => 0 }, 'has_been_checked' => 1, 'acknowledged' => 0, 'state_type' => 1, 'scheduled_downtime_depth' => 0 ],
        columns    => ['host_name','description','state','plugin_output','last_hard_state_change'],
        sort       => { ASC => 'last_hard_state_change' },
        limit      => 5,
        debug_hint => 'service problems',
    );
    $c->stash->{'problemhosts'} = $problemhosts;
    $c->stash->{'problemservices'} = $problemservices;

    ############################################################################
    # backend statistics
    my $backend_stats = {
        'available' => 0,
        'enabled'   => 0,
        'running'   => 0,
        'down'      => 0,
    };
    for my $pd (@{$c->stash->{'backends'}}){
        $backend_stats->{'available'}++;
        if($c->stash->{'backend_detail'}->{$pd}->{'running'}) {
            $backend_stats->{'running'}++;
            $backend_stats->{'enabled'}++;
        } elsif($c->stash->{'backend_detail'}->{$pd}->{'disabled'} == HIDDEN_USER) {
            $backend_stats->{'disabled'}++;
        } elsif($c->stash->{'backend_detail'}->{$pd}->{'disabled'} == UNREACHABLE) {
            $backend_stats->{'down'}++;
            $backend_stats->{'enabled'}++;
        } elsif($c->stash->{'backend_detail'}->{$pd}->{'running'} == 0) {
            $backend_stats->{'down'}++;
            $backend_stats->{'enabled'}++;
        }
    }
    my $backend_gauge_data = [];
    push @{$backend_gauge_data}, ["Up",      $backend_stats->{'running'}] if $backend_stats->{'running'};
    push @{$backend_gauge_data}, ["Down",    $backend_stats->{'down'}]    if $backend_stats->{'down'};
    push @{$backend_gauge_data}, ["Enabled", 0]                           if $backend_stats->{'enabled'} == 0;
    $c->stash->{'backend_gauge_data'} = $backend_gauge_data;
    $c->stash->{'backend_stats'}      = $backend_stats;

    ############################################################################
    # host by backend
    if($backend_stats->{'enabled'} - $backend_stats->{'down'} > 1) {
        my $hosts_by_backend = [];
        my $hosts_by_backend_data = $c->db->get_host_stats_by_backend(
            filter     => [ Thruk::Utils::Auth::get_auth_filter($c, 'hosts'), $hostfilter],
            debug_hint => "hosts by backend",
        );
        for my $row (values %{$hosts_by_backend_data}) {
            push @{$hosts_by_backend}, [$row->{'peer_name'}, $row->{'total'} ];
        }
        @{$hosts_by_backend} = sort { $b->[1] <=> $a->[1] } @{$hosts_by_backend};
        $c->stash->{'hosts_by_backend'} = $hosts_by_backend;
    }

    ############################################################################
    my $style = $c->req->parameters->{'style'} || 'main';
    if($style ne 'main' ) {
        return if Thruk::Utils::Status::redirect_view($c, $style);
    }
    $c->stash->{style}      = $style;
    $c->stash->{substyle}   = 'service';
    $c->stash->{page_title} = '';

    Thruk::Utils::ssi_include($c);

    return 1;
}

##########################################################
sub _get_top5_hostgroups {
    my($c, $hostfilter) = @_;

    my $auth_filter = [Thruk::Utils::Auth::get_auth_filter($c, 'hosts')];
    if(!$auth_filter && !$hostfilter) {
        return _get_top5_hostgroups_sums($c);
    }
    my $hosts = $c->db->get_hosts(
        filter => [ $auth_filter, $hostfilter, { groups => { '!=', '' }} ],
        columns => ['name', 'groups'],
        debug_hint => 'top hostgroups',
    );
    my $hostgroups = {};
    for my $host ( @{$hosts} ) {
        for my $group ( @{$host->{'groups'}} ) {
            $hostgroups->{$group}++;
        }
    }
    return $hostgroups;
}

##########################################################
sub _get_top5_hostgroups_sums {
    my($c) = @_;

    my $data = $c->db->get_hostgroups(
        columns => [qw/name num_hosts/],
        debug_hint => 'top hostgroups sums',
    );

    my $hostgroups = {};
    for my $group (@{$data}) {
        $hostgroups->{$group->{'name'}} = $group->{'num_hosts'};
    }

    return $hostgroups;
}

##########################################################
sub _get_notifications {
    my($c, $hostfilter, $host_lookup) = @_;
    $c->stats->profile(begin => "_get_notifications");
    my $start            = time() - 90000; # last 25h
    my $notificationData = _notifications_data($c, $start);
    my $notificationHash = {};
    my $time = $start;
    while ($time <= time()) {
        my $curDate = ($time - ($time % 3600)) * 1000;
        $notificationHash->{$curDate} = 0;
        $time += 3600;
    }

    my $hosts_with_notifications = {};

    my($selected_backends) = $c->db->select_backends('get_logs', []);
    for my $ts ( sort keys %{$notificationData} ) {
        my $date = ($ts - ($ts % 3600))*1000;
        for my $backend (@{$selected_backends}) {
            next unless $notificationData->{$ts}->{$backend};
            for my $n ( @{$notificationData->{$ts}->{$backend}} ) {
                if(!$hostfilter) {
                    $notificationHash->{$date}++;
                    next;
                }
                if($host_lookup->{$n->{'host_name'}}) {
                    $hosts_with_notifications->{$n->{'host_name'}} = 1;
                    $notificationHash->{$date}++;
                }
            }
        }
    }

    $c->stash->{'hosts_with_notifications'} = $hosts_with_notifications;

    my($label, $ts) = ({});
    my $notifications = [["x"], ["Notifications"]];
    my @keys = sort keys %{$notificationHash};
    @keys = splice(@keys, 1);
    for my $key (@keys) {
        push(@{$notifications->[0]}, 0+$key);
        push(@{$notifications->[1]}, $notificationHash->{$key});
        $ts = 0+$key/1000;
        $label->{$ts} = Thruk::Utils::format_date($ts, "%H:%M");
    }
    $label->{$ts+3600} = Thruk::Utils::format_date($ts+3600, "%H:%M");
    $c->stats->profile(end => "_get_notifications");
    return({data => $notifications, label => $label});
}

##########################################################
sub _notifications_data {
    my($c, $start) = @_;
    $c->stats->profile(begin => "_notifications_data read cache");

    my $cache  = Thruk::Utils::Cache->new($c->config->{'var_path'}.'/notifications.cache');
    my $cached = $cache->get("notifications") || {};

    $c->stats->profile(end => "_notifications_data read cache");

    # update cache every 60sec
    my $age = $cache->age();
    $c->stash->{'notifications_age'} = defined $age ? $age : "";
    if(!defined $age || $age > 50) {
        $c->stats->profile(begin => "_notifications_data bg refresh");
        $cache->touch(); # update timestamp to avoid multiple parallel updates
        require Thruk::Utils::External;
        Thruk::Utils::External::perl($c, {
                    expr       => 'Thruk::Controller::main::_notifications_update_cache($c, '.$start.')',
                    background => 1,
                    clean      => 1,
        });
        $c->stats->profile(end => "_notifications_data bg refresh");
    }

    return($cached);
}

##########################################################
sub _notifications_update_cache {
    my($c, $start) = @_;
    my $cache  = Thruk::Utils::Cache->new($c->config->{'var_path'}.'/notifications.cache');
    my $cached = $cache->get("notifications") || {};
    $cache->touch(); # update timestamp to avoid multiple parallel updates

    # always update full hours
    $start = $start - ($start % 3600);

    # clear old entries
    for my $ts (sort keys %{$cached}) {
        if($ts < $start) {
            delete $cached->{$ts};
        }
    }

    # remove last available hour from cache
    my @keys = sort keys %{$cached};
    if(scalar @keys > 0) {
        my $last = pop(@keys);
        delete $cached->{$last};
        $start = $last;
    }

    my $data = $c->db->get_logs(
        filter     => [
                      { time => { '>=' => $start }},
                      class => 3,
                  ],
        columns    => [qw/time host_name/],
        backends   => ['ALL'],
        debug_hint => 'notifications',
    );

    # clean all cache entries which will be updated now
    for my $i (1..30) {
        delete $cached->{$start + ($i * 3600)};
    }

    for my $n ( @{$data} ) {
        my $hour = $n->{'time'} - ($n->{'time'} % 3600);
        push @{$cached->{$hour}->{$n->{'peer_key'}}}, $n;
    }
    $cache->set("notifications", $cached);
    return($cached, 0);
}

##########################################################
sub _get_filter_from_params {
    my($params) = @_;
    my $f = {};
    for my $key (keys %{$params}) {
        if($key =~ m/^dfl_(.*)$/mx) {
            $f->{$key} = $params->{$key};
        }
    }
    delete $f->{'dfl_columns'};
    return($f);
}

##########################################################
sub _compare_filter {
    my($f1, $f2) = @_;
    my $json = Cpanel::JSON::XS->new->utf8;
    $json = $json->canonical; # keys will be randomly ordered otherwise

    my $d1 = $json->encode($f1);
    my $d2 = $json->encode($f2);

    return($d1 eq $d2);
}

##########################################################
sub _get_contacts {
    my($c) = @_;
    $c->stats->profile(begin => "_get_contacts");

    my $auth_backends = $c->db->authoritative_peer_keys();
    my $backends      = Thruk::Action::AddDefaults::has_backends_set($c) ? undef : $c->db->authoritative_peer_keys();
    my $num_backends  = scalar @{$c->db->get_peers()};
    my($selected_backends) = $c->db->select_backends('get_contacts', []);
    if($num_backends > 1 && scalar @{$selected_backends} == $num_backends) {
        $backends = $auth_backends;
    }

    my $data = $c->db->caching_query(
        $c->config->{'var_path'}.'/caching_query.contact_names.cache',
        'get_contacts',
        {
            columns    => [qw/name/],
            debug_hint => 'total contacts',
            backend    => $backends,
        },
        sub { return $_[0]->{'name'}; },
        1,
    );

    # take shortcut if its only one backend
    my $key;
    if($backends && scalar @{$backends} == 1) {
        $key = (keys %{$data})[0];
    }
    elsif(scalar keys %{$data} == 1) {
        $key = (keys %{$data})[0];
    }

    if($key) {
        my $num = scalar @{$data->{$key}};

        $c->stats->profile(end => "_get_contacts");
        return($num);
    }

    my $uniq = {};
    for my $peer_key (sort keys %{$data}) {
        for my $name (@{$data->{$peer_key}}) {
            $uniq->{$name} = 1;
        }
    }

    $c->stats->profile(end => "_get_contacts");
    return(scalar keys %{$uniq});
}

##########################################################
sub _get_default_filter {
    my($c) = @_;
    my $default = $c->config->{'default_main_filter'};
    return unless $default;
    my($key, $op, $val) = $default =~ m/^\s*(\w+)\s+([\S]+)\s+(.*)\s*$/gmx;
    my $remoteuser = $c->stash->{'remote_user'};
    $val =~ s/\$REMOTE_USER\$/$remoteuser/gmx;
    return({
        "dfl_s0_op"      => $op,
        "dfl_s0_type"    => $key,
        "dfl_s0_val_pre" => "",
        "dfl_s0_value"   => $val,
    });
}

##########################################################

1;
