package Thruk::Utils::CLI::Selfcheck;

=head1 NAME

Thruk::Utils::CLI::Selfcheck - Selfcheck CLI module

=head1 DESCRIPTION

The selfcheck command runs a couple of selfchecks to identify typical issues when using Thruk.

=head1 SYNOPSIS

  Usage: thruk [globaloptions] selfcheck <checktype[s]>... [--heal]

=head1 OPTIONS

=over 4

=item B<help>

    print help and exit

=item B<checktype>

    available check types are:

    - all                       runs all checks below
    - filesystem                runs filesystem checks
    - logfiles                  runs logfile checks
    - lmd                       runs lmd related checks
    - recurring_downtimes       runs recurring downtimes checks
    - reports                   runs reporting checks
    - logcache                  runs logcache checks
    - backends                  runs backend connection checks

=item B<--heal>

    try automatic heal if possible.

=back

=cut

use warnings;
use strict;

##############################################

=head1 METHODS

=head2 cmd

    cmd([ $options ])

=cut
sub cmd {
    my($c, $action, $commandoptions, $data) = @_;
    $c->stats->profile(begin => "_cmd_selfcheck($action)");

    if(!$c->check_user_roles('authorized_for_admin')) {
        return("ERROR - authorized_for_admin role required", 1);
    }

    # parse options
    my $opt = {};
    Getopt::Long::Configure('pass_through');
    Getopt::Long::GetOptionsFromArray($commandoptions,
       "heal" => \$opt->{'heal'},
    ) or do {
        return(Thruk::Utils::CLI::get_submodule_help(__PACKAGE__));
    };

    require Thruk::Utils::SelfCheck;
    my($rc, $msg, $details) = Thruk::Utils::SelfCheck->self_check($c, $commandoptions, $opt);
    $data->{'all_stdout'} = 1;

    $c->stats->profile(end => "_cmd_selfcheck($action)");
    return($msg."\n".$details."\n", $rc);
}

##############################################

=head1 EXAMPLES

Run all selfchecks

  %> thruk selfcheck all

Run all selfchecks except filesystem

  %> thruk selfcheck 'all,!filesystem'

Run lmd and filesystem selfcheck

  %> thruk selfcheck 'lmd,filesystem'

=cut

##############################################

1;
