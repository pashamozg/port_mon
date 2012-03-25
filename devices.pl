#!/usr/bin/perl

use strict;
use lib "/usr/lib/perl/5.10";
use Net::SNMP qw(:snmp);
use Net::IP;
use Storable;
use Data::Dumper;
my $d_store_path = 'dev_store';
my @ip_ranges = ('192.168.0.0/16', 
); 

my $community = 'public';
my %oids_per_s = (
# 64bit counter
        'bytes_in_64' => '1.3.6.1.2.1.31.1.1.1.6',
        'bytes_out_64' => '1.3.6.1.2.1.31.1.1.1.10',
# 32bit counter
        'bytes_in_32' => '1.3.6.1.2.1.2.2.1.10' , 
        'bytes_out_32' => '1.3.6.1.2.1.2.2.1.16',
        );
my %oids_sum = (
        'ifspeed' => '1.3.6.1.2.1.2.2.1.5',
        'descr' => '1.3.6.1.2.1.2.2.1.2',
        'error_in' => '1.3.6.1.2.1.2.2.1.14',
        'error_out' => '1.3.6.1.2.1.2.2.1.20',
        );
my %oids_per_s_inv = map {$oids_per_s{$_} => $_} keys %oids_per_s;
my %oids_sum_inv = map {$oids_sum{$_} => $_} keys %oids_sum;
my $devices;
if(-f $d_store_path){
    $devices =  retrieve($d_store_path);
}
sub get_callback{
    my ($session, $shared, $base_oid) = @_;
    my $list = $session->var_bind_list();
    if (!defined $list) {
#        printf "ERROR: Get request failed for host '%s': %s.\n",
#             $session->hostname(), $session->error();
        return -1;
    }
    my @names = $session->var_bind_names();
    my $next = undef;
#    print "get callback from ", $session->hostname(),"\n";
    while(@names){
        $next = shift @names;
        if (!oid_base_match($base_oid->[0], $next)) {
            return; # Table is done.
        }
        my ($port) = ($next =~ /\.(\d+)$/);
        if(exists $oids_per_s_inv{$base_oid->[0]}){
	my $t = time;
            $shared->{$session->hostname()}->{'int'}->{$port}->{$oids_per_s_inv{$base_oid->[0]}}->{$t} = $list->{$next};
#    	    print $shared->{$port}->{$oids_per_s_inv{$base_oid->[0]}}->{$t}, "\n";
        }
        if(exists $oids_sum_inv{$base_oid->[0]}){
            $shared->{$session->hostname()}->{'int'}->{$port}->{$oids_sum_inv{$base_oid->[0]}} = $list->{$next};
#            $shared->{$port}->{$oids_sum_inv{$base_oid->[0]}} = $list->{$next};
        }
    }
    my $result = $session->get_next_request(
            -varbindlist    => [ $next ],
            );
    return;
}
sub snmp_req {
    my ($ip , $oids , $shared) = @_;
    my ($session, $error) = Net::SNMP->session(
            -hostname     =>  $ip,
            -community    =>  $community,
            -version      => 'snmpv2c',
            -nonblocking  =>  1,
            -timeout  => 2,
            -retries  => 2,
            );  

    if (!defined $session) {
        printf "ERROR -$ip-  exit: %s.\n", $error;
        return -1;
    }   

    my $result = $session->get_next_request(
            -varbindlist => $oids,
            -callback    => [ \&get_callback , $shared, $oids],
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
        my $host_count;
        do{
            snmp_req( $ip->ip(), [$oids_sum{descr}], $devices);
            ++$host_count;
            if($host_count==200){
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
    my $host_count = 0;
    foreach my $ip (keys %$devices){
        ++$host_count;
        foreach(values %oids_sum){
            snmp_req($ip, [$_], $devices);
        }
        foreach(values %oids_per_s){
            snmp_req($ip, [$_], $devices);
        }
        if($host_count==200){
            snmp_dispatcher();
        }
    }
    snmp_dispatcher();
# tranform data to use in rrdtool
# calculate speed on interface
# set description 
# set errors
    foreach my $ip (keys %$devices){
        my @all_int = keys %{$devices->{$ip}->{'int'}};
        if($#all_int == -1 ){
            delete $devices->{$ip};
            next;
        }
        foreach my $p (@all_int){
            foreach my $type (keys %{$devices->{$ip}->{'int'}->{$p}}){
                if(exists $oids_per_s{$type}){
                    my @t = sort keys %{$devices->{$ip}->{'int'}->{$p}->{$type}};
                    next unless($#t>0);
                    $devices->{$ip}->{stat}->{$p}->{$type}->{$t[$#t]} = 
                        $devices->{$ip}->{'int'}->{$p}->{$type}->{$t[$#t]} - $devices->{$ip}->{'int'}->{$p}->{$type}->{$t[$#t-1]};
                    my $val =  int( $devices->{$ip}->{stat}->{$p}->{$type}->{$t[$#t]}/ ($t[$#t] - $t[$#t-1])) ;
                    if( $devices->{$ip}->{'int'}->{$p}->{ifspeed} > 0 && $val*8 > $devices->{$ip}->{'int'}->{$p}->{ifspeed}){
                        $val = ( $devices->{$ip}->{'int'}->{$p}->{ifspeed})/8;
                    }elsif($val < 0){
                        $val = 0;
                    }
                    $devices->{$ip}->{stat}->{$p}->{$type}->{$t[$#t]}  = $val*8;
                    foreach(0 .. ($#t-2)){ 
                        delete $devices->{$ip}->{'int'}->{$p}->{$type}->{$t[$_]};
                    }
                }elsif(exists $oids_sum{$type}){
                    if($type =~ /error/){
                        $devices->{$ip}->{stat}->{$p}->{$type}->{time()} = $devices->{$ip}->{'int'}->{$p}->{$type} + 0 ;
                    }else{
                        $devices->{$ip}->{stat}->{$p}->{$type} = $devices->{$ip}->{'int'}->{$p}->{$type} ;
                    }
                }
            }
        }
    }
    return $devices;
}

$devices = search_new_devices($devices);
$devices = polling_devices($devices);
# print Dumper($devices);
store $devices , $d_store_path;
