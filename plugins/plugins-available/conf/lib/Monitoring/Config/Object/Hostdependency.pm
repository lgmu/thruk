package Monitoring::Config::Object::Hostdependency;

use warnings;
use strict;

use parent 'Monitoring::Config::Object::Parent';

=head1 NAME

Monitoring::Config::Object::Hostdependency - Hostdependency Object Configuration

=head1 DESCRIPTION

Defaults for hostdependency objects

=cut

##########################################################

$Monitoring::Config::Object::Hostdependency::Defaults = {
    'name'                          => { type => 'STRING', cat => 'Extended' },
    'use'                           => { type => 'LIST', link => 'hostdependency', cat => 'Basic' },
    'register'                      => { type => 'BOOL', cat => 'Extended' },

    'dependent_host_name'           => { type => 'LIST', 'link' => 'host' },
    'dependent_hostgroup_name'      => { type => 'LIST', 'link' => 'hostgroup' },
    'host_name'                     => { type => 'LIST', 'link' => 'host' },
    'hostgroup_name'                => { type => 'LIST', 'link' => 'hostgroup' },
    'inherits_parent'               => { type => 'BOOL' },
    'execution_failure_criteria'    => { type => 'ENUM', values => ['o','d','u','p','n'], keys => [ 'Ok', 'Down', 'Unreachable', 'Pending', 'None' ] },
    'notification_failure_criteria' => { type => 'ENUM', values => ['o','d','u','p','n'], keys => [ 'Ok', 'Down', 'Unreachable', 'Pending', 'None' ] },
    'dependency_period'             => { type => 'STRING', link => 'timeperiod' },

    'host'                          => { type => 'ALIAS', 'name' => 'host_name' },
    'master_host'                   => { type => 'ALIAS', 'name' => 'host_name' },
    'master_host_name'              => { type => 'ALIAS', 'name' => 'host_name' },
    'hostgroup'                     => { type => 'ALIAS', 'name' => 'hostgroup_name' },
    'hostgroups'                    => { type => 'ALIAS', 'name' => 'hostgroup_name' },
    'dependent_hostgroup'           => { type => 'ALIAS', 'name' => 'dependent_hostgroup_name' },
    'dependent_hostgroups'          => { type => 'ALIAS', 'name' => 'dependent_hostgroup_name' },
    'dependent_host'                => { type => 'ALIAS', 'name' => 'dependent_host_name' },
    'notification_failure_options'  => { type => 'ALIAS', 'name' => 'notification_failure_criteria' },
    'execution_failure_options'     => { type => 'ALIAS', 'name' => 'execution_failure_criteria' },
};

$Monitoring::Config::Object::Hostdependency::primary_keys = ['dependent_host_name', ['dependent_hostgroup_name', 'host_name', 'hostgroup_name']];
$Monitoring::Config::Object::Hostdependency::Defaults::standard_keys = [ 'dependent_host_name', 'host_name', 'execution_failure_criteria', 'notification_failure_criteria' ];

##########################################################

=head1 METHODS

=head2 BUILD

return new object

=cut
sub BUILD {
    my $class = shift || __PACKAGE__;
    my $self = {
        'type'        => 'hostdependency',
        'primary_key' => $Monitoring::Config::Object::Hostdependency::primary_keys,
        'default'     => $Monitoring::Config::Object::Hostdependency::Defaults,
        'standard'    => $Monitoring::Config::Object::Hostdependency::Defaults::standard_keys,
        'primary_name_all_keys' => 1,
    };
    bless $self, $class;
    return $self;
}

##########################################################

1;
