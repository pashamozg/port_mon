#!/usr/bin/perl
use Storable;
use CGI qw/:standart/;
use File::Path;
use RRDTool::OO;
use Data::Dumper;

my @names = qw/bytes_in_32 bytes_in_64 bytes_out_32 bytes_out_64 error_in error_out/;
my $d_store_path = 'dev_store';
my $image_refresh_time = 60;
my $step = 300;
my $q = CGI->new();

my $dev = $q->param('device');
my $port = $q->param('port');

my $devices;

sub all_devices {
    print $q->h2("Known devices ");
    print "<table><tr><td>\n";
    foreach( sort keys %$devices){
        print "<a href=port_mon1.pl?device=$_> $_ </a>&nbsp&nbsp&nbsp ";
    }
    print "</td></tr></table>\n";
}
sub ports {
    print $q->h2("Ports on device $dev ");
    if(exists $devices->{$dev}){
        my $c=0;
        print "<table>";
        print "<tr><td>" ;
        foreach(sort {$devices->{$dev}->{stat}->{$a}->{descr} cmp $devices->{$dev}->{stat}->{$b}->{descr}} keys %{$devices->{$dev}->{stat}}){
            print "<a href=port_mon1.pl?device=$dev&port=$_>".$devices->{$dev}->{stat}->{$_}->{descr}."</a>&nbsp&nbsp&nbsp ";
#            if(++$c%15==0){print "<br>";}
        }
        print "</td>\n";
        print "</table>";
    }
}
if(-e $d_store_path){
    $devices =  retrieve($d_store_path);
}

sub rrd_graph {
    my ($rrd, $file, $start, $end, $type) = @_;
    my @colors = qw/FF0000 00FF00 0000FF/;
    if( (stat($file))[9] < $end-$image_refresh_time){
        $rrd->graph(
                image          => $file,
                vertical_label => 'bytes per second',
                start          => $start,
                end            => $end ,
                draw           => { 
                dsname    => $type,
                name    => $type,
                thickness => 1,
                color     => $colors[0],
                legend    => $type,
                },
                draw           => { 
                name    => 'average',
                thickness => 1,
                vdef =>     "$type,AVERAGE",
                color     => $colors[1],
                },
                gprint         => {
                draw      => 'average',
                format    => 'Average=%9.2lf%s',
                },
                );
    }
}
print $q->header,
      $q->start_html('Page with device statistics');
if(defined $dev && defined $port){
    my $path = '/var/www/img';
    my $end = time();
    my $start  = $end - (3600*24*31);
    foreach my $type ( @names ){
        next if ($type =~ /_32/ && ref $devices->{$dev}->{stat}->{$port}->{bytes_in_64} eq 'HASH');
        my @t = sort keys %{$devices->{$dev}->{stat}->{$port}->{$type}};
        next unless ($#t>0);
        my $rrd = RRDTool::OO->new( file => "$path/myrrdfile.rrd" );
        $rrd->create(
                step        => $step,  # one-second intervals
                start       => $start,
                data_source => { 
                name      => $type,
                type      => "GAUGE" },
                archive     => { 
                rows      => (3600/$step)*24*31,
                },
                );
        foreach my $t ( @t){
            unless($t > $start && $t < $end ){ next ;}
            $rrd->update(time => $t , value => $devices->{$dev}->{stat}->{$port}->{$type}->{$t} );
        }
        unless(-d "$path/$dev/$port"){
            mkpath "$path/$dev/$port";
        }
        my $name = $type;
        if($type =~ /^(\w+)_\d\d/){
            $name = $1;
        }
        rrd_graph($rrd, "$path/$dev/$port/${name}_2h.png", $end-2*3600, $end, $type);
        rrd_graph($rrd, "$path/$dev/$port/${name}_8h.png", $end-8*3600, $end, $type);
        rrd_graph($rrd, "$path/$dev/$port/${name}_24h.png", $end-24*3600, $end, $type);
        rrd_graph($rrd, "$path/$dev/$port/${name}_w.png", $end-7*24*3600, $end, $type);
    }
    my $count=0;
    all_devices();
    ports();
    print $q->h2("Statistics for port ".$devices->{$dev}->{stat}->{$port}->{descr}." on device $dev ");
    print "<table>";
    foreach $be (qw/bytes_in bytes_out error_in error_out/){
        print "<tr><td colspan=\"100%\"><h3>$be</h3></td></tr>\n";
        print "<tr>";
        foreach my $p (qw/2h 8h 24h w/){
            unless($count++%2){
                print "</tr>\n";
                print "<tr>";
            }
            print "<td><image src = \"../img/$dev/$port/${be}_$p.png\" > </image></td>";
        }
    }
    print "<tr>";
    print "</table>\n";
}elsif(defined $dev){
    ports();
}else{
    all_devices();
}

print $q->end_html;
