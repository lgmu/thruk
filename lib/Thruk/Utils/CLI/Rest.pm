package Thruk::Utils::CLI::Rest;

=head1 NAME

Thruk::Utils::CLI::Rest - Rest API CLI module

=head1 DESCRIPTION

The rest command is a cli interface to the rest api.

=head1 SYNOPSIS

  Usage:

    - simple query:
      thruk [globaloptions] rest [-m method] [-d postdata] <url>

    - multiple queries_:
      thruk [globaloptions] rest [-m method] [-d postdata] <url> [-m method] [-d postdata] <url>

=cut

use warnings;
use strict;
use Cpanel::JSON::XS qw/decode_json/;
use Cwd ();
use Getopt::Long ();
use POSIX ();
use Template ();

use Thruk::Action::AddDefaults ();
use Thruk::Backend::Manager ();
use Thruk::Request ();
use Thruk::Utils::CLI ();
use Thruk::Utils::Log qw/:all/;

our $skip_backends = \&_skip_backends;

##############################################

=head1 METHODS

=head2 cmd

    cmd([ $options ])

=cut
sub cmd {
    my($c, undef, $commandoptions, undef, $src, $opt) = @_;

    # split args by url, then parse leading options. In case there is only one
    # url, all options belong to this url.
    my $opts = $opt->{'_parsed_args'} // _parse_args($commandoptions, $src);
    if(ref $opts eq "") {
        return({output => $opts, rc => 2});
    }

    if(scalar @{$opts} == 0) {
        return(Thruk::Utils::CLI::get_submodule_help(__PACKAGE__));
    }

    my $result = _fetch_results($c, $opts, $opt);
    # return here for simple requests
    if(scalar @{$result} == 1
        && !$result->[0]->{'output'}
        && !$result->[0]->{'template'}
        && (!$result->[0]->{'warning'}  || scalar @{$result->[0]->{'warning'}}  == 0 )
        && (!$result->[0]->{'critical'} || scalar @{$result->[0]->{'critical'}} == 0 )
        && (!$result->[0]->{'rename'}   || scalar @{$result->[0]->{'rename'}}   == 0 )
    ) {
        return({output => $result->[0]->{'result'}, rc => $result->[0]->{'rc'}, content_type => $result->[0]->{'content_type'}, all_stdout => 1});
    }

    my($output, $rc) = _create_output($c, $opts, $result);
    return({output => $output, rc => $rc, all_stdout => 1 });
}

##############################################
sub _fetch_results {
    my($c, $opts, $global_opts) = @_;

    for my $opt (@{$opts}) {
        my $url = $opt->{'url'};

        # replace variables in the url, ex.: from previous queries
        unshift(@{$opts}, {}); # add empty totals up front to not mix up order
        $url =~ s/\{([^\}]+)\}/&_replace_output($1, $opts, {}, 1)/gemx;
        shift @{$opts};

        # Support local files and remote urls as well.
        # But for security reasons only from the command line
        if($ENV{'THRUK_CLI_SRC'} && $ENV{'THRUK_CLI_SRC'}) {
            # json arguments
            if($url =~ m/^\s*\[.*\]\s*$/mx || $url =~ m/^\s*\{.*\}\s*$/mx) {
                $opt->{'result'} = $url;
                $opt->{'rc'}     = 0;
                _debug("json data from command line argument:");
                _debug($opt->{'result'});
                next;
            }
            elsif($url =~ m/^https?:/mx) {
                my($code, $result, $res) = Thruk::Utils::CLI::request_url($c, $url, undef, $opt->{'method'}, $opt->{'postdata'}, $opt->{'headers'}, $global_opts->{'insecure'});
                if(Thruk::Base->verbose >= 2) {
                    _debug2("request:");
                    _debug2($res->request->as_string());
                    _debug2("response:");
                    _debug2($res->as_string());
                }
                $opt->{'result'} = $result->{'result'};
                $opt->{'rc'}     = $code == 200 ? 0 : 3;
                if(!$opt->{'result'} && $opt->{'rc'} != 0) {
                    $opt->{'result'} = Cpanel::JSON::XS->new->pretty->encode({
                        'message'  => $res->message(),
                        'code'     => $res->code(),
                        'request'  => $res->request->as_string(),
                        'response' => $res->as_string(),
                        'failed'   => Cpanel::JSON::XS::true,
                    })."\n";
                }
                next;
            } elsif(-r $url && -f $url) {
                _debug("loading local file: ".$url);
                $opt->{'result'} = Thruk::Utils::IO::read($url);
                $opt->{'rc'}     = 0;
                _debug("json data from local file ".$url.":");
                _debug($opt->{'result'});
                next;
            }

            # plus symbols from the command line are probably meant as plus
            # if a space is meant, simply use a space or %20
            $url =~ s/\+/%2B/gmx;
        }

        $url =~ s|^/||gmx;

        if($opt->{'format'}) {
            $url = $opt->{'format'}.'/'.$url;
        }

        $c->stats->profile(begin => "_cmd_rest($url)");
        my $sub_c = $c->sub_request('/r/v1/'.$url, uc($opt->{'method'}), $opt->{'postdata'}, 1);
        $c->stats->profile(end => "_cmd_rest($url)");

        $opt->{'content_type'} = $sub_c->res->content_type;
        $opt->{'result'}       = $sub_c->res->body;
        $opt->{'rc'}           = ($sub_c->res->code == 200 ? 0 : 3);
        if(!$opt->{'json'}) {
            eval {
                my $json = decode_json($opt->{'result'});
                $opt->{'json'} = $json;
            };
        }
        _debug2("json data:");
        _debug2($opt->{'result'});
    }
    return($opts);
}

##############################################
sub _parse_args {
    my($args, $src) = @_;

    # split by url
    my $current_args = [];
    my $split_args = [];
    while(@{$args}) {
        my $a = shift @{$args};
        if($a =~ m/^\-\-/mx) {
            push @{$current_args}, $a;
        } elsif($a =~ m/^\-/mx) {
            push @{$current_args}, $a;
            push @{$current_args}, shift @{$args} if defined $args->[0];
        } else {
            push @{$current_args}, $a;
            push @{$split_args}, $current_args;
            undef $current_args;
        }
    }
    # trailing args are amended to the previous url
    if($current_args) {
        if(scalar @{$split_args} > 0) {
            push @{$split_args->[scalar @{$split_args}-1]}, @{$current_args};
        }
    }

    # then parse each options
    my @commands = ();
    Getopt::Long::Configure('no_ignore_case');
    Getopt::Long::Configure('bundling');
    Getopt::Long::Configure('pass_through');
    for my $s (@{$split_args}) {
        my $opt = {
            'method'     => undef,
            'postdata'   => {},
            'warning'    => [],
            'critical'   => [],
            'perfunit'   => [],
            'rename'     => [],
            'headers'    => [],
            'perffilter' => [],
            'format'     => '',
            'template'   => '',
        };
        Getopt::Long::GetOptionsFromArray($s,
            "H|header=s"      =>  $opt->{'headers'},
            "m|method=s"      => \$opt->{'method'},
            "d|data=s"        =>  sub { _set_postdata($opt, 0, $src, @_); },
            "D|rawdata=s"     =>  sub { _set_postdata($opt, 1, $src, @_); },
            "o|output=s"      => \$opt->{'output'},
              "template=s"    => \$opt->{'template'},
            "w|warning=s"     =>  $opt->{'warning'},
            "c|critical=s"    =>  $opt->{'critical'},
              "perfunit=s"    =>  $opt->{'perfunit'},
              "perffilter=s"  =>  $opt->{'perffilter'},
              "rename=s"      =>  $opt->{'rename'},
              "csv"           =>  sub { $opt->{'format'} = 'csv' },
              "xls"           =>  sub { $opt->{'format'} = 'xls' },
              "human"         =>  sub { $opt->{'format'} = 'human' },
            "t|text"          =>  sub { $opt->{'format'} = 'human' },
        );

        # last option of parameter set is the url
        if(scalar @{$s} >= 1) {
            $opt->{'url'} = pop(@{$s});
        }

        $opt->{'method'} = 'GET' unless $opt->{'method'};

        push @commands, $opt;
    }

    return(\@commands);
}

##############################################
sub _set_postdata {
    my($opts, $overwrite, $src, undef, $data) = @_;
    my $postdata = $opts->{'postdata'};
    if(!$opts->{'method'}) {
        $opts->{'method'} = 'POST';
    }

    if($src && $src eq 'local' && $data && $data =~ m/^\@(.*)$/mx) {
        my $file = $1;
        if(!-e $file) {
            _fatal("could not read file %s: %s", $file, $!);
        }
        open(my $fh, '<', $file) || _fatal("could not read file %s: %s", $file, $!);
        $data = Thruk::Utils::IO::json_retrieve($file, $fh);
        if(ref $data ne 'HASH') {
            _fatal("could not read file %s, file must contain hash data structure, got: %s", $file, ref $data);
        }
        for my $key (sort keys %{$data}) {
            $postdata->{$key} = $data->{$key};
        }

        return;
    }

    if(ref $data eq '' && $data =~ m/^\{.*\}$/mx) {
        my $json = Cpanel::JSON::XS->new->utf8;
        $json->relaxed();
        eval {
            $data = $json->decode($data);
        };
        if($@) {
            _fatal("failed to parse json data argument: %s", $@);
        }
        for my $key (sort keys %{$data}) {
            $postdata->{$key} = $data->{$key};
        }

        return;
    }

    my($key,$val) = split(/=/mx, $data, 2);
    if($src && $src eq 'local' && defined $val) {
        $val =~ s/^\+/%2B/gmx;
        $val =~ s/\+/ /gmx;
        $val = Thruk::Request->unescape($val);
    }
    return unless $key;
    if(defined $postdata->{$key} && !$overwrite) {
        $postdata->{$key} = [$postdata->{$key}] unless ref $postdata->{$key} eq 'ARRAY';
        push @{$postdata->{$key}}, $val;
    } else {
        $postdata->{$key} = $val;
    }
    return;
}

##############################################
sub _apply_threshold {
    my($threshold_name, $data, $totals) = @_;
    return unless scalar @{$data->{$threshold_name}} > 0;
    $data->{'json'} = decode_json($data->{'result'}) unless $data->{'json'};

    for my $t (@{$data->{$threshold_name}}) {
        my($attr, $threshold);
        # {key1.key2...}threshold
        # {key1::key2...}threshold
        if($t =~ m/^\s*\{([^\}]*)\}\s*(.*)\s*$/mx) {
            $attr      = $1;
            $threshold = $2;
        }
        # key1.key2...:threshold
        # key:threshold
        elsif($t =~ m/^\s*([^:]*?):\s*(.*)\s*$/mx) {
            $attr      = $1;
            $threshold = $2;
        } else {
            _set_rc($data, 3, "unknown threshold format, syntax is --$threshold_name={key}threshold, got: ".$t."\n");
            return;
        }
        $attr =~ s/\./::/gmx;

        my($value, $ok) = _get_value($data->{'json'}, $attr);
        if(!$ok) {
            _set_rc($data, 3, "unknown variable $attr in thresholds, syntax is --$threshold_name=key:value\n");
            return;
        }
        _debug("checking threshold %s - src: %s | threshold: %s | current value: %s", $threshold_name, $attr, $threshold, $value);
        $value = 0 unless defined $value;
        if($threshold !~ m/^[\-\d\.]+$/mx) {
            eval {
                require Monitoring::Plugin::Range;
            };
            if($@) {
                die("Monitoring::Plugin module is required when using threshold ranges");
            }
            my $r = Monitoring::Plugin::Range->parse_range_string($threshold);
            if($r->check_range($value)) {
                if($threshold_name eq 'warning')  { _set_rc($data, 1); }
                if($threshold_name eq 'critical') { _set_rc($data, 2); }
            }
            # save range object
            $totals->{'range'}->{$attr}->{$threshold_name} = $r;
            next;
        }
        # single value check
        if($value < 0 || $value > $threshold) {
            if($threshold_name eq 'warning')  { _set_rc($data, 1); }
            if($threshold_name eq 'critical') { _set_rc($data, 2); }
        }
        $totals->{$threshold_name}->{$attr} = $threshold;
    }
    return;
}

##############################################
sub _set_rc {
    my($data, $rc, $msg) = @_;
    if(!defined $data->{'rc'} || $data->{'rc'} < $rc) {
        $data->{'rc'} = $rc;
    }
    if($msg) {
        $data->{'output'} = $msg;
    }
    return;
}

##############################################
sub _create_output {
    my($c, $opt, $result) = @_;
    my($output, $rc) = ("", 0);

    # if there are output formats, use them
    my $totals = {};
    for my $r (@{$result}) {
        # directly return fetch errors
        return($r->{'result'}, $r->{'rc'}) if $r->{'rc'} > 0;

        if($r->{rename} && scalar @{$r->{rename}} > 0) {
            $r->{'json'} = decode_json($r->{'result'}) unless $r->{'json'};
            for my $d (@{$r->{rename}}) {
                my($old,$new) = split(/:/mx,$d, 2);
                $r->{'json'}->{$new} = delete $r->{'json'}->{$old};
            }
        }

        # output template supplied?
        if($r->{'output'}) {
            if($totals->{'output'}) {
                return("multiple -o/--output parameter are not supported.", 3);
            }
            $totals->{'output'} = $r->{'output'};
        }
        if($r->{'template'}) {
            if($totals->{'template'}) {
                return("multiple --template parameter are not supported.", 3);
            }
            $totals->{'template'} = $r->{'template'};
        }

        # apply thresholds
        _apply_threshold('warning', $r, $totals);
        _apply_threshold('critical', $r, $totals);

        $rc = $r->{'rc'} if $r->{'rc'} > $rc;
        return($r->{'output'}, 3) if $r->{'rc'} == 3;
    }
    if($totals->{'template'} && $totals->{'output'}) {
        return("do not mix -o/--output with --template. Use only one of them.", 3);
    }

    # if there is no format, simply concatenate the output
    if(!$totals->{'output'} && !$totals->{'template'}) {
        for my $r (@{$result}) {
            $output .= $r->{'result'};
        }
        return($output, $rc);
    }

    $totals = _calculate_data_totals($result, $totals);
    unshift(@{$result}, $totals);
    my $macros = {
        STATUS => Thruk::Utils::Filter::state2text($rc) // 'UNKNOWN',
    };

    $macros->{RAW} = $result->[0]->{'json'} // $result->[0]->{'result'} // '';
    my $x = 0;
    for my $r (@{$result}) {
        $macros->{'RAW'.$x} = $r->{'json'} // $r->{'result'} // '';
        $x++;
    }
    $macros->{RC}       = $rc;
    $macros->{PERFDATA} = _append_performance_data($opt, $result);

    _debug("output macros:");
    _debug($macros);

    if($totals && $totals->{'template'}) {
        my $tpl;
        # base64 encoded template?
        if($totals->{'template'} =~ m/^data:(.*)$/mx) {
            require MIME::Base64;
            my $b64 = MIME::Base64::decode_base64($1);
            $tpl = \$b64;
        }
        elsif(!-e $totals->{'template'}) {
            return($totals->{'template'}.": ".$!, 3);
        }
        $tpl = Cwd::abs_path($totals->{'template'}) unless $tpl;
        $macros->{"macros"} = $macros;
        _debug("using template: %s", ref $tpl ? "<base64 inline>\n".${$tpl} : $tpl);
        my $settings = Thruk::Config::get_toolkit_config();
        $settings->{'RELATIVE'}    = 1;
        $settings->{'ABSOLUTE'}    = 1;
        $settings->{'PRE_CHOMP'}   = 1;
        $settings->{'POST_CHOMP'}  = 1;
        $settings->{'TRIM'}        = 1;
        my $tt = Template->new($settings);
        $tt->process($tpl, $macros, \$output) || die("failed to process template ".$tpl.": ".$tt->error());
        delete $macros->{"macros"};

        # extract exit code from template
        if($output =~ s/^\{\s*exitcode:(\w+)\s*\}//mxi) {
            $rc = $1;
        }
        if($output =~ m/^(OK|WARNING|CRITICAL|UNKNOWN)\s+/smxi) {
            $rc = $1;
        }
        my $nr = Thruk::Utils::Filter::text2state($rc);
        if(defined $nr) {
            $rc = $nr;
        }
        chomp($output);
    } else {
        $output = $totals->{'output'};
        $output =~ s/\{([^\}]+)\}/&_replace_output($1, $result, $macros)/gemx;
        $output =~ s/\\n/\n/gmx; # support adding newlines

        chomp($output);
        $output .= $macros->{PERFDATA} if $macros->{PERFDATA} ne '|';
    }
    $output .= "\n";
    return($output, $rc);
}

##############################################
sub _append_performance_data {
    my($opt, $result) = @_;
    my @perf_data;
    my $totals = $result->[0];
    if(ref $totals->{'json'} eq 'HASH') {
        for my $key (sort keys %{$totals->{'json'}}) {
            my $perfdata = _append_performance_data_string($key, $totals->{'json'}->{$key}, $totals);
            push @perf_data, @{$perfdata} if $perfdata;
        }
    }
    return("|".join(" ", @perf_data));
}

##############################################
sub _append_performance_data_string {
    my($key, $data, $totals) = @_;
    return unless _perffilter($totals->{'perffilter'}, $key);
    if(ref $data eq 'HASH') {
        my @res;
        for my $k (sort keys %{$data}) {
            my $r = _append_performance_data_string($key."::".$k, $data->{$k}, $totals);
            push @res, @{$r} if $r;
        }
        return \@res;
    }
    if(ref $data eq 'ARRAY') {
        my @res;
        my $index = 0;
        for my $v (@{$data}) {
            my $r = _append_performance_data_string($key."::".$index, $v, $totals);
            push @res, @{$r} if $r;
            $index++;
        }
        return \@res;
    }
    if(defined $data && !Thruk::Backend::Manager::looks_like_number($data)) {
        return;
    }
    my($min,$max,$warn,$crit) = ("", "", "", "");
    if($totals->{'range'}->{$key}->{'warning'}) {
        $warn = $totals->{'range'}->{$key}->{'warning'};
    } elsif($totals->{'warning'}->{$key}) {
        $warn = $totals->{'warning'}->{$key};
    }
    if($totals->{'range'}->{$key}->{'critical'}) {
        $crit = $totals->{'range'}->{$key}->{'critical'};
    } elsif($totals->{'critical'}->{$key}) {
        $crit = $totals->{'critical'}->{$key};
    }
    my $unit = "";
    for my $p (sort keys %{$totals->{perfunits}}) {
        if($p eq $key) {
            $unit = $totals->{perfunits}->{$p};
            last;
        }
        ## no critic
        if($key =~ m/^$p$/) {
        ## use critic
            $unit = $totals->{perfunits}->{$p};
            last;
        }
    }
    return([sprintf("'%s'=%s%s;%s;%s;%s;%s",
            $key,
            $data // 'U',
            $unit,
            $warn,
            $crit,
            $min,
            $max,
    )]);
}

##############################################
# return true if $key passes given filter or filter list is empty
sub _perffilter {
    my($perffilter, $key) = @_;
    return 1 if !$perffilter;
    return 1 if scalar @{$perffilter} == 0;
    for my $f (@{$perffilter}) {
        my $regex = qr/$f/mx;
        return 1 if $key =~ m/$regex/mx;
    }
    return(0);
}

##############################################
sub _calculate_data_totals {
    my($result, $totals) = @_;
    $totals->{json} = {};
    my $perfunits   = [];
    my $perffilter  = [];
    for my $r (@{$result}) {
        $r->{'json'} = decode_json($r->{'result'}) unless $r->{'json'};
        next unless ref $r->{'json'} eq 'HASH';
        for my $key (sort keys %{$r->{'json'}}) {
            if(!defined $totals->{'json'}->{$key}) {
                $totals->{'json'}->{$key} = $r->{'json'}->{$key};
            } else {
                $totals->{'json'}->{$key} += $r->{'json'}->{$key};
            }
        }
        push @{$perfunits}, @{$r->{'perfunit'}}    if $r->{'perfunit'};
        push @{$perffilter}, @{$r->{'perffilter'}} if $r->{'perffilter'};
    }
    if(scalar @{$result} == 1) {
        $totals->{'json'} = $result->[0]->{'json'};
    }
    $totals->{perfunits} = {};
    for my $p (@{$perfunits}) {
        my($label, $unit) = split(/:/mx, $p, 2);
        $totals->{perfunits}->{$label} = $unit;
    }
    $totals->{perffilter} = $perffilter;
    return($totals);
}

##############################################
sub _replace_output {
    my($var, $result, $macros, $keep_if_missing) = @_;
    my($format, $strftime);
    if($var =~ m/^(.*)%strftime:(.*)$/gmx) {
        $strftime = $2; # overwriting $var first breaks on <= perl 5.16
        $var      = $1;
    }
    elsif($var =~ m/^(.*)(%[^%]+?)$/gmx) {
        $format = $2; # overwriting $var first breaks on <= perl 5.16
        $var    = $1;
    }

    my @vars = split(/([\s\-\+\/\*\(\)]+)/mx, $var);
    my @processed;
    my $error;
    for my $v (@vars) {
        $v =~ s/^\s*//gmx;
        $v =~ s/\s*$//gmx;
        if($v =~ m/[\s\-\+\/\*\(\)]+/mx) {
            push @processed, $v;
            next;
        }
        my $nr = 0;
        if($v =~ m/^(\d+):(.*)$/mx) {
            $nr = $1;
            $v  = $2;
        }
        my $val;
        if($nr == 0 && $v =~ m/^\d\.?\d*$/mx && !defined $result->[$nr]->{'json'}->{$v}) {
            $val = $v;
        } else {
            my($ok);
            ($val, $ok) = _get_value($result->[$nr]->{'json'}, $v);
            if(!$ok && defined $macros->{$v}) {
                $val = $macros->{$v};
                $ok = 1;
            }
            if(!$ok) {
                return('{'.$var.'}') if $keep_if_missing;
                $error = "error:$v does not exist";
            }
        }
        if(ref $val) {
            $val = Cpanel::JSON::XS->new->canonical->encode($val);
        }
        push @processed, $val;
    }
    my $value = "";
    if($error) {
        $value    = '{'.$error.'}';
        $format   = "";
        $strftime = "";
    }
    elsif(scalar @processed == 1) {
        $value = $processed[0] // '(null)';
    } else {
        for my $d (@processed) {
            $d = 0 unless defined $d;
        }
        ## no critic
        $value = eval(join("", @processed)) // '(error)';
        ## use critic
    }

    if($format) {
        return(sprintf($format, $value));
    }
    if($strftime) {
        return(POSIX::strftime($strftime, localtime($value)));
    }
    return($value);
}

##############################################
# return $val, $ok. $ok is true if a value was found
sub _get_value {
    my($data, $key) = @_;
    if(ref $data eq 'HASH' && exists $data->{$key}) {
        return(_get_value_ref_check($data->{$key}), 1);
    }
    if(ref $data eq 'ARRAY' && $key =~ m/^\d+$/mx && exists $data->[$key]) {
        return(_get_value_ref_check($data->[$key]), 1);
    }
    # traverse into nested hashes and lists
    my @parts = split(/\.|::/mx, $key);
    if(scalar @parts <= 1) {
        return(undef, 0);
    }

    my $val = $data;
    for my $k (@parts) {
        if(ref $val eq 'HASH' && exists $val->{$k}) {
            $val = $val->{$k};
        }
        elsif(ref $val eq 'ARRAY' && $k =~ m/^\d+$/mx && exists $val->[$k]) {
            $val = $val->[$k];
        } else{
            return(undef, 0);
        }
    }

    return(_get_value_ref_check($val), 1);
}

##############################################
sub _get_value_ref_check {
    my($val) = @_;
    if(ref $val) {
        return(Cpanel::JSON::XS->new->ascii->canonical->encode($val));
    }
    return($val);
}

##############################################
# determines if command requires backends or not
sub _skip_backends {
    my($c, $opts, $src) = @_;
    Thruk::Action::AddDefaults::add_defaults($c, Thruk::Constants::ADD_SAFE_DEFAULTS) unless $c->stash->{'processinfo_time'};
    return unless $opts->{'commandoptions'};
    my $cmds = _parse_args($opts->{'commandoptions'}, $src);
    $opts->{'_parsed_args'} = $cmds;
    for my $cmd (@{$cmds}) {
        if(!$cmd->{'url'} || $cmd->{'url'} !~ m/^https?:\/\//mx) {
            return;
        }
    }
    return(1);
}

##############################################

=head1 EXAMPLES

Get list of hosts sorted by name

  %> thruk r /hosts?sort=name

Get list of hostgroups starting with literal l

  %> thruk r '/hostgroups?name[~]=^l'

Reschedule next host check for host localhost:

  %> thruk r -d "start_time=now" /hosts/localhost/cmd/schedule_host_check

Read POST data from file

  %> thruk r -d @/tmp/postdata.json /hosts/localhost/cmd/schedule_host_check

Read POST data from file but overwrite specific key with new value

  %> thruk r -d @/tmp/postdata.json -D comment=... /hosts/localhost/cmd/schedule_host_check

Send multiple endpoints at once:

  %> thruk r "/hosts/totals" "/services/totals"

See more examples and additional help at https://thruk.org/documentation/rest.html

=cut

##############################################

1;
