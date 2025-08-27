package Thruk::Controller::status;

use warnings;
use strict;
use Cpanel::JSON::XS qw/decode_json/;

use Thruk::Action::AddDefaults ();
use Thruk::Backend::Manager ();
use Thruk::Backend::Provider::Livestatus ();
use Thruk::Utils::Auth ();
use Thruk::Utils::Log qw/:all/;
use Thruk::Utils::Status ();

=head1 NAME

Thruk::Controller::status - Thruk Controller

=head1 DESCRIPTION

Thruk Controller.

=head1 METHODS

=head2 index

=cut

##########################################################
sub index {
    my($c) = @_;

    return unless Thruk::Action::AddDefaults::add_defaults($c, Thruk::Constants::ADD_CACHED_DEFAULTS);

    # which style to display?
    my $allowed_subpages = {
                            'detail'     => 1, 'hostdetail'   => 1,
                            'grid'       => 1, 'hostgrid'     => 1, 'servicegrid'     => 1,
                            'overview'   => 1, 'hostoverview' => 1, 'serviceoverview' => 1,
                            'summary'    => 1, 'hostsummary'  => 1, 'servicesummary'  => 1,
                            'combined'   => 1, 'perfmap'      => 1,
                        };
    my $style = $c->req->parameters->{'style'} || '';

    if($style ne '' && !defined $allowed_subpages->{$style}) {
        return if Thruk::Utils::Status::redirect_view($c, $style);
    }

    if( $style eq '' ) {
        if( defined $c->req->parameters->{'hostgroup'} and $c->req->parameters->{'hostgroup'} ne '' ) {
            $style = 'overview';
        }
        if( defined $c->req->parameters->{'servicegroup'} and $c->req->parameters->{'servicegroup'} ne '' ) {
            $style = 'overview';
        }
    }

    if(defined $c->req->parameters->{'addb'} or defined $c->req->parameters->{'saveb'}) {
        return _process_bookmarks($c);
    }

    if(defined $c->req->parameters->{'verify'} and $c->req->parameters->{'verify'} eq 'time') {
        return _process_verify_time($c);
    }

    if($c->req->parameters->{'serveraction'}) {
        return if Thruk::Utils::External::render_page_in_background($c);

        my($rc, $msg) = Thruk::Utils::Status::serveraction($c);
        my $json = { 'rc' => $rc, 'msg' => $msg };
        return $c->render(json => $json);
    }

    if(defined $c->req->parameters->{'action'}) {
        if($c->req->parameters->{'action'} eq "set_default_columns") {
            my($rc, $data) = _process_set_default_columns($c);
            my $json = { 'rc' => $rc, 'msg' => $data };
            return $c->render(json => $json);
        }
    }

    if($c->req->parameters->{'replacemacros'}) {
        my($rc, $data) = _replacemacros($c);
        if($c->req->parameters->{'forward'}) {
            if(!$rc) {
                return $c->redirect_to($data);
            }
            die("replacing macros failed");
        }

        if(!Thruk::Utils::check_csrf($c)) {
            ($rc, $data) = (1, 'invalid request');
        }
        my $json = { 'rc' => $rc, 'data' => $data };
        return $c->render(json => $json);
    }

    if($c->req->parameters->{'long_plugin_output'}) {
        return _long_plugin_output($c);
    }

    # set some defaults
    Thruk::Utils::Status::set_default_stash($c);

    $style = 'detail' unless defined $allowed_subpages->{$style};

    # did we get a search request?
    if( defined $c->req->parameters->{'navbarsearch'} and $c->req->parameters->{'navbarsearch'} eq '1' ) {
        $style = _process_search_request($c);
    }

    $c->stash->{title}         = 'Current Network Status';
    $c->stash->{infoBoxTitle}  = 'Current Network Status';
    $c->stash->{page}          = 'status';
    $c->stash->{show_top_pane} = 1;
    $c->stash->{style}         = $style;
    $c->stash->{'num_hosts'}   = 0;
    $c->stash->{'custom_vars'} = [];

    $c->stash->{substyle}     = undef;
    if($c->stash->{'hostgroup'}) {
        $c->stash->{substyle} = 'host';
    }
    elsif($c->stash->{'servicegroup'}) {
        $c->stash->{substyle} = 'service';
    }
    elsif( $style =~ m/^host/mx ) {
        $c->stash->{substyle} = 'host';
    }
    elsif( $style =~ m/^service/mx ) {
        $c->stash->{substyle} = 'service';
    }

    # raw data request?
    $c->stash->{'output_format'} = $c->req->parameters->{'format'} || 'html';
    if($c->stash->{'output_format'} ne 'html') {
        return unless _process_raw_request($c);
        return 1;
    }

    # normal pages
    elsif ( $style eq 'detail' ) {
        $c->stash->{substyle} = 'service';
        return unless _process_details_page($c);
    }
    elsif ( $style eq 'hostdetail' ) {
        return unless _process_hostdetails_page($c);
    }
    elsif ( $style =~ /overview$/gmx ) {
        $style = 'overview';
        _process_overview_page($c);
    }
    elsif ( $style =~ m/grid$/mx ) {
        $style = 'grid';
        _process_grid_page($c);
    }
    elsif ( $style =~ m/summary$/mx ) {
        $style = 'summary';
        _process_summary_page($c);
    }
    elsif ( $style eq 'combined' ) {
        _process_combined_page($c);
    }
    elsif ( $style eq 'perfmap' ) {
        $c->stash->{substyle} = 'service';
        _process_perfmap_page($c);
    }

    $c->stash->{template} = 'status_' . $style . '.tt';

    Thruk::Utils::ssi_include($c);

    return 1;
}

##########################################################
# check for search results
sub _process_raw_request {
    my($c) = @_;

    my $limit = $c->req->parameters->{'limit'};
    my $type  = $c->req->parameters->{'type'}  || 'all';
    if($c->req->parameters->{'page'}) {
        $limit = $c->req->parameters->{'page'} * $limit;
    }

    my $filter;
    if($c->req->parameters->{'query'}) {
        $filter = $c->req->parameters->{'query'};
        $filter =~ s/\s+/\.\*/gmx;
        if($filter =~ s/^(\w{2}:)//mx) {
            my $prefix = $1;
            if($prefix eq 'ho:') { $type = "host"; }
            if($prefix eq 'se:') { $type = "service"; }
            if($prefix eq 'hg:') { $type = "hostgroup"; }
            if($prefix eq 'sg:') { $type = "servicegroup"; }
        }
        if($filter eq '*') { $filter = ""; }
    }

    my $json;
    if($type eq 'contact' || $type eq 'contacts') {
        my $data = [];
        my $size = 0;
        if(!$c->check_user_roles("authorized_for_configuration_information")) {
            $data = ["you are not authorized for configuration information"];
        } else {
            ($data, $size) = $c->db->get_contacts( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'contact' ), name => { '~~' => $filter } ], columns => [qw/name alias/], limit => $limit );
        }
        if($c->req->parameters->{'wildcards'}) {
            unshift @{$data}, { name => '*', alias => '*' };
            $size++;
        }
        push @{$json}, { 'name' => "contacts", 'data' => $data, 'total' => $size };
    }

    if($type eq 'host' || $type eq 'hosts' || $type eq 'all') {
        my($data, $size) = $c->db->get_hosts( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'hosts' ), name => { '~~' => $filter } ], columns => [qw/name alias/], limit => $limit );
        for my $row (@{$data}) {
            delete $row->{'peer_key'};
            delete $row->{'peer_name'};
        }
        push @{$json}, { 'name' => "hosts", 'data' => $data, 'total' => $size };
    }

    if($type eq 'hostgroup' || $type eq 'hostgroups' || $type eq 'all') {
        my $data = [];
        my $hostgroups = $c->db->get_hostgroup_names_from_hosts(filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'hosts' )]);
        my $alias      = $c->db->get_hostgroups( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'hostgroups' )], columns => [qw/name alias/]);
        $alias = Thruk::Base::array2hash($alias, "name");
        for my $group (@{$hostgroups}) {
            my $row = $alias->{$group};
            next unless(!$filter || ($row->{'name'}.' - '.$row->{'alias'}) =~ m/$filter/mxi);
            delete $row->{'peer_key'};
            delete $row->{'peer_name'};
            push @{$data}, $row;
        }
        push @{$json}, { 'name' => "hostgroups", 'data' => $data };
    }

    if($type eq 'servicegroup' || $type eq 'servicegroups' || $type eq 'all') {
        my $data = [];
        my $servicegroups = $c->db->get_servicegroup_names_from_services(filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'services' )]);
        my $alias         = $c->db->get_servicegroups( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'servicegroups' ) ], columns => [qw/name alias/] );
        $alias = Thruk::Base::array2hash($alias, "name");
        for my $group (@{$servicegroups}) {
            my $row = $alias->{$group};
            next unless(!$filter || ($row->{'name'}.' - '.$row->{'alias'}) =~ m/$filter/mxi);
            delete $row->{'peer_key'};
            delete $row->{'peer_name'};
            push @{$data}, $row;
        }
        push @{$json}, { 'name' => "servicegroups", 'data' => $data };
    }

    if($type eq 'service' || $type eq 'services' || $type eq 'all') {
        my $host = $c->req->parameters->{'host'};
        my $additional_filter;
        my @hostfilter;
        if(defined $host and $host ne '') {
            for my $h (split(/\s*,\s*/mx, $host)) {
                next if $h eq '*';
                my $op = "=";
                if(Thruk::Base::looks_like_regex($h)) {
                    $op = "~";
                }
                push @hostfilter, { 'host_name' => { $op => $h }};
            }
            $additional_filter = Thruk::Utils::combine_filter('-or', \@hostfilter);
        }
        my($data) = $c->db->get_service_names( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'services' ), $additional_filter, description => { '~~' => $filter } ], limit => $limit );
        push @{$json}, { 'name' => "services", 'data' => $data };
    }

    if($type eq 'timeperiod' or $type eq 'timeperiods') {
        my($data, $size) = $c->db->get_timeperiod_names( filter => [ name => { '~~' => $filter } ], limit => $limit );
        push @{$json}, { 'name' => "timeperiods", 'data' => $data, 'total' => $size };
    }

    if($type eq 'command' or $type eq 'commands') {
        my $data = [];
        if(!$c->check_user_roles("authorized_for_configuration_information")) {
            $data = ["you are not authorized for configuration information"];
        } else {
            my $commands = $c->db->get_commands( filter => [ name => { '~~' => $filter } ], columns => ['name'] );
            $data = [];
            for my $d (@{$commands}) {
                push @{$data}, $d->{'name'};
            }
        }
        push @{$json}, { 'name' => "commands", 'data' => $data };
    }

    if($type eq 'custom variable' || $type eq 'custom value') {
        # get available custom variables
        my $data = [];
        my $exposed_only = $c->req->parameters->{'exposed_only'} || 0;
        if($type eq 'custom variable' || !$c->check_user_roles("authorized_for_configuration_information")) {
            $data = Thruk::Utils::Status::get_custom_variable_names($c, 'all', $exposed_only, $filter, $c->req->parameters->{'prefix'});
        }
        if($type eq 'custom value') {
            my $allowed = $data;
            my $varname = $c->req->parameters->{'var'} || '';
            if(!$c->check_user_roles("authorized_for_configuration_information") && !grep/^\Q$varname\E$/mx, @{$allowed}) {
                $data = ["you are not authorized for this custom variable"];
            } else {
                my $uniq = {};
                my $hosts    = $c->db->get_hosts(    filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'hosts' ),    { 'custom_variable_names' => { '>=' => $varname } }], columns => ['custom_variable_names', 'custom_variable_values'] );
                my $services = $c->db->get_services( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'services' ), { 'custom_variable_names' => { '>=' => $varname } }], columns => ['custom_variable_names', 'custom_variable_values'] );
                for my $obj (@{$hosts}, @{$services}) {
                    my %vars;
                    @vars{@{$obj->{custom_variable_names}}} = @{$obj->{custom_variable_values}};
                    $uniq->{$vars{$varname}} = 1;
                }
                if($varname eq 'THRUK_ACTION_MENU' && $c->config->{'action_menu_items'}) {
                    # add available action menus
                    for my $key (keys %{$c->config->{'action_menu_items'}}) {
                        $uniq->{$key} = 1;
                    }
                }
                @{$data} = sort keys %{$uniq};
                @{$data} = grep(/$filter/mxi, @{$data}) if $filter;
            }
        }
        push @{$json}, { 'name' => $type."s", 'data' => $data };
    }

    if($type eq 'contactgroup' || $type eq 'contactgroups') {
        my $data = [];
        if($c->req->parameters->{'wildcards'}) {
            push @{$data}, '*';
        }
        my($groups, $size) = $c->db->get_contactgroups(filter => [ Thruk::Utils::Auth::get_auth_filter($c, 'contactgroups'), name => { '~~' => $filter } ], columns => [qw/name/], sort => {ASC=> 'name'}, limit => $limit);
        for my $g (@{$groups}) {
            push @{$data}, $g->{'name'};
        }
        push @{$json}, { 'name' => "contactgroups", 'data' => $data, 'total' => $size };
    }

    if($type eq 'event handler') {
        my $data = [];
        if(!$c->check_user_roles("authorized_for_configuration_information")) {
            $data = ["you are not authorized for configuration information"];
        } else {
            $data = $c->db->get_services( filter => [ -or => [ { host_event_handler => { '~~' => $filter }},
                                                                    {      event_handler => { '~~' => $filter }},
                                                                    ]],
                                                columns => [qw/host_event_handler event_handler/],
                                            );
            my $eventhandler = {};
            for my $d (@{$data}) {
                $eventhandler->{$d->{host_event_handler}} = 1 if $d->{host_event_handler};
                $eventhandler->{$d->{event_handler}}      = 1 if $d->{event_handler};
            }
            $data = [sort keys %{$eventhandler}];
        }
        push @{$json}, { 'name' => "event handlers", 'data' => $data };
    }

    if($type eq 'site') {
        my $data = [];
        for my $key (@{$c->stash->{'backends'}}) {
            my $b = $c->stash->{'backend_detail'}->{$key};
            push @{$data}, $b->{'name'};
        }
        @{$data} = sort @{$data};
        @{$data} = grep(/$filter/mxi, @{$data}) if $filter;
        push @{$json}, { 'name' => "sites", 'data' => $data };
    }

    if($type eq 'navsection') {
        Thruk::Utils::Menu::read_navigation($c);
        my $data = [];
        for my $section (@{$c->stash->{'navigation'}}) {
            push @{$data}, $section->{'name'};
        }
        @{$data} = sort @{$data};
        @{$data} = grep(/$filter/mxi, @{$data}) if $filter;
        push @{$json}, { 'name' => "navsections", 'data' => $data };
    }

    # make lists uniq
    for my $res (@{$json}) {
        $res->{'total_none_uniq'} = scalar @{$res->{'data'}};
        $res->{'data'} = Thruk::Backend::Manager::remove_duplicates($res->{'data'});
    }

    if($c->req->parameters->{'hash'}) {
        my $data  = $json->[0]->{'data'};
        my $total = $json->[0]->{'total'} || scalar @{$data};
        Thruk::Utils::page_data($c, $data, $c->req->parameters->{'limit'}, $total);
        my $list = [];
        if(scalar @{$c->stash->{'data'}} > 0 && ref $c->stash->{'data'}->[0] eq 'HASH') {
            for my $d (@{$c->stash->{'data'}}) {
                if($d->{'name'} ne $d->{'alias'}) {
                    push @{$list}, { 'text' => $d->{'name'}.' - '.$d->{'alias'}, value => $d->{'name'} };
                } else {
                    push @{$list}, { 'text' => $d->{'name'}, value => $d->{'name'} };
                }
            }
        } else {
            for my $d (@{$c->stash->{'data'}}) { push @{$list}, { 'text' => $d, 'value' => $d } }
        }
        $json = { 'data' => $list, 'total' => $total };
    }

    return $c->render(json => $json);
}

##########################################################
# check for search results
sub _process_search_request {
    my( $c ) = @_;

    # search pattern is in host param
    my $host = $c->req->parameters->{'host'};

    return ('detail') unless defined $host;

    # is there a servicegroup with this name?
    my $servicegroups = $c->db->get_servicegroups( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'servicegroups' ), 'name' => $host ] );
    if( scalar @{$servicegroups} > 0 ) {
        delete $c->req->parameters->{'host'};
        $c->req->parameters->{'servicegroup'} = $host;
        $c->stash->{'servicegroup'} = $host;
        return ('overview');
    }

    # is there a hostgroup with this name?
    my $hostgroups = $c->db->get_hostgroups( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'hostgroups' ), 'name' => $host ] );
    if( scalar @{$hostgroups} > 0 ) {
        delete $c->req->parameters->{'host'};
        $c->req->parameters->{'hostgroup'} = $host;
        $c->stash->{'hostgroup'} = $host;
        return ('overview');
    }

    return ('detail');
}

##########################################################
# create the status details page
sub _process_details_page {
    my( $c ) = @_;

    my $view_mode = $c->req->parameters->{'view_mode'} || 'html';
    $c->stash->{'minimal'} = 1 if $view_mode ne 'html';
    $c->stash->{'explore'} = 1 if $c->req->parameters->{'explore'};
    $c->stash->{'show_column_select'} = 1;
    $c->stash->{'auto_reload_fn'} = "explorerUpdateStatusTable" if $c->stash->{'explore'};
    $c->stash->{'status_search_add_default_filter'} = "host";

    my $user_data = Thruk::Utils::get_user_data($c);
    $c->stash->{'default_columns'}->{'dfl_'} = Thruk::Utils::Status::get_service_columns($c);
    my $selected_columns = $c->req->parameters->{'dfl_columns'} || $user_data->{'columns'}->{'svc'} || $c->config->{'default_service_columns'};
    $c->stash->{'table_columns'}->{'dfl_'}   = Thruk::Utils::Status::sort_table_columns($c->stash->{'default_columns'}->{'dfl_'}, $selected_columns);
    $c->stash->{'comments_by_host'}          = {};
    $c->stash->{'comments_by_host_service'}  = {};
    Thruk::Utils::Status::set_comments_and_downtimes($c) if($selected_columns && $selected_columns =~ m/comments/imx);
    $c->stash->{'has_user_columns'}->{'dfl_'} = ($user_data->{'columns'}->{'svc'} || $c->req->parameters->{'dfl_columns'}) ? 1 : 0;

    # which host to display?
    my($hostfilter, $servicefilter) = Thruk::Utils::Status::do_filter($c);

    # do the sort
    my $sorttype   = $c->req->parameters->{'sorttype'}   || 1;
    my $sortoption = $c->req->parameters->{'sortoption'} || 1;
    my $order      = "ASC";
    $order = "DESC" if $sorttype eq "2";
    my $sortoptions = {
        '1' => [ [ 'host_name',   'description' ], 'host name' ],
        '2' => [ [ 'description', 'host_name' ],   'service name' ],
        '3' => [ [ 'has_been_checked', 'state_order', 'host_name', 'description' ], 'service status' ],
        '4' => [ [ 'last_check',              'host_name', 'description' ], 'last check time' ],
        '5' => [ [ 'current_attempt',         'host_name', 'description' ], 'attempt number' ],
        '6' => [ [ 'last_state_change_order', 'host_name', 'description' ], 'state duration' ],
        '7' => [ [ 'peer_name', 'host_name', 'description' ], 'site' ],
        '9' => [ [ 'plugin_output', 'host_name', 'description' ], 'status information' ],
    };
    my $sortnum = 10;
    for my $col (@{$c->stash->{'default_columns'}->{'dfl_'}}) {
        next if defined $col->{'sortby'};

        my $field = $col->{'field'};
        if($field =~ m/^cust_(.*)$/mx) {
            $field = uc($1);
            $sortoptions->{$sortnum} = [["custom_variables ".$field, "host_custom_variables ".$field], lc($col->{"title"}) ];
        } else {
            $sortoptions->{$sortnum} = [[$field], lc($col->{"title"}) ];
        }
        $col->{'sortby'} = $sortnum;
        $sortnum++;
    }
    $sortoption = 1 if !defined $sortoptions->{$sortoption};
    return 1 if $c->stash->{'has_error'};

    # reverse order for duration
    my $backend_order = $order;
    if($sortoption eq "6") { $backend_order = $order eq 'ASC' ? 'DESC' : 'ASC'; }

    my($columns, $keep_peer_addr, $keep_peer_name, $keep_peer_key, $keep_last_state, $keep_state_order);
    if($view_mode eq 'json' and $c->req->parameters->{'columns'}) {
        @{$columns} = split(/\s*,\s*/mx, $c->req->parameters->{'columns'});
        my $col_hash = Thruk::Base::array2hash($columns);
        $keep_peer_addr   = delete $col_hash->{'peer_addr'};
        $keep_peer_name   = delete $col_hash->{'peer_name'};
        $keep_peer_key    = delete $col_hash->{'peer_key'};
        $keep_last_state  = delete $col_hash->{'last_state_change_order'};
        $keep_state_order = delete $col_hash->{'state_order'};
        @{$columns} = keys %{$col_hash};
    }

    my $extra_columns = [];
    if($c->config->{'use_lmd_core'} && $c->stash->{'show_long_plugin_output'} ne 'inline' && $view_mode eq 'html') {
        push @{$extra_columns}, 'has_long_plugin_output';
    } else {
        push @{$extra_columns}, 'long_plugin_output';
    }
    push @{$extra_columns}, 'contacts' if ($selected_columns && $selected_columns =~ m/contacts/imx);

    # get all services
    my $services = $c->db->get_services(
                                filter  => [ Thruk::Utils::Auth::get_auth_filter( $c, 'services' ), $servicefilter ],
                                sort    => { $backend_order => $sortoptions->{$sortoption}->[0] },
                                pager   => 1,
                                columns => $columns,
                                extra_columns => $extra_columns,
                    );

    if(scalar @{$services} == 0 && !$c->stash->{'has_service_filter'}) {
        # try to find matching hosts, maybe we got some hosts without service
        my $host_stats = $c->db->get_host_stats( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'hosts' ), $hostfilter ] );
        $c->stash->{'num_hosts'} = $host_stats->{'total'};

        # redirect to host details page if there are hosts but no service filter
        if($c->stash->{'num_hosts'} > 0) {
            # remove columns, they are different for hosts
            my $url = $c->stash->{'url_prefix'}.'cgi-bin/'.Thruk::Utils::Filter::uri_with($c, {'style' => 'hostdetail', 'dfl_columns' => undef });
            $url =~ s/&amp;/&/gmx;
            Thruk::Utils::set_message( $c, 'info_message', 'No services found for this filter, redirecting to host view.' );
            return $c->redirect_to($url);
        }
    }

    if( $view_mode eq 'xls' ) {
        Thruk::Utils::Status::set_selected_columns($c, [''], 'service');
        Thruk::Utils::Status::set_comments_and_downtimes($c);
        $c->res->headers->header( 'Content-Disposition', 'attachment; filename="status.xls"' );
        $c->stash->{'data'}     = $services;
        $c->stash->{'template'} = 'excel/status_detail.tt';
        return $c->render_excel();
    }
    elsif ( $view_mode eq 'json' ) {
        # remove unwanted colums
        if($columns) {
            for my $s (@{$services}) {
                delete $s->{'peer_addr'}               unless $keep_peer_addr;
                delete $s->{'peer_name'}               unless $keep_peer_name;
                delete $s->{'peer_key'}                unless $keep_peer_key;
                delete $s->{'last_state_change_order'} unless $keep_last_state;
                delete $s->{'state_order'}             unless $keep_state_order;
            }
        }

        my $allowed      = $c->check_user_roles("authorized_for_configuration_information");
        my $allowed_list = Thruk::Utils::get_exposed_custom_vars($c->config);
        my $show_full_commandline = $c->config->{'show_full_commandline'};
        Thruk::Utils::fill_commands_cache($c);
        for my $s (@{$services}) {
            # remove custom macro colums which could contain confidential informations
            Thruk::Utils::set_allowed_rows_data($s, $allowed, $allowed_list, $show_full_commandline);
        }
        return $c->render(json => $services);
    }

    $c->stash->{'data_sorted'} = { type => $sorttype, option => $sortoption };

    if($c->config->{'show_custom_vars'}
       and $c->stash->{'data'}
       and defined $c->stash->{'host_stats'}
       and ref($c->stash->{'host_stats'}) eq 'HASH'
       and defined $c->stash->{'host_stats'}->{'up'}
       and $c->stash->{'host_stats'}->{'up'} + $c->stash->{'host_stats'}->{'down'} + $c->stash->{'host_stats'}->{'unreachable'} + $c->stash->{'host_stats'}->{'pending'} == 1) {
        # set allowed custom vars into stash if there is only one host visible
        Thruk::Utils::set_custom_vars($c, {'prefix' => 'host_', 'host' => $c->stash->{'data'}->[0], 'add_host' => 1 });
    }

    return 1;
}

##########################################################
# create the hostdetails page
sub _process_hostdetails_page {
    my( $c ) = @_;

    my $view_mode = $c->req->parameters->{'view_mode'} || 'html';
    $c->stash->{'minimal'} = 1 if $view_mode ne 'html';
    $c->stash->{'explore'} = 1 if $c->req->parameters->{'explore'};
    $c->stash->{'show_column_select'} = 1;
    $c->stash->{'auto_reload_fn'} = "explorerUpdateStatusTable" if $c->stash->{'explore'};
    $c->stash->{'status_search_add_default_filter'} = "host";

    my $user_data = Thruk::Utils::get_user_data($c);
    my $selected_columns = $c->req->parameters->{'dfl_columns'} || $user_data->{'columns'}->{'hst'} || $c->config->{'default_host_columns'};
    $c->stash->{'show_host_attempts'} = defined $c->config->{'show_host_attempts'} ? $c->config->{'show_host_attempts'} : 0;
    $c->stash->{'default_columns'}->{'dfl_'} = Thruk::Utils::Status::get_host_columns($c);
    $c->stash->{'table_columns'}->{'dfl_'}   = Thruk::Utils::Status::sort_table_columns($c->stash->{'default_columns'}->{'dfl_'}, $selected_columns);
    $c->stash->{'comments_by_host'}          = {};
    $c->stash->{'comments_by_host_service'}  = {};
    Thruk::Utils::Status::set_comments_and_downtimes($c) if($selected_columns && $selected_columns =~ m/comments/imx);
    $c->stash->{'has_user_columns'}->{'dfl_'} = ($user_data->{'columns'}->{'hst'} || $c->req->parameters->{'dfl_columns'}) ? 1 : 0;

    # which host to display?
    my($hostfilter) = Thruk::Utils::Status::do_filter($c);

    # do the sort
    my $sorttype   = $c->req->parameters->{'sorttype'}   || 1;
    my $sortoption = $c->req->parameters->{'sortoption'} || 1;
    my $order      = "ASC";
    $order = "DESC" if $sorttype eq "2";
    my $sortoptions = {
        '1' => [ 'name', 'host name' ],
        '4' => [ [ 'last_check',              'name' ], 'last check time' ],
        '6' => [ [ 'last_state_change_order', 'name' ], 'state duration' ],
        '7' => [ [ 'peer_name', 'name' ], 'site' ],
        '8' => [ [ 'has_been_checked', 'state', 'name' ], 'host status' ],
        '9' => [ [ 'plugin_output', 'name' ], 'status information' ],
    };
    my $sortnum = 10;
    for my $col (@{$c->stash->{'default_columns'}->{'dfl_'}}) {
        next if defined $col->{'sortby'};

        my $field = $col->{'field'};
        if($field =~ m/^cust_(.*)$/mx) {
            $field = uc($1);
            $sortoptions->{$sortnum} = [["custom_variables ".$field], lc($col->{"title"}) ];
        } else {
            $sortoptions->{$sortnum} = [[$field], lc($col->{"title"}) ];
        }
        $col->{'sortby'} = $sortnum;
        $sortnum++;
    }
    $sortoption = 1 if !defined $sortoptions->{$sortoption};
    return 1 if $c->stash->{'has_error'};

    # reverse order for duration
    my $backend_order = $order;
    if($sortoption eq "6") { $backend_order = $order eq 'ASC' ? 'DESC' : 'ASC'; }

    my($columns, $keep_peer_addr, $keep_peer_name, $keep_peer_key, $keep_last_state);
    if($view_mode eq 'json' and $c->req->parameters->{'columns'}) {
        @{$columns} = split(/\s*,\s*/mx, $c->req->parameters->{'columns'});
        my $col_hash = Thruk::Base::array2hash($columns);
        $keep_peer_addr  = delete $col_hash->{'peer_addr'};
        $keep_peer_name  = delete $col_hash->{'peer_name'};
        $keep_peer_key   = delete $col_hash->{'peer_key'};
        $keep_last_state = delete $col_hash->{'last_state_change_order'};
        @{$columns} = keys %{$col_hash};
    }

    my $extra_columns = [];
    if($c->config->{'use_lmd_core'} && $c->stash->{'show_long_plugin_output'} ne 'inline' && $view_mode eq 'html') {
        push @{$extra_columns}, 'has_long_plugin_output';
    } else {
        push @{$extra_columns}, 'long_plugin_output';
    }
    push @{$extra_columns}, 'contacts' if ($selected_columns && $selected_columns =~ m/contacts/imx);

    # get hosts
    my $hosts = $c->db->get_hosts( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'hosts' ), $hostfilter ], sort => { $backend_order => $sortoptions->{$sortoption}->[0] }, pager => 1, columns => $columns, extra_columns => $extra_columns );

    if( $view_mode eq 'xls' ) {
        Thruk::Utils::Status::set_selected_columns($c, [''], 'host');
        Thruk::Utils::Status::set_comments_and_downtimes($c);
        my $filename = 'status.xls';
        $c->res->headers->header( 'Content-Disposition', qq[attachment; filename="] . $filename . q["]);
        $c->stash->{'data'}     = $hosts;
        $c->stash->{'template'} = 'excel/status_hostdetail.tt';
        return $c->render_excel();
    }
    if ( $view_mode eq 'json' ) {
        # remove unwanted colums
        if($columns) {
            for my $h (@{$hosts}) {
                delete $h->{'peer_addr'}               unless $keep_peer_addr;
                delete $h->{'peer_name'}               unless $keep_peer_name;
                delete $h->{'peer_key'}                unless $keep_peer_key;
                delete $h->{'last_state_change_order'} unless $keep_last_state;
            }
        }
        my $allowed      = $c->check_user_roles("authorized_for_configuration_information");
        my $allowed_list = Thruk::Utils::get_exposed_custom_vars($c->config);
        my $show_full_commandline = $c->config->{'show_full_commandline'};
        Thruk::Utils::fill_commands_cache($c);
        for my $h (@{$hosts}) {
            # remove custom macro colums which could contain confidential informations
            Thruk::Utils::set_allowed_rows_data($h, $allowed, $allowed_list, $show_full_commandline);
        }
        return $c->render(json => $hosts);
    }

    $c->stash->{'data_sorted'} = { type => $sorttype, option => $sortoption };

    return 1;
}

##########################################################
# create the host/status groups overview page
sub _process_overview_page {
    my( $c ) = @_;

    Thruk::Utils::set_paging_steps($c, Thruk::Base->config->{'group_paging_overview'});
    $c->stash->{'paneprefix'}                       = 'ovr_';
    $c->stash->{'columns'}                          = $c->req->parameters->{'columns'} || 3;

    if($c->req->parameters->{'servicegroup'} || ($c->req->parameters->{'style'} && $c->req->parameters->{'style'} eq 'serviceoverview')) {
        _process_overview_page_by_servicegroup($c);
    } else {
        $c->stash->{substyle} = 'host';
        _process_overview_page_by_hostgroup($c);
    }

    $c->stash->{'show_column_select'} = 1;
    my $user_data = Thruk::Utils::get_user_data($c);
    $c->stash->{'default_columns'}->{'ovr_'} = Thruk::Utils::Status::get_overview_columns($c);
    my $selected_columns = $c->req->parameters->{'ovr_columns'} || $user_data->{'columns'}->{'ovr'} || $c->config->{'default_overview_columns'};
    $c->stash->{'table_columns'}->{'ovr_'}   = Thruk::Utils::Status::sort_table_columns($c->stash->{'default_columns'}->{'ovr_'}, $selected_columns);
    $c->stash->{'has_user_columns'}->{'ovr_'} = ($user_data->{'columns'}->{'ovr'} || $c->req->parameters->{'ovr_columns'}) ? 1 : 0;

    return 1;
}

##########################################################
# create the services overview by hostgroup page
sub _process_overview_page_by_hostgroup {
    my($c) = @_;

    $c->stash->{'status_search_add_default_filter'} = "hostgroup";

    # which host to display?
    my($hostfilter, $servicefilter, $hostgroupfilter, undef) = Thruk::Utils::Status::do_filter($c, 'ovr_');
    return 1 if $c->stash->{'has_error'};
    $c->stash->{'hostgroup'} = 'all' unless $c->stash->{'has_service_filter'};
    $c->stash->{'hostgroup'} = $c->req->parameters->{'hostgroup'} if $c->req->parameters->{'hostgroup'};

    my $groups;
    if($c->stash->{'hostgroup'} ne 'all') {
        $groups = [$c->stash->{'hostgroup'}];
    } else {
        $groups = $c->db->get_hostgroup_names_from_hosts( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'hosts' ), $hostfilter ] );
    }
    my $paged  = Thruk::Utils::page_data($c, $groups);
    my(@hostfilter, @servicefilter , @hostgroupfilter);
    for my $group (@{$paged}) {
        push @hostfilter,      { groups      => { '>=' => $group } };
        push @servicefilter,   { host_groups => { '>=' => $group } };
        push @hostgroupfilter, { name => $group };
    }
    if(scalar @{$paged} > 0 && scalar @{$paged} <= 100) {
        $hostfilter      = Thruk::Utils::combine_filter('-and', [$hostfilter,      Thruk::Utils::combine_filter('-or', \@hostfilter)]);
        $servicefilter   = Thruk::Utils::combine_filter('-and', [$servicefilter,   Thruk::Utils::combine_filter('-or', \@servicefilter)]);
        $hostgroupfilter = Thruk::Utils::combine_filter('-and', [$hostgroupfilter, Thruk::Utils::combine_filter('-or', \@hostgroupfilter)]);
    }

    # we need the hostname, address etc...
    my $hosts = $c->db->get_hosts( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'hosts' ), $hostfilter ],
                                  columns => [ @{$Thruk::Backend::Provider::Livestatus::minimal_host_columns}  ]);
    my $hosts_data = Thruk::Base::array2hash($hosts, "name");
    $c->stash->{'hosts_data'} = $hosts_data;

    # sort in all services and states
    my $services = $c->db->get_services( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'services' ), $servicefilter ],
                                        columns => [qw/host_name description state has_been_checked/]);
    my $services_data = Thruk::Base::array2hash($services, "host_name", "description");

    $groups = $c->db->get_hostgroups( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'hostgroups' ), $hostgroupfilter ] );

    # join our groups together
    my $group_names = Thruk::Base::array2hash( $groups, 'name' );
    my $groups_data = {};
    for my $group ( @{$groups} ) {
        next unless $group_names->{$group->{'name'}};
        next if scalar @{ $group->{'members'} } == 0;

        my $name = $group->{'name'};
        if( !defined $groups_data->{$name} ) {
            $groups_data->{$name} = {
                group => $group,
                hosts => {},
            };
        }

        for my $hostname ( @{ $group->{'members'} } ) {
            # show only hosts with proper authorization
            next unless defined $hosts_data->{$hostname};

            if(!$groups_data->{$name}->{'hosts'}->{$hostname}) {
                $groups_data->{$name}->{'hosts'}->{$hostname}->{'pending'}  = 0;
                $groups_data->{$name}->{'hosts'}->{$hostname}->{'ok'}       = 0;
                $groups_data->{$name}->{'hosts'}->{$hostname}->{'warning'}  = 0;
                $groups_data->{$name}->{'hosts'}->{$hostname}->{'unknown'}  = 0;
                $groups_data->{$name}->{'hosts'}->{$hostname}->{'critical'} = 0;
            }

            for my $servicename (keys %{$services_data->{$hostname}}) {
                my $state            = $services_data->{$hostname}->{$servicename}->{'state'};
                my $has_been_checked = $services_data->{$hostname}->{$servicename}->{'has_been_checked'};
                if( !$has_been_checked ) {
                    $groups_data->{$name}->{'hosts'}->{$hostname}->{'pending'}++;
                }
                elsif ( $state == 0 ) { $groups_data->{$name}->{'hosts'}->{$hostname}->{'ok'}++;       }
                elsif ( $state == 1 ) { $groups_data->{$name}->{'hosts'}->{$hostname}->{'warning'}++;  }
                elsif ( $state == 2 ) { $groups_data->{$name}->{'hosts'}->{$hostname}->{'critical'}++; }
                elsif ( $state == 3 ) { $groups_data->{$name}->{'hosts'}->{$hostname}->{'unknown'}++;  }
            }
        }
    }

    $c->stash->{'groups_data'} = $groups_data;

    return 1;
}

##########################################################
# create the services overview by servicegroup page
sub _process_overview_page_by_servicegroup {
    my( $c ) = @_;

    $c->stash->{'status_search_add_default_filter'} = "servicegroup";

    # which host to display?
    my($hostfilter, $servicefilter, $hostgroupfilter, $servicegroupfilter) = Thruk::Utils::Status::do_filter($c, 'ovr_');
    return 1 if $c->stash->{'has_error'};
    $c->stash->{'servicegroup'} = 'all' unless $c->stash->{'has_service_filter'};
    $c->stash->{'servicegroup'} = $c->req->parameters->{'servicegroup'} if $c->req->parameters->{'servicegroup'};

    my $groups;
    if($c->stash->{'servicegroup'} ne 'all') {
        $groups = [$c->stash->{'servicegroup'}];
    } else {
        $groups = $c->db->get_servicegroup_names_from_services( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'services' ), $servicefilter ] );
    }
    my $paged  = Thruk::Utils::page_data($c, $groups);
    my( @servicefilter , @servicegroupfilter);
    for my $group (@{$paged}) {
        push @servicefilter,      { groups => { '>=' => $group } };
        push @servicegroupfilter, { name => $group };
    }
    if(scalar @{$paged} > 0 && scalar @{$paged} <= 100) {
        $servicefilter      = Thruk::Utils::combine_filter('-and', [$servicefilter,      Thruk::Utils::combine_filter('-or', \@servicefilter)]);
        $servicegroupfilter = Thruk::Utils::combine_filter('-and', [$servicegroupfilter, Thruk::Utils::combine_filter('-or', \@servicegroupfilter)]);
    }

    # sort in all services and states
    my $services = $c->db->get_services( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'services' ), $servicefilter ],
                                        columns => Thruk::Base::array_uniq([
                                                qw/host_name description state has_been_checked groups/,
                                                (map { "host_".$_ } @{$Thruk::Backend::Provider::Livestatus::minimal_host_columns}),
                                            ]),
                                        );

    $groups = $c->db->get_servicegroups( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'servicegroups' ), $servicegroupfilter ] );

    my $hosts_data = {};
    $c->stash->{'hosts_data'} = $hosts_data;

    # join our groups together
    my $group_names = Thruk::Base::array2hash( $groups, 'name' );
    my $groups_data = {};
    for my $svc ( @{$services} ) {
        for my $name ( @{$svc->{'groups'}} ) {
            my $group = $group_names->{$name};
            next unless $group;
            next if scalar @{ $group->{'members'} } == 0;

            if( !defined $groups_data->{$name} ) {
                $groups_data->{$name} = {
                    group => $group,
                    hosts => {},
                };
            }

            my $hostname = $svc->{'host_name'};
            if(!$groups_data->{$name}->{'hosts'}->{$hostname}) {
                $groups_data->{$name}->{'hosts'}->{$hostname}->{'pending'}  = 0;
                $groups_data->{$name}->{'hosts'}->{$hostname}->{'ok'}       = 0;
                $groups_data->{$name}->{'hosts'}->{$hostname}->{'warning'}  = 0;
                $groups_data->{$name}->{'hosts'}->{$hostname}->{'unknown'}  = 0;
                $groups_data->{$name}->{'hosts'}->{$hostname}->{'critical'} = 0;
            }

            if(!$hosts_data->{$hostname}) {
                my $host = {};
                for my $key (@{$Thruk::Backend::Provider::Livestatus::minimal_host_columns}) {
                    my $val = $svc->{'host_'.$key};
                    my $hkey = "$key";
                    $hkey =~ s/^host_//gmx;
                    $host->{$hkey} = $val;
                }
                $host->{'peer_key'} = $svc->{'peer_key'};
                $hosts_data->{$hostname} = $host;
            }

            my $state            = $svc->{'state'};
            my $has_been_checked = $svc->{'has_been_checked'};
            if( !$has_been_checked ) {
                $groups_data->{$name}->{'hosts'}->{$hostname}->{'pending'}++;
            }
            elsif ( $state == 0 ) { $groups_data->{$name}->{'hosts'}->{$hostname}->{'ok'}++;       }
            elsif ( $state == 1 ) { $groups_data->{$name}->{'hosts'}->{$hostname}->{'warning'}++;  }
            elsif ( $state == 2 ) { $groups_data->{$name}->{'hosts'}->{$hostname}->{'critical'}++; }
            elsif ( $state == 3 ) { $groups_data->{$name}->{'hosts'}->{$hostname}->{'unknown'}++;  }
        }
    }

    $c->stash->{'groups_data'} = $groups_data;

    return 1;
}

##########################################################
# create the status grid page
sub _process_grid_page {
    my( $c ) = @_;

    die("no substyle!") unless defined $c->stash->{substyle};

    $c->stash->{'paneprefix'} = 'grd_';

    # which host to display?
    my($hostfilter, $servicefilter, $hostgroupfilter, $servicegroupfilter) = Thruk::Utils::Status::do_filter($c, "grd_");
    return 1 if $c->stash->{'has_error'};

    my($host_data, $services_data) = _fill_host_services_hashes($c,
                                            [ Thruk::Utils::Auth::get_auth_filter( $c, 'hosts' ), $hostfilter ],
                                            [ Thruk::Utils::Auth::get_auth_filter( $c, 'services' ), $servicefilter ],
                                            1, # all columns
                                    );

    # get all host/service groups
    my $groups;
    if( $c->stash->{substyle} eq 'host' ) {
        $groups = $c->db->get_hostgroups( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'hostgroups' ), $hostgroupfilter ] );
        $c->stash->{'status_search_add_default_filter'} = "hostgroup";
    }
    else {
        $groups = $c->db->get_servicegroups( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'servicegroups' ), $servicegroupfilter ] );
        $c->stash->{'status_search_add_default_filter'} = "servicegroup";
    }

    # sort in hosts / services
    my %joined_groups;
    for my $group ( @{$groups} ) {

        # only need groups with members
        next unless scalar @{ $group->{'members'} } > 0;

        my $name = $group->{'name'};
        if( !defined $joined_groups{$name} ) {
            $joined_groups{$name}->{'name'}  = $group->{'name'};
            $joined_groups{$name}->{'alias'} = $group->{'alias'};
            $joined_groups{$name}->{'hosts'} = {};
        }

        for my $member ( @{ $group->{'members'} } ) {
            my( $hostname, $servicename );
            if( $c->stash->{substyle} eq 'host' ) {
                $hostname = $member;
            } else {
                ( $hostname, $servicename ) = @{$member};
            }
            next unless defined $host_data->{$hostname};

            # add all services
            $joined_groups{$name}->{'hosts'}->{$hostname}->{'services'} = {} unless defined $joined_groups{$name}->{'hosts'}->{$hostname}->{'services'};
            if( $c->stash->{substyle} eq 'host' ) {
                for my $service ( sort keys %{ $services_data->{$hostname} } ) {
                    $joined_groups{$name}->{'hosts'}->{$hostname}->{'services'}->{$service} = 1;
                }
            }
            else {
                $joined_groups{$name}->{'hosts'}->{$hostname}->{'services'}->{$servicename} = 1;
            }
        }

        # remove empty groups
        if( scalar keys %{ $joined_groups{$name}->{'hosts'} } == 0 ) {
            delete $joined_groups{$name};
        }
    }

    my $sortedgroups = Thruk::Backend::Manager::sort_result($c, [(values %joined_groups)], { 'ASC' => 'name'});
    Thruk::Utils::set_paging_steps($c, Thruk::Base->config->{'group_paging_grid'});
    Thruk::Utils::page_data($c, $sortedgroups);

    $host_data     = undef;
    $services_data = undef;
    my @hostfilter;
    my @servicefilter;
    if( $c->stash->{substyle} eq 'host' ) {
        for my $group (@{$c->stash->{'data'}}) {
            push @hostfilter,    {      groups => { '>=' => $group->{name} } };
            push @servicefilter, { host_groups => { '>=' => $group->{name} } };
        }
        $hostfilter    = [$hostfilter,    Thruk::Utils::combine_filter('-or', \@hostfilter)];
        $servicefilter = [$servicefilter, Thruk::Utils::combine_filter('-or', \@servicefilter)];
    } else {
        for my $group (@{$c->stash->{'data'}}) {
            push @servicefilter, { groups => { '>=' => $group->{name} } };
        }
        $servicefilter = [$servicefilter, Thruk::Utils::combine_filter('-or', \@servicefilter)];
    }
    ($host_data, $services_data) = _fill_host_services_hashes($c,
                                            [ Thruk::Utils::Auth::get_auth_filter( $c, 'hosts' ), $hostfilter ],
                                            [ Thruk::Utils::Auth::get_auth_filter( $c, 'services' ), $servicefilter ],
                                            1, # all columns
                                    );

    for my $group (@{$c->stash->{'data'}}) {
        for my $hostname (keys %{$group->{hosts}}) {
            # merge host data
            %{$group->{hosts}->{$hostname}} = (%{$group->{hosts}->{$hostname}}, %{$host_data->{$hostname}});
            for my $servicename (keys %{$group->{hosts}->{$hostname}->{'services'}}) {
                $group->{hosts}->{$hostname}->{'services'}->{$servicename} = $services_data->{$hostname}->{$servicename};
            }
        }
    }

    $c->stash->{'show_column_select'} = 1;
    my $user_data = Thruk::Utils::get_user_data($c);
    $c->stash->{'default_columns'}->{'grd_'} = Thruk::Utils::Status::get_grid_columns($c);
    my $selected_columns = $c->req->parameters->{'grd_columns'} || $user_data->{'columns'}->{'grd'} || $c->config->{'default_overview_columns'};
    $c->stash->{'table_columns'}->{'grd_'}   = Thruk::Utils::Status::sort_table_columns($c->stash->{'default_columns'}->{'grd_'}, $selected_columns);
    $c->stash->{'has_user_columns'}->{'grd_'} = ($user_data->{'columns'}->{'grd'} || $c->req->parameters->{'grd_columns'}) ? 1 : 0;

    return 1;
}

##########################################################
# create the status summary page
sub _process_summary_page {
    my( $c ) = @_;

    die("no substyle!") unless defined $c->stash->{substyle};

    # which host to display?
    my($hostfilter, $servicefilter, $hostgroupfilter, $servicegroupfilter) = Thruk::Utils::Status::do_filter($c);
    return 1 if $c->stash->{'has_error'};

    # get all host/service groups
    my $groups;
    if( $c->stash->{substyle} eq 'host' ) {
        $groups = $c->db->get_hostgroups( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'hostgroups' ), $hostgroupfilter ] );
    }
    else {
        $groups = $c->db->get_servicegroups( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'servicegroups' ), $servicegroupfilter ] );
    }

    # set defaults for all groups
    my $all_groups;
    for my $group ( @{$groups} ) {
        $all_groups->{ $group->{'name'} } = Thruk::Utils::Status::summary_set_group_defaults($group);
    }

    $c->stash->{'status_search_add_default_filter'} = "servicegroup";
    if( $c->stash->{substyle} eq 'host' ) {
        # we need the hosts data
        my $host_data = $c->db->get_hosts( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'hosts' ), $hostfilter ],
                                          columns => [ @{$Thruk::Backend::Provider::Livestatus::minimal_host_columns}, qw/groups/ ],
                                             );
        for my $host ( @{$host_data} ) {
            for my $group ( @{ $host->{'groups'} } ) {
                next if !defined $all_groups->{$group};
                Thruk::Utils::Status::summary_add_host_stats( "", $all_groups->{$group}, $host );
            }
        }
        $c->stash->{'status_search_add_default_filter'} = "hostgroup";
    }
    # create a hash of all services
    my $service_columns = Thruk::Base::array_uniq([
        @{$Thruk::Backend::Provider::Livestatus::minimal_service_columns},
        (map { "host_".$_ } @{$Thruk::Backend::Provider::Livestatus::minimal_host_columns}),
        qw/groups host_groups/,
    ]);
    my $services_data = $c->db->get_services( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'services' ), $servicefilter ],
                                             columns => $service_columns,
                                            );

    my $groupsname = "host_groups";
    if( $c->stash->{substyle} eq 'service' ) {
        $groupsname = "groups";
    }

    my %host_already_added;
    my $uniq_services;
    for my $service ( @{$services_data} ) {
        next if exists $uniq_services->{$service->{'host_name'}}->{$service->{'description'}};
        $uniq_services->{$service->{'host_name'}}->{$service->{'description'}} = 1;
        for my $group ( @{ $service->{$groupsname} } ) {
            next if !defined $all_groups->{$group};

            if( $c->stash->{substyle} eq 'service' ) {
                if( !defined $host_already_added{$group}->{ $service->{'host_name'} } ) {
                    Thruk::Utils::Status::summary_add_host_stats( "host_", $all_groups->{$group}, $service );
                    $host_already_added{$group}->{ $service->{'host_name'} } = 1;
                }
            }
            Thruk::Utils::Status::summary_add_service_stats($all_groups->{$group}, $service);
        }
    }

    for my $group ( values %{$all_groups} ) {

        # remove empty groups
        $group->{'services_total'} = 0 unless defined $group->{'services_total'};
        $group->{'hosts_total'}    = 0 unless defined $group->{'hosts_total'};
        if( $group->{'services_total'} + $group->{'hosts_total'} == 0 ) {
            delete $all_groups->{ $group->{'name'} };
        }
    }

    my $sortedgroups = Thruk::Backend::Manager::sort_result($c, [(values %{$all_groups})], { 'ASC' => 'name'});
    Thruk::Utils::set_paging_steps($c, Thruk::Base->config->{'group_paging_summary'});
    Thruk::Utils::page_data($c, $sortedgroups);

    return 1;
}


##########################################################
# create the status details page
sub _process_combined_page {
    my( $c ) = @_;

    $c->stash->{hidetop}                = 1 unless defined $c->stash->{hidetop};
    $c->stash->{show_substyle_selector} = 0;
    $c->stash->{'show_column_select'}   = 1;
    $c->stash->{show_top_pane}          = 0;

    my $view_mode = $c->req->parameters->{'view_mode'} || 'html';

    my $user_data = Thruk::Utils::get_user_data($c);
    my $selected_hst_columns = $c->req->parameters->{'hst_columns'} || $user_data->{'columns'}->{'hst'} || $c->config->{'default_host_columns'};
    my $selected_svc_columns = $c->req->parameters->{'svc_columns'} || $user_data->{'columns'}->{'svc'} || $c->config->{'default_service_columns'};
    $c->stash->{'show_host_attempts'} = defined $c->config->{'show_host_attempts'} ? $c->config->{'show_host_attempts'} : 1;
    $c->stash->{'default_columns'}->{'hst_'} = Thruk::Utils::Status::get_host_columns($c);
    $c->stash->{'default_columns'}->{'svc_'} = Thruk::Utils::Status::get_service_columns($c);
    $c->stash->{'table_columns'}->{'hst_'}   = Thruk::Utils::Status::sort_table_columns($c->stash->{'default_columns'}->{'hst_'}, $selected_hst_columns);
    $c->stash->{'table_columns'}->{'svc_'}   = Thruk::Utils::Status::sort_table_columns($c->stash->{'default_columns'}->{'svc_'}, $selected_svc_columns);
    $c->stash->{'comments_by_host'}          = {};
    $c->stash->{'comments_by_host_service'}  = {};
    if($selected_hst_columns || $selected_svc_columns) {
        if(   ($selected_hst_columns && $selected_hst_columns =~ m/comments/mx)
           || ($selected_svc_columns && $selected_svc_columns =~ m/comments/mx)
        ) {
            Thruk::Utils::Status::set_comments_and_downtimes($c);
        }
    }
    $c->stash->{'has_user_columns'}->{'hst_'} = ($user_data->{'columns'}->{'hst'} || $c->req->parameters->{'hst_columns'}) ? 1 : 0;
    $c->stash->{'has_user_columns'}->{'svc_'} = ($user_data->{'columns'}->{'svc'} || $c->req->parameters->{'svc_columns'}) ? 1 : 0;

    # which host to display?
    my($hostfilter)           = Thruk::Utils::Status::do_filter($c, 'hst_');
    my(undef, $servicefilter) = Thruk::Utils::Status::do_filter($c, 'svc_');
    return 1 if $c->stash->{'has_error'};

    # services
    my $sorttype   = $c->req->parameters->{'sorttype_svc'}   || 1;
    my $sortoption = $c->req->parameters->{'sortoption_svc'} || 1;
    my $order      = "ASC";
    $order = "DESC" if $sorttype eq "2";
    my $sortoptions = {
        '1' => [ [ 'host_name',   'description' ], 'host name' ],
        '2' => [ [ 'description', 'host_name' ],   'service name' ],
        '3' => [ [ 'has_been_checked', 'state', 'host_name', 'description' ], 'service status' ],
        '4' => [ [ 'last_check',              'host_name', 'description' ], 'last check time' ],
        '5' => [ [ 'current_attempt',         'host_name', 'description' ], 'attempt number' ],
        '6' => [ [ 'last_state_change_order', 'host_name', 'description' ], 'state duration' ],
        '7' => [ [ 'peer_name', 'host_name', 'description' ], 'site' ],
        '9' => [ [ 'plugin_output', 'host_name', 'description' ], 'status information' ],
    };
    my $sortnum = 10;
    for my $col (@{$c->stash->{'default_columns'}->{'svc_'}}) {
        next if defined $col->{'sortby'};

        my $field = $col->{'field'};
        if($field =~ m/^cust_(.*)$/mx) {
            $field = uc($1);
            $sortoptions->{$sortnum} = [["custom_variables ".$field, "host_custom_variables ".$field], lc($col->{"title"}) ];
        } else {
            $sortoptions->{$sortnum} = [[$field], lc($col->{"title"}) ];
        }
        $col->{'sortby'} = $sortnum;
        $sortnum++;
    }
    $sortoption = 1 if !defined $sortoptions->{$sortoption};
    $c->stash->{'svc_orderby'}  = $sortoptions->{$sortoption}->[1];
    $c->stash->{'svc_orderdir'} = $order;

    my $extra_svc_columns = [];
    my $extra_hst_columns = [];
    if($c->config->{'use_lmd_core'} && $c->stash->{'show_long_plugin_output'} ne 'inline' && $view_mode eq 'html') {
        push @{$extra_svc_columns}, 'has_long_plugin_output';
        push @{$extra_hst_columns}, 'has_long_plugin_output';
    } else {
        push @{$extra_svc_columns}, 'long_plugin_output';
        push @{$extra_hst_columns}, 'long_plugin_output';
    }
    push @{$extra_svc_columns}, 'contacts' if ($selected_svc_columns && $selected_svc_columns =~ m/contacts/imx);

    my $services = $c->db->get_services( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'services' ), $servicefilter ],
                                         sort   => { $order => $sortoptions->{$sortoption}->[0] },
                                         extra_columns => $extra_svc_columns,
                                       );
    $c->stash->{'services'} = $services;
    if( $sortoption eq "6" and defined $services ) { @{ $c->stash->{'services'} } = reverse @{ $c->stash->{'services'} }; }


    # hosts
    $sorttype   = $c->req->parameters->{'sorttype_hst'}   || 1;
    $sortoption = $c->req->parameters->{'sortoption_hst'} || 7;
    $order      = "ASC";
    $order = "DESC" if $sorttype eq "2";
    $sortoptions = {
        '1' => [ 'name', 'host name' ],
        '4' => [ [ 'last_check',              'name' ], 'last check time' ],
        '5' => [ [ 'current_attempt',         'name' ], 'attempt number'  ],
        '6' => [ [ 'last_state_change_order', 'name' ], 'state duration'  ],
        '8' => [ [ 'has_been_checked', 'state', 'name' ], 'host status'  ],
        '9' => [ [ 'plugin_output', 'name' ], 'status information' ],
    };
    $sortnum = 10;
    for my $col (@{$c->stash->{'default_columns'}->{'hst_'}}) {
        next if defined $col->{'sortby'};

        my $field = $col->{'field'};
        if($field =~ m/^cust_(.*)$/mx) {
            $field = uc($1);
            $sortoptions->{$sortnum} = [["custom_variables ".$field], lc($col->{"title"}) ];
        } else {
            $sortoptions->{$sortnum} = [[$field], lc($col->{"title"}) ];
        }
        $col->{'sortby'} = $sortnum;
        $sortnum++;
    }
    $sortoption = 1 if !defined $sortoptions->{$sortoption};
    $c->stash->{'hst_orderby'}  = $sortoptions->{$sortoption}->[1];
    $c->stash->{'hst_orderdir'} = $order;
    push @{$extra_hst_columns}, 'contacts' if ($selected_hst_columns && $selected_hst_columns =~ m/contacts/imx);

    my $hosts = $c->db->get_hosts( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'hosts' ), $hostfilter ],
                                   sort   => { $order => $sortoptions->{$sortoption}->[0] },
                                   extra_columns => $extra_hst_columns,
                                 );
    $c->stash->{'hosts'} = $hosts;
    if( $sortoption == 6 and defined $hosts ) { @{ $c->stash->{'hosts'} } = reverse @{ $c->stash->{'hosts'} }; }

    $c->stash->{'hosts_limit_hit'}    = 0;
    $c->stash->{'services_limit_hit'} = 0;

    if( $view_mode eq 'xls' ) {
        Thruk::Utils::Status::set_selected_columns($c, ['host_', 'service_']);
        Thruk::Utils::Status::set_comments_and_downtimes($c);
        $c->res->headers->header( 'Content-Disposition', 'attachment; filename="status.xls"' );
        $c->stash->{'hosts'}     = $hosts;
        $c->stash->{'services'}  = $services;
        $c->stash->{'template'}  = 'excel/status_combined.tt';
        return $c->render_excel();
    }
    elsif ( $view_mode eq 'json' ) {
        my $allowed      = $c->check_user_roles("authorized_for_configuration_information");
        my $allowed_list = Thruk::Utils::get_exposed_custom_vars($c->config);
        my $show_full_commandline = $c->config->{'show_full_commandline'};
        Thruk::Utils::fill_commands_cache($c);
        # remove custom macro colums which could contain confidential informations
        for my $h (@{$hosts}) {
            Thruk::Utils::set_allowed_rows_data($h, $allowed, $allowed_list, $show_full_commandline);
        }
        for my $s (@{$services}) {
            Thruk::Utils::set_allowed_rows_data($s, $allowed, $allowed_list, $show_full_commandline);
        }
        my $json = {
            'hosts'    => $hosts,
            'services' => $services,
        };
        return $c->render(json => $json);
    } else {
        if($c->config->{problems_limit}) {
            if(scalar @{$c->stash->{'hosts'}} > $c->config->{problems_limit} && !$c->req->parameters->{'show_all_hosts'}) {
                $c->stash->{'hosts_limit_hit'}    = 1;
                $c->stash->{'hosts'}              = [splice(@{$c->stash->{'hosts'}}, 0, $c->config->{problems_limit})];
            }
            if(scalar @{$c->stash->{'services'}} > $c->config->{problems_limit} && !$c->req->parameters->{'show_all_services'}) {
                $c->stash->{'services_limit_hit'} = 1;
                $c->stash->{'services'}           = [splice(@{$c->stash->{'services'}}, 0, $c->config->{problems_limit})];
            }
        }
    }

    # set audio file to play
    Thruk::Utils::Status::set_audio_file($c);

    return 1;
}

##########################################################
# create the perfmap details page
sub _process_perfmap_page {
    my( $c ) = @_;

    my $view_mode = $c->req->parameters->{'view_mode'} || 'html';

    # which host to display?
    my(undef, $servicefilter) = Thruk::Utils::Status::do_filter($c);
    return 1 if $c->stash->{'has_error'};

    # do the sort
    my $sorttype   = $c->req->parameters->{'sorttype'}   || 1;
    my $sortoption = $c->req->parameters->{'sortoption'} || 1;
    my $order      = "ASC";
    $order = "DESC" if $sorttype == 2;

    # get all services
    my $services = $c->db->get_services( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'services' ), $servicefilter ]  );
    my $data = [];
    my $keys = {};
    for my $svc (@{$services}) {
        $svc->{'perf'} = {};
        my $perfdata = $svc->{'perf_data'};
        my @matches  = $perfdata =~ m/([^\s]+|'[^']+')=([^\s]*)/gmxoi;
        for(my $x = 0; $x < scalar @matches; $x=$x+2) {
            my $key = $matches[$x];
            my $val = $matches[$x+1];
            $key =~ s/^'//gmxo;
            $key =~ s/'$//gmxo;
            $val =~ s/;.*$//gmxo;
            $val =~ s/,/./gmxo;
            $val =~ m/^([\d\.\-]+)(.*?)$/mx;
            if(defined $val && defined $1) { # $val && required, triggers unused var in t/086-Test-Vars.t otherwise
                my($num, $unit) = ($1, $2);
                $svc->{'perf'}->{$key} = 1;
                $keys->{$key} = 1;
                # flatten performance data into service unless that key already exists
                if($unit && $unit eq 'B') {
                    ($num,$unit) = Thruk::Utils::reduce_number($num, $unit);
                    $num = sprintf("%.2f", $num);
                }
                $svc->{$key} = $num.$unit unless defined $svc->{$key};
                $svc->{$key.'_sort'} = $num;
            }
        }
        push @{$data}, $svc;
    }

    if( $view_mode eq 'xls' ) {
        Thruk::Utils::Status::set_selected_columns($c, [''], 'service', ['Hostname', 'Service', 'Status', sort keys %{$keys}]);
        my $filename = 'performancedata.xls';
        $c->res->headers->header( 'Content-Disposition', qq[attachment; filename="] . $filename . q["] );
        $c->stash->{'name'}      = 'Performance';
        $c->stash->{'data'}      = $data;
        $c->stash->{'col_tr'}    = { 'Hostname' => 'host_name', 'Service' => 'description', 'Status' => 'state' };
        $c->stash->{'template'}  = 'excel/generic.tt';
        return $c->render_excel();
    }
    if ( $view_mode eq 'json' ) {
        # remove unwanted colums
        for my $d (@{$data}) {
            delete $d->{'peer_key'};
            delete $d->{'perf'};
            delete $d->{'has_been_checked'};
            for my $k (keys %{$keys}) {
                delete $d->{$k.'_sort'};
            }
        }
        return $c->render(json => $data);
    }

    # sort things?
    if(defined $keys->{$sortoption}) {
        $data = Thruk::Backend::Manager::sort_result($c, $data, { $order => $sortoption.'_sort'});
    } elsif($sortoption eq "1") {
        $c->stash->{'sortoption'}  = '';
    } elsif($sortoption eq "2") {
        $data = Thruk::Backend::Manager::sort_result($c, $data, { $order => ['description', 'host_name']});
        $c->stash->{'sortoption'}  = '';
    }

    $c->stash->{'perf_keys'} = $keys;
    Thruk::Utils::page_data($c, $data);

    $c->stash->{'data_sorted'} = { type => $sorttype, option => $sortoption };

    return 1;
}

##########################################################
# store bookmarks and redirect to last page
sub _process_bookmarks {
    my( $c ) = @_;

    my $referer       = $c->req->parameters->{'referer'} || 'status.cgi';
    my $bookmark      = $c->req->parameters->{'bookmark'};
    my $bookmarks     = Thruk::Utils::list($c->req->parameters->{'bookmarks'}  // []);
    my $bookmarksp    = Thruk::Utils::list($c->req->parameters->{'bookmarksp'} // []);
    my $section       = $c->req->parameters->{'section'};
    my $newname       = $c->req->parameters->{'newname'};
    my $button        = $c->req->parameters->{'addb'};
    my $save          = $c->req->parameters->{'saveb'};
    my $public        = $c->req->parameters->{'public'} || 0;
    my $save_backends = $c->req->parameters->{'save_backends'} || 0;
    my $link_target   = $c->req->parameters->{'link_target'} || "";

    # public only allowed for bookmark admins
    if($public) {
        if(!$c->check_user_roles('authorized_for_public_bookmarks')) {
            $public = 0;
        }
    }

    my $data   = Thruk::Utils::get_user_data($c);
    my $global = $c->stash->{global_user_data};
    my $done   = 0;

    # add new bookmark
    my $keep  = {};
    my $keepp = {};
    if(    defined $newname   and $newname  ne ''
       and defined $bookmark  and $bookmark ne ''
       and defined $section   and $section  ne ''
       and (    ( defined $button and $button eq 'add bookmark' )
             or ( defined $save   and $save   eq 'save changes' )
           )
    ) {
        my $new_bookmark = [ $newname, $bookmark ];
        if($save_backends) {
            my $backends = Thruk::Utils::backends_list_to_hash($c);
            push @{$new_bookmark}, $backends;
        } else {
            push @{$new_bookmark}, '';
        }
        push @{$new_bookmark}, $link_target;
        if($public) {
            $global->{'bookmarks'}->{$section} = [] unless defined $global->{'bookmarks'}->{$section};
            push @{$global->{'bookmarks'}->{$section}}, $new_bookmark;
            if(Thruk::Utils::store_global_user_data($c, $global)) {
                Thruk::Utils::set_message( $c, 'success_message', 'Bookmark added' );
            }
            $keepp->{$section}->{$newname} = 1;
            push @{$bookmarksp}, $section.'::'.$newname;
        } else {
            $data->{'bookmarks'}->{$section} = [] unless defined $data->{'bookmarks'}->{$section};
            push @{$data->{'bookmarks'}->{$section}}, $new_bookmark;
            if(Thruk::Utils::store_user_data($c, $data)) {
                Thruk::Utils::set_message( $c, 'success_message', 'Bookmark added' );
            }
            $keep->{$section}->{$newname} = 1;
            push @{$bookmarks}, $section.'::'.$newname;
        }
        $done++;
    }

    # remove existing bookmarks
    if(    ( defined $button and $button eq 'add bookmark' )
        or ( defined $save   and $save   eq 'save changes' )) {
        for my $bookmark (@{Thruk::Base::list($bookmarks)}) {
            next unless defined $bookmark;
            my($section, $name) = split(/::/mx, $bookmark, 2);
            next unless defined $name;
            $keep->{$section}->{$name} = 1;
        }

        my $order = {};
        my $x = 0;
        for my $b (@{Thruk::Base::list($bookmarks)}) {
            my($section, $name) = split(/::/mx, $b, 2);
            $order->{$section}->{$name} = $x++;
        }

        my $new  = {};
        my $dups = {};
        for my $section (keys %{$data->{'bookmarks'}}) {
            # reverse ensures the last bookmark with same name superseeds
            for my $link ( reverse @{$data->{'bookmarks'}->{$section}} ) {
                next unless exists $keep->{$section}->{$link->[0]};
                next if     exists $dups->{$section}->{$link->[0]};
                push @{$new->{$section}}, $link;
                $dups->{$section}->{$link->[0]} = 1;
            }

            # sort
            @{$new->{$section}} = sort { $order->{$section}->{$a->[0]} <=> $order->{$section}->{$b->[0]} } @{$new->{$section}} if defined $new->{$section};
        }

        $data->{'bookmarks'} = $new;
        if(Thruk::Utils::store_user_data($c, $data)) {
            Thruk::Utils::set_message( $c, 'success_message', 'Bookmarks updated' );
        }
        $done++;

        if($c->check_user_roles('authorized_for_public_bookmarks')) {
            for my $bookmark (@{Thruk::Base::list($bookmarksp)}) {
                next unless defined $bookmark;
                my($section, $name) = split(/::/mx, $bookmark, 2);
                $keepp->{$section}->{$name} = 1;
            }

            my $order = {};
            my $x = 0;
            for my $b (@{Thruk::Base::list($bookmarksp)}) {
                my($section, $name) = split(/::/mx, $b, 2);
                $order->{$section}->{$name} = $x++;
            }

            $new  = {};
            $dups = {};
            for my $section (keys %{$global->{'bookmarks'}}) {
                # reverse ensures the last bookmark with same name superseeds
                for my $link ( reverse @{$global->{'bookmarks'}->{$section}} ) {
                    next unless exists $keepp->{$section}->{$link->[0]};
                    next if     exists $dups->{$section}->{$link->[0]};
                    push @{$new->{$section}}, $link;
                    $dups->{$section}->{$link->[0]} = 1;
                }
                @{$new->{$section}} = sort { $order->{$section}->{$a->[0]} <=> $order->{$section}->{$b->[0]} } @{$new->{$section}} if defined $new->{$section};
            }

            $global->{'bookmarks'} = $new;
            Thruk::Utils::store_global_user_data($c, $global);
            $done++;
        }

    }

    unless($done) {
        Thruk::Utils::set_message( $c, 'fail_message', 'nothing to do!' );
    }

    return $c->redirect_to($referer);
}


##########################################################
# check for search results
sub _process_verify_time {
    my($c) = @_;

    my $verified;
    my $error    = 'not a valid date';
    my $time = $c->req->parameters->{'time'};
    my $start;
    if(defined $time) {
        undef $@;
        $start = Thruk::Utils::parse_date($c, $time);
        if($start) {
            $verified = 1;
        }
        if($@) {
            $error = _strip_line($@);
        }
    }

    my $duration = $c->req->parameters->{'duration'};
    my $end;
    if($verified && $duration) {
        undef $verified;
        undef $@;
        $end = Thruk::Utils::parse_date($c, $duration);
        if($end) {
            $verified = 1;
        }
        if($@) {
            $error = _strip_line($@);
        }
    }

    # check for mixed up start/end
    my $id = $c->req->parameters->{'duration_id'};
    if($start && $end && $id && $id eq 'start_time') {
        ($start, $end) = ($end, $start);
    }

    my $now = time();
    if($start && $end && $start > $end) {
        $error = 'End date must be after start date';
        undef $verified;
    }
    elsif($start && $end && $end < $now) {
        $error = 'End date must be in the future';
        undef $verified;
    }
    elsif($start && $end && $c->config->{downtime_max_duration}) {
        my $max_duration = Thruk::Utils::expand_duration($c->config->{downtime_max_duration});
        my $duration = $end - $start;
        if($duration > $max_duration) {
            $error = 'Duration exceeds maximum<br>allowed value: '.Thruk::Utils::Filter::duration($max_duration);
            undef $verified;
        }
    }

    my $json = { 'verified' => $verified ? 'true' : 'false', 'error' => $error };
    return $c->render(json => $json);
}

##########################################################
# check for search results
sub _process_set_default_columns {
    my( $c ) = @_;

    return(1, 'invalid request') unless Thruk::Utils::check_csrf($c);

    my $val  = $c->req->parameters->{'value'} || '';
    my $type = $c->req->parameters->{'type'}  || '';
    if($type ne 'svc' && $type ne 'hst' && $type ne 'ovr' && $type ne 'grd') {
        return(1, 'unknown type');
    }

    my $data = Thruk::Utils::get_user_data($c);

    if($val eq "") {
        delete $data->{'columns'}->{$type};
    } else {
        $data->{'columns'}->{$type} = $val;
    }

    if(Thruk::Utils::store_user_data($c, $data)) {
        if($val eq "") {
            return(0, 'Default columns restored' );
        }
        return(0, 'Default columns updated' );
    }

    return(1, "saving user data failed");
}

##########################################################
# replace macros in given string for a host/service
sub _replacemacros {
    my( $c ) = @_;

    my $host    = $c->req->parameters->{'host'};
    my $service = $c->req->parameters->{'service'};
    my $data    = $c->req->parameters->{'data'};

    # replace macros
    my $objs;
    if($service) {
        $objs = $c->db->get_services( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'services' ), { host_name => $host, description => $service } ] );
    } else {
        $objs = $c->db->get_hosts( filter => [ Thruk::Utils::Auth::get_auth_filter( $c, 'hosts' ), { name => $host } ] );
    }
    my $obj = $objs->[0];
    return(1, 'no such object') unless $obj;

    if($c->req->parameters->{'dataJson'}) {
        my $new       =  {};
        my $overal_rc = 0;
        my $data = decode_json($c->req->parameters->{'dataJson'});
        for my $key (keys %{$data}) {
            my($replaced, $rc) = $c->db->replace_macros($data->{$key}, {host => $obj, service => $service ? $obj : undef, skip_user => 1});
            $new->{$key} = $replaced;
            $overal_rc = $rc if $rc > $overal_rc;
        }
        return(!$overal_rc, $new);
    }

    my($new, $rc) = $c->db->replace_macros($data, {host => $obj, service => $service ? $obj : undef, skip_user => 1});
    # replace_macros returns 1 on success, js expects 0 on success, so revert rc here

    return(!$rc, $new);
}

##########################################################
sub _fill_host_services_hashes {
    my($c, $hostfilter, $servicefilter, $all_columns) = @_;

    my $host_data;
    my $tmp_host_data = $c->db->get_hosts( filter => $hostfilter, columns => $all_columns ? undef : [qw/name/] );
    if( defined $tmp_host_data ) {
        for my $host ( @{$tmp_host_data} ) {
            $host_data->{ $host->{'name'} } = $host;
        }
    }

    my $services_data;
    my $tmp_services = $c->db->get_services( filter => $servicefilter, columns => $all_columns ? undef : [qw/host_name description/] );
    if( defined $tmp_services ) {
        for my $service ( @{$tmp_services} ) {
            $services_data->{ $service->{'host_name'} }->{ $service->{'description'} } = $service;
        }
    }
    return($host_data, $services_data);
}

##########################################################
# return long plugin output
sub _long_plugin_output {
    my( $c ) = @_;

    my $host    = $c->req->parameters->{'host'};
    my $service = $c->req->parameters->{'service'};

	my $columns = [qw/has_been_checked plugin_output long_plugin_output/];
    my $objs;
    if($service) {
        $objs = $c->db->get_services(
            filter  => [ Thruk::Utils::Auth::get_auth_filter( $c, 'services' ), { host_name => $host, description => $service } ],
            columns => $columns,
        );
    } else {
        $objs = $c->db->get_hosts(
            filter  => [ Thruk::Utils::Auth::get_auth_filter( $c, 'hosts' ), { name => $host } ],
            columns => $columns,
        );
    }
    my $obj = $objs->[0];
    return(1, 'no such object') unless $obj;

    $c->stash->{obj}      = $obj;
    $c->stash->{template} = '_plugin_output.tt';

    return 1;
}

##########################################################

1;
