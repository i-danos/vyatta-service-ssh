#!/usr/bin/perl
# **** License ****
#
# Copyright (c) 2018-2021, AT&T Intellectual Property.
# All rights reserved.
#
# Copyright (c) 2017 by Brocade Communications Systems, Inc.
# All rights reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2007-2015 Vyatta, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#
# **** End License ****
#
use strict;
use warnings;
use lib '/opt/vyatta/share/perl5';
use File::Basename;
use File::Slurp qw(write_file);
use Vyatta::Config;
use Vyatta::VrfManager qw(get_interface_vrf $VRFNAME_DEFAULT);
use Template;
use Getopt::Long;
use Sys::Syslog qw(:standard :macros);

my $config = new Vyatta::Config;

# OpenSSH limitation
my $MAX_LISTEN_SOCKS = 16;

# Initalize defaults
my $vars = {
    Script              => $0,
    Port                => ["22"],
    Subsystem           => [],
    ClientAliveInterval => 0,
    ClientAliveCountMax => 3,
};

my $keygen       = 1;
my $update       = 0;
my $update_file  = '/etc/ssh/sshd_config';
my $priv_sep_dir = '/run/sshd';
my $run_dir      = '/run/ssh';

sub setup_options {
    my ( $opts, $config, $cli_path ) = @_;
    $opts->{PermitRootLogin} =
      $config->exists("${cli_path}service ssh allow-root") ? "yes" : "no";
    $opts->{UseDNS} =
      $config->exists("${cli_path}service ssh disable-host-validation")
      ? "no"
      : "yes";
    $opts->{PasswordAuthentication} =
      $config->exists("${cli_path}service ssh disable-password-authentication")
      ? "no"
      : "yes";
    $opts->{AllowTcpForwarding} =
      $config->exists("${cli_path}service ssh disable-tcp-forwarding")
      ? "no"
      : "yes";
    return;
}

sub setup_ports_and_listen_addrs {
    my ( $opts, $config, $cli_path ) = @_;
    my @ports     = $config->returnValues("${cli_path}service ssh port");
    my $num_ports = @ports;
    my @addrs = $config->returnValues("${cli_path}service ssh listen-address");
    my $num_addrs = @addrs;

    if ($num_ports) {

        # With no listen addrs, there is 1 IPv4 & 1 IPv6 socket for each port
        my $max_ports =
          $num_addrs ? $MAX_LISTEN_SOCKS : int( $MAX_LISTEN_SOCKS / 2 );

        if ( $num_ports <= $max_ports ) {
            $opts->{Port} = [@ports];
        } else {
            $opts->{Port} = [ @ports[ 0 .. $max_ports - 1 ] ];
            my $str = "SSH: More than $max_ports ports configured, discarding: "
              . "@ports[ $max_ports .. $num_ports - 1 ]";
            print "Warning: " . $str . "\n";
            syslog( 'warning', $str );
            $num_ports = $max_ports;
        }
    } else {

        # default port 22
        $num_ports = 1;
    }

    if ($num_addrs) {
        my $max_addrs = int( $MAX_LISTEN_SOCKS / $num_ports );

        if ( $num_addrs <= $max_addrs ) {
            $opts->{ListenAddress} = [@addrs];
        } else {
            $opts->{ListenAddress} = [ @addrs[ 0 .. $max_addrs - 1 ] ];
            my $str =
                "SSH: More than $max_addrs listen addresses configured, "
              . "discarding: @addrs[ $max_addrs .. $num_addrs - 1 ]";
            print "Warning: " . $str . "\n";
            syslog( 'warning', $str );
        }
    }

    return;
}

# SSH does not support free (non-local) bind. It can bind to a local IPv4
# address if it exists, even if the interface is down. It cannot do so for IPv6
# addresses if they exist, as these are in tentative state when intf is down.
# Once intf is up, need to wait for DAD so that address goes from tentative
# state to assigned. So check for presence of addresses that are not tentative.
sub check_listen_addrs {
    my ( $opts, $file, $vrf ) = @_;
    my $listen_addrs = $opts->{ListenAddress};

    if ( !( $listen_addrs && @$listen_addrs ) ) {
        if ( -e $file ) {
            unlink($file) or die "Unable to delete '$file': $!\n";
        }
        return;
    }

    # Output format: <index>: <intf[.vif]> <inet[6]> <address/prefix> ...
    my $cmd = "ip -o addr show scope global -tentative";
    my ( %addrs, @cols, $intf, $line, %pending_addrs );
    my $vrf_name = $vrf // $VRFNAME_DEFAULT;

    open my $ipcmd, '-|'
      or exec $cmd
      or die "ip addr command failed: $!";
    while ( $line = <$ipcmd> ) {
        @cols = split( /[\s\/]+/, $line, 5 );
        $addrs{ $cols[3] } = $cols[1];
    }
    close $ipcmd;

    %pending_addrs = map { $_ => 1 } @$listen_addrs;
    foreach my $addr ( keys %pending_addrs ) {
        $intf = $addrs{$addr};
        if ( $intf && $vrf_name eq get_interface_vrf($intf) ) {
            delete $pending_addrs{$addr};
        }
    }

    if (%pending_addrs) {
        write_file( $file, { atomic => 1 }, join( " ", keys %pending_addrs ) )
          or die "Could not write to file '$file': $!\n";
    } elsif ( -e $file ) {
        unlink($file) or die "Unable to delete '$file': $!\n";
    }

    return;
}

sub setup_netconf {
    my ( $opts, $config, $cli_path ) = @_;
    if ( defined( $config->exists("${cli_path}service netconf") )
        && !defined( $config->exists("${cli_path}service netconf disable") ) )
    {
        $opts->{Subsystem} =
          [ @{ $opts->{Subsystem} }, "netconf /opt/vyatta/bin/netconfd" ];
    }
    return;
}

sub setup_timeout {
    my ( $opts, $config, $cli_path ) = @_;
    my $timeout = $config->returnValue("${cli_path}service ssh timeout");

    if ( !defined($timeout) ) {
        return;
    }
    $opts->{LoginGraceTime} = $timeout;
    return;
}

sub setup_client_alive_interval {
    my ( $opts, $config ) = @_;
    my $timeout = $config->returnValue("service ssh client-alive-interval");

    return if !defined($timeout);

    $timeout = int($timeout);
    $opts->{ClientAliveInterval} = $timeout;
    return;
}

sub setup_client_alive_count_max {
    my ( $opts, $config ) = @_;
    my $attempts = $config->returnValue("service ssh client-alive-attempts");

    return if !defined($attempts);

    $attempts = int($attempts);
    $opts->{ClientAliveCountMax} = $attempts;
    return;
}

sub setup_max_auth_retries {
    my ( $opts, $config, $cli_path ) = @_;
    my $max_auth_retries =
      $config->returnValue("${cli_path}service ssh authentication-retries");

    if ( !defined($max_auth_retries) ) {
        return;
    }
    $opts->{MaxAuthTries} = $max_auth_retries;
    return;
}

sub setup_ciphers {
    my ( $opts, $config, $cli_path ) = @_;
    my $ciphers =
      `/usr/sbin/sshd -T -f /dev/null | awk '/^ciphers /{print \$2; exit}'`;
    chomp $ciphers;
    my @cfg_ciphers =
      $config->returnValues("${cli_path}service ssh permit cipher");
    if ( scalar @cfg_ciphers > 0 ) {
        $ciphers = $ciphers . ',' . join( ',', @cfg_ciphers );
    }
    $opts->{Ciphers} = "$ciphers";
}

sub setup_kexalgorithms {
    my ( $opts, $config, $cli_path ) = @_;
    my $algs =
      `/usr/sbin/sshd -T -f /dev/null | awk '/^kexalgorithms /{print \$2; exit}'`;
    chomp $algs;
    my @splitalgs = split( ',', $algs );

    # Remove initial disallowed list
    my $dis1    = "diffie-hellman-group1-sha1";
    my $dis2    = "diffie-hellman-group14-sha1";
    my $dis3    = "diffie-hellman-group-exchange-sha1";
    my @new     = grep { !/($dis1|$dis2|$dis3)/ } @splitalgs;
    my $newalgs = join( ',', @new );

    # Readd any specifically permitted by config
    my @cfg_kexalgs = $config->returnValues(
        "${cli_path}service ssh permit key-exchange-algorithm");
    if ( scalar @cfg_kexalgs > 0 ) {
        $newalgs = $newalgs . ',' . join( ',', @cfg_kexalgs );
        syslog( 'warning',
            "SSH: Legacy Key Exchange Algorithms enabled: @cfg_kexalgs" );
    }

    $opts->{KexAlgorithms} = "$newalgs";
}

sub setup_server_key_bits {
    my ( $opts, $config, $cli_path ) = @_;
    my %key_lengths = (
        "80"  => [ "1024", "1024",  "256" ],
        "112" => [ "1024", "2048",  "256" ],
        "128" => [ "1024", "3072",  "256" ],
        "192" => [ "1024", "7680",  "384" ],
        "256" => [ "1024", "15360", "521" ],
    );
    my $key_strength =
      $config->returnValue("${cli_path}service ssh key-security-strength");

    if ( !defined($key_strength) ) {
        system("ssh-keygen -A &>/dev/null");
        return;
    }

    my ( $dsa_len, $rsa_len, $ecdsa_len ) =
      @{ $key_lengths{$key_strength} };

    system(
"ssh-keygen -q -N '' -t ecdsa -b $ecdsa_len -f /etc/ssh/ssh_host_ecdsa_key &>/dev/null"
    );

    my $fips = `cat /proc/cmdline | grep "fips=1"`;
    if ( $fips eq "" ) {
        system(
"ssh-keygen -q -N '' -t dsa -b $dsa_len -f /etc/ssh/ssh_host_dsa_key &>/dev/null"
        );
        system(
"ssh-keygen -q -N '' -t rsa -b $rsa_len -f /etc/ssh/ssh_host_rsa_key &>/dev/null"
        );
    }
    return;
}

# Allow or deny sshd running at reboot depending on it being configured or not.
# Not needed for VRFs, as sshd_config for these are removed when config deleted
sub setup_run_at_startup {
    my $config     = shift;
    my $norun_file = "/etc/ssh/sshd_not_to_be_run";

    if ( defined( $config->exists("service ssh") ) ) {
        unlink $norun_file;
    } else {
        open( my $fh, '>', $norun_file )
          or die "Could not open file '$norun_file' $!";
        close $fh;
    }
}

sub update_handler {
    my ( $opt_name, $opt_value ) = @_;
    $update = 1;
    if ( length $opt_value ) {
        $update_file = $opt_value;
    }
}

my ( $cli_path, $vrf );

GetOptions(
    "keygen!"    => \$keygen,
    "update:s"   => \&update_handler,
    'cli-path=s' => \$cli_path,
    'vrf=s'      => \$vrf
);

if ( !defined($cli_path) ) {
    $cli_path = "";
} else {
    $cli_path = $cli_path . " ";
}

my $update_dir = dirname($update_file);
$update_dir = $run_dir if ( $update_dir eq "/etc/ssh" );
my $listen_addr_file = $update_dir . "/listen_addresses";
die "File '$listen_addr_file' must be in $run_dir\n"
  unless $listen_addr_file =~ m"^/run/ssh" and $listen_addr_file !~ /\.\./;

mkdir $priv_sep_dir unless -d $priv_sep_dir;
mkdir $run_dir      unless -d $run_dir;

setup_ports_and_listen_addrs( $vars, $config, $cli_path );
setup_options( $vars, $config, $cli_path );
setup_netconf( $vars, $config, $cli_path );
setup_timeout( $vars, $config, $cli_path );
setup_client_alive_interval( $vars, $config );
setup_client_alive_count_max( $vars, $config );
setup_max_auth_retries( $vars, $config, $cli_path );
setup_ciphers( $vars, $config, $cli_path );
setup_kexalgorithms( $vars, $config, $cli_path );
setup_server_key_bits( $vars, $config, $cli_path ) if $keygen;
setup_run_at_startup($config) if $cli_path eq "";

my $tt = new Template( PRE_CHOMP => 1 );
if ($update) {
    $tt->process( \*DATA, $vars, $update_file );
} else {
    $tt->process( \*DATA, $vars );
}

# Check if any listen addresses not yet assigned after updating sshd_config
check_listen_addrs( $vars, $listen_addr_file, $vrf );

__END__
### /etc/ssh/sshd_config is autogenerated by [% Script %]
### Note: Manual changes to this file will be lost during
###       the next commit.
[% FOREACH p = Port %]
Port [% p %]
[% END %]
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_dsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
SyslogFacility AUTH
LogLevel INFO
LoginGraceTime [% LoginGraceTime %]
ClientAliveInterval [% ClientAliveInterval %]
ClientAliveCountMax [% ClientAliveCountMax %]
MaxAuthTries [% MaxAuthTries %]
PermitRootLogin [% PermitRootLogin %]
StrictModes yes
PubkeyAuthentication yes
IgnoreRhosts yes
HostbasedAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
PasswordAuthentication [% PasswordAuthentication %]
X11Forwarding yes
X11DisplayOffset 10
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
Ciphers [% Ciphers %]
KexAlgorithms [% KexAlgorithms %]
AllowTcpForwarding [% AllowTcpForwarding %]
Banner /etc/issue.ssh
Subsystem sftp /usr/lib/openssh/sftp-server
[% FOREACH s = Subsystem %]
Subsystem [% s %]
[% END %]
UsePAM yes
UseDNS [% UseDNS %]
[% FOREACH addr = ListenAddress %]
ListenAddress [% addr %]
[% END %]
