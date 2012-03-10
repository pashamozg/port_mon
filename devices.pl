#!/usr/bin/perl

use strict;

use Net::SNMP;
use Net::IP;
use Storable;
use Data::Dumper;
use Time::HiRes qw(tv_interval gettimeofday);
my $d_store_path = 'dev_store';
my @ip_ranges = ('192.168.2.0/24', '172.31.31.0/24');
my $community = 'read';
my @oids = (
        '1.3.6.1.2.1.31.1.1.1.6',
        '1.3.6.1.2.1.31.1.1.1.10',
        '1.3.6.1.2.1.2.2.1.14',
        '1.3.6.1.2.1.2.2.1.20',
        '1.3.6.1.2.1.2.2.1.5',
        '1.3.6.1.2.1.2.2.1.2',
);
my %oids_ps = (
    '1.3.6.1.2.1.31.1.1.1.6' => 1, 
    '1.3.6.1.2.1.31.1.1.1.10' => 1,
    );
my %aux_oids = (
    'ifspeed' => '1.3.6.1.2.1.2.2.1.5',
    'ifnum' => '1.3.6.1.2.1.2.1.0',
    'descr' => '1.3.6.1.2.1.2.2.1.2',
);
my $devices;
my %skip_ip;
if(-f $d_store_path){
    my $t0 = [gettimeofday];
    $devices =  retrieve($d_store_path);
    print "load time : ", tv_interval ( $t0, [gettimeofday]),"\n";

}

sub get_callback
{
    my ($session, $shared, $type, $oids) = @_;
    my $result = $session->var_bind_list();
    my $t = time;
    if (!defined $result) {
#        printf "ERROR: Get request failed for host '%s': %s.\n",
#              $session->hostname(), $session->error();
        return -1;
    }
    printf "callback from host '%s' .\n",
           $session->hostname();
    if($type == 1){
        my $t = time;
        foreach(keys %$result){
            if($_ =~ /^($aux_oids{descr}|$aux_oids{ifspeed}).\d{1,2}$/){
                $shared->{$_}= $result->{$_}||'';
            }else{
                $shared->{$_}->{$t} = $result->{$_};
            }
#        print "-$_-", $result->{$_},"-\n";
        }
    }else{
        if($result->{$aux_oids{ifnum}} > 0){
            $shared->{$session->hostname()}->{num} = $result->{$aux_oids{ifnum}};
        }
    }

    return;
}
sub snmp_req {
    my ($ip , $oids , $shared, $type) = @_;
    my ($session, $error) = Net::SNMP->session(
            -hostname     =>  $ip,
            -community    =>  $community,
            -version      => 'snmpv2c',
            -timeout      =>  2,
            -retries      =>  2,
            -nonblocking  =>  1,
            );  

    if (!defined $session) {
        printf "ERROR -$ip-  exit: %s.\n", $error;
        return -1;
    }   

    my $result = $session->get_request(
            -varbindlist => $oids,
            -callback    => [ \&get_callback , $shared, $type, $oids],
            );  

    if (!defined $result) {
        printf "ERROR: %s.\n", $session->error();
        $session->close();
        return -1;
    } 
}
sub search_new_devices {
    my ($devices) = @_;
    foreach (@ip_ranges){
        my $ip = new Net::IP ("$_") or die (Net::IP::Error());
        my %dp;
        my $host_count;
        do{
            snmp_req( $ip->ip(), [$aux_oids{ifnum}], $devices);
            ++$host_count;
            if($host_count==150){
                snmp_dispatcher();
                $host_count=0;
            }
        }while(++$ip);
        snmp_dispatcher();
    }
    return $devices;
}

sub polling_devices {
    my ($devices) = @_;
    foreach my $ip (keys %$devices){
        foreach my $int (1 .. $devices->{$ip}->{num}){
            my @r_oids = map {$_.".$int"} @oids;
            snmp_req($ip, \@r_oids, $devices->{$ip}->{int}, 1);
        }
        snmp_dispatcher();
    }
# tranform data to use in rrdtool
# calculate speed on interface
# set description 
# set errors
    foreach my $ip (keys %$devices){
        foreach my $p (keys %{$devices->{$ip}->{int}}){
            next if ($p =~ /^$aux_oids{ifspeed}/);
            $p =~ /^((\d{1,2}\.?)+)\.(\d+)$/;
            my ($oid , $int) = ($1, $3);
            if($oid eq "$aux_oids{descr}" && $devices->{$ip}->{int}->{$p} ne ''){
                $devices->{$ip}->{stat}->{$int}->{name} =  $devices->{$ip}->{int}->{$p};
            }else{
                my @t = sort keys %{$devices->{$ip}->{int}->{$p}};
                if($#t>0){
                    if($devices->{$ip}->{int}->{$p}->{$t[$#t]} =~ /noSuch/){
                        delete $devices->{$ip}->{int}->{$p}; 
                        delete $devices->{$ip}->{stat}->{$int}->{$oid};
                    }
                    if($oids_ps{$oid}){
                        $devices->{$ip}->{stat}->{$int}->{$oid}->{$t[$#t]} = 
                            $devices->{$ip}->{int}->{$p}->{$t[$#t]} - $devices->{$ip}->{int}->{$p}->{$t[$#t-1]};
                        my $val =  int( $devices->{$ip}->{stat}->{$int}->{$oid}->{$t[$#t]}/ ($t[$#t] - $t[$#t-1])) ;
                        if( $val*8 > $devices->{$ip}->{int}->{$aux_oids{ifspeed}.".$int"}){
                            $val = ($devices->{$ip}->{int}->{$aux_oids{ifspeed}.".$int"})/8;
                        }
                        $devices->{$ip}->{stat}->{$int}->{$oid}->{$t[$#t]}  = $val;
                        print $devices->{$ip}->{stat}->{$int}->{$oid}->{$t[$#t]} ,"\n";
                    }else{
                        $devices->{$ip}->{stat}->{$int}->{$oid}->{$t[$#t]} =
                            $devices->{$ip}->{int}->{$p}->{$t[$#t]};
                    }
                    foreach(0 .. ($#t-2)){ 
                        delete $devices->{$ip}->{int}->{$p}->{$t[$_]};
                    }
                }
            }
        }
    }
    return $devices;

}

$devices = search_new_devices($devices);
$devices = polling_devices($devices);
#print Dumper($devices);
store $devices , $d_store_path;
