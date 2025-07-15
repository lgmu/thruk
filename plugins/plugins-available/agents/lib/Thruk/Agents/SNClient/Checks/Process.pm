package Thruk::Agents::SNClient::Checks::Process;

use warnings;
use strict;

use Thruk::Agents::SNClient ();
use Thruk::Base ();
use Thruk::Utils::Agents ();
use Thruk::Utils::IO ();

=head1 NAME

Thruk::Agents::SNClient::Checks::Process - returns process checks for snclient

=head1 METHODS

=cut

##########################################################

=head2 get_checks

    get_checks()

returns snclient checks

=cut
sub get_checks {
    my($self, $c, $inventory, $hostname, $password, $section) = @_;
    my $checks = [];

    return unless $inventory->{'process'};

    my $procs = Thruk::Base::list($inventory->{'process'});

    # generic processes check
    if(scalar @{$procs} > 0) {
        push @{$checks}, {
            'id'       => 'proc',
            'name'     => 'processes',
            'check'    => 'check_process',
            'parent'   => 'agent version',
        };
    }

    # generic zombie processes check
    if(scalar @{$procs} > 0) {
        push @{$checks}, {
            'id'       => 'proc.zombies',
            'name'     => 'zombie processes',
            'check'    => 'check_process',
            'args'     => {
                    'empty-syntax'  => "%(status) - no zombie processes found",
                    'top-syntax'    => "%(status) - %(count) zombie processes found.%(list)",
                    'filter'        => "state=zombie",
                    'empty-state'   => 0,
                    'perf-config'   => 'rss(ignored:true) virtual(ignored:true) cpu(ignored:true)',
                    'detail-syntax' => '\\n%(process): pid: %(pid) / user: %(username) / age: %(creation | age | duration)',
            },
            'parent'   => 'agent version',
        };
    }

    # specifically configured process checks
    my $already_checked = {};
    my $wanted = [];
    my $configs = Thruk::Base::list($c->config->{'Thruk::Agents'}->{'snclient'}->{'proc'});
    for my $cfg (@{$configs}) {
        next unless Thruk::Utils::Agents::check_wildcard_match($hostname, ($cfg->{'host'} // 'ANY'));
        next unless Thruk::Utils::Agents::check_wildcard_match($section, ($cfg->{'section'} // 'ANY'));
        if($cfg->{'match'}) {
            for my $n (@{Thruk::Base::list($cfg->{'match'})}) {
                for my $u (@{Thruk::Base::list($cfg->{'user'} // 'ANY')}) {
                    my $local = Thruk::Utils::IO::dclone($cfg);
                    $local->{'user'}  = $u;
                    $local->{'match'} = $n;
                    $local->{'name'}  = Thruk::Base::list($cfg->{'name'} // 'process %e %u')->[0];
                    push @{$wanted}, $local;
                }
            }
        } elsif($cfg->{'name'}) {
            for my $name (@{Thruk::Base::list($cfg->{'name'})}) {
                for my $u (@{Thruk::Base::list($cfg->{'user'} // 'ANY')}) {
                    my $local = Thruk::Utils::IO::dclone($cfg);
                    $local->{'user'}  = $u;
                    $local->{'name'} = $name;
                    push @{$wanted}, $local;
                }
            }
        }
    }
    for my $p (@{$procs}) {
        for my $cfg (@{$wanted}) {
            my $filter = [];
            my $args = [
                "top-syntax='%{status} - %{count} processes, memory %{rss|h}B, cpu %{cpu:fmt=%.1f}%, started %{oldest:age|duration} ago'",
            ];
            my $match;
            if($cfg->{'match'}) {
                my $m = Thruk::Utils::Agents::check_wildcard_match($p->{'command_line'}, $cfg->{'match'}, 1);
                next unless defined $m;
                if($m ne 'ANY') {
                    my($f, $v) = Thruk::Agents::SNClient::make_filter("command_line", $m, 1);
                    push @{$filter}, $f;
                    $match = $v;
                }
            } elsif($cfg->{'name'}) {
                my $m = Thruk::Utils::Agents::check_wildcard_match($p->{'exe'}, $cfg->{'name'});
                next unless defined $m;
                my($f, $v) = Thruk::Agents::SNClient::make_filter("exe", $m);
                $match = $v;
                $cfg->{'_name'} = "process ".$v;
                if($v eq $cfg->{'name'}) {
                    push @{$args}, sprintf("process='%s'", $v);
                } else {
                    push @{$filter}, $f;
                }
            }

            my $user = Thruk::Utils::Agents::check_wildcard_match(($p->{'username'}//''), ($cfg->{'user'} // 'ANY'));
            next unless $user;
            if($user ne 'ANY') {
                my($f, $v) = Thruk::Agents::SNClient::make_filter("username", $user);
                push @{$filter}, $f;
            }
            my $username = $user ne 'ANY' ? $p->{'username'} : "";

            my $has_zero = 0;
            if($cfg->{'warn'}) {
                my($low,$high) = split(/:/mx,$cfg->{'warn'});
                if(!defined $high) { $high = $low; $low  = 1; }
                push @{$args}, sprintf("warn='count < %d || count > %d'", $low, $high);
                $has_zero = 1 if $low <= 0;
            }

            if($cfg->{'crit'}) {
                my($low,$high) = split(/:/mx,$cfg->{'crit'});
                if(!defined $high) { $high = $low; $low  = 1; }
                push @{$args}, sprintf("crit='count < %d || count > %d'", $low, $high);
                $has_zero = 1 if $low <= 0;
            }

            if($has_zero) {
                # if zero is a valid threshold, do not make check unknown
                push @{$args}, 'empty-state=0';
            }

            push @{$args}, sprintf('"filter=%s"', join(" and ", @{$filter})) if scalar @{$filter} > 0;

            my $id = 'proc.'.Thruk::Utils::Agents::to_id($match.'_'.($username || 'ANY'));
            next if $already_checked->{$id};
            $already_checked->{$id} = 1;
            my $exe = $p->{'exe'};
            $exe =~ s/^\[//gmx;
            $exe =~ s/\]$//gmx;
            push @{$checks}, {
                'id'       => $id,
                'name'     => Thruk::Agents::SNClient::make_name($cfg->{'_name'} // $cfg->{'name'} // 'proc %e %u', { '%e' => $exe, '%u' => $username }),
                'check'    => 'check_process',
                'args'     => $args,
                'parent'   => 'agent version',
                'info'     => $p,
                '_GRAPH_SOURCE' => 'cpu',
            };
        }
    }

    return $checks;
}

##########################################################

1;
