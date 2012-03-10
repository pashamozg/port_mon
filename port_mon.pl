#!/usr/bin/perl
use Storable;
use CGI qw/:standart/;
use File::Path;
use RRDTool::OO;
use Data::Dumper;
my @kv = (
        # 64bit
       {'1.3.6.1.2.1.31.1.1.1.6' =>'bytesIn',
        '1.3.6.1.2.1.31.1.1.1.10' =>'bytesOut',
       },
        # 32bit
       {'1.3.6.1.2.1.2.2.1.10' =>'bytesIn',
        '1.3.6.1.2.1.2.2.1.16' =>'bytesOut',
        },
       {'1.3.6.1.2.1.2.2.1.14'=>'errorIn',
        '1.3.6.1.2.1.2.2.1.20'=>'errorOut',
        },
    );
my $d_store_path = '/home/pasha/projects/port_mon/dev_store';
my $image_refresh_time = 60;
my $q = CGI->new();

my $dev = $q->param('device');
my $port = $q->param('port');

my $devices;

if(-e $d_store_path){
    $devices =  retrieve($d_store_path);
}

sub rrd_graph {
    my ($rrd, $file, $start, $end, $ds) = @_;
    my @colors = qw/FF0000 00FF00 0000FF/;
    my @draw;
    foreach(0..$#{$ds}){
        my %tmp = (
            draw           => { 
                dsname    => $ds->[$_],
                thickness => 1,
                color     => $colors[$_],
                legend    => $ds->[$_],
                cfunc   => 'AVERAGE',
                },
                );
        push @draw, %tmp;
    }
    if( (stat($file))[9] < $end-$image_refresh_time){
        $rrd->graph(
                image          => $file,
                vertical_label => 'bytes per second',
                start          => $start,
                end            => $end ,
                @draw,
        );
    }
}
print $q->header,
      $q->start_html('Page with device statistics');
if(defined $dev && defined $port){
    my $path = '../htdocs/img';
    my $end = time();
    my $start  = $end - (300*12*24*31);
    foreach my $in_out (@kv){
        my @ds = values %$in_out;
        my @oids = keys %$in_out;
        if(exists $devices->{$dev}->{stat}->{$port} && exists $devices->{$dev}->{stat}->{$port}->{$oids[0]}){
            my @t = sort keys %{$devices->{$dev}->{stat}->{$port}->{$oids[0]}};
            next unless ($#t>0);
            my $rrd = RRDTool::OO->new( file => "$path/myrrdfile.rrd" );
            my $base_name = ($ds[0]=~/bytes/)?'bytes':'errors';
            $rrd->create(
                    step        => 60,  # one-second intervals
                    start       => $start,
                    data_source => { 
                        name      => $ds[0],
                        type      => "GAUGE" },
                    data_source => {
                       name    => $ds[1],
                        type    => 'GAUGE'},
                    archive     => { 
                        rows      => 60*24*31,
                        cfunc     => 'AVERAGE',
                    },
                    archive => {
                        rows    => 60*24*31,
                        cfunc     => 'AVERAGE',
                    },
            );
            foreach my $t (@t){
                unless($t > $start && $t < $end ){ next ;}
                my $vals;
                foreach my $oid ( 0..$#oids  ){
                    $vals->{$ds[$oid]} =  $devices->{$dev}->{stat}->{$port}->{$oids[$oid]}->{$t} ;
                }
                $rrd->update(time => $t , values => $vals );
            }
            unless(-d "$path/$dev/$port"){
                mkpath "$path/$dev/$port";
            }
            rrd_graph($rrd, "$path/$dev/$port/${base_name}_4h.png", $end-3600, $end , \@ds);
            rrd_graph($rrd, "$path/$dev/$port/${base_name}_12h.png", $end-12*3600, $end ,\@ds);
            rrd_graph($rrd, "$path/$dev/$port/${base_name}_24h.png", $end-24*3600, $end ,\@ds);
            rrd_graph($rrd, "$path/$dev/$port/${base_name}_w.png", $end-7*24*3600, $end ,\@ds);
        }
    }
    foreach( sort keys %$devices){
        print "<a href=port_mon.pl?device=$_> $_ </a> &nbsp&nbsp";
    }
    print $q->h1("Statistics for port ".$devices->{$dev}->{stat}->{$port}->{name}." on device $dev ");
    print "<table>";
    foreach my $p (qw/4h 12h 24h w/){
        print "<tr>";
        foreach $be (qw/bytes errors/){
            print "<td><image src = \"../img/$dev/$port/${be}_$p.png\" > </image></td>";
        }
        print "</tr>\n";
    }
    print "</table>\n";
}elsif(defined $dev){
    print $q->h1("Knowing ports for $dev");
    print "<table>\n";
    if(exists $devices->{$dev}){
        foreach(sort {$a <=> $b} keys %{$devices->{$dev}->{stat}}){
            print "<tr><td>";
            print "<a href=port_mon.pl?device=$dev&port=$_> $dev / $_ (".$devices->{$dev}->{stat}->{$_}->{name}.") </a>";
            print "</td></tr>\n";
        }
        print "</table>";
    }
}else{
    print $q->h1('Knowing devices');
    print "<table>\n";
    foreach( sort keys %$devices){
        print "<tr><td>";
        print "<a href=port_mon.pl?device=$_> $_ </a>";
        print "</td></tr>\n";
    }
    print "</table>";
}

print $q->end_html;
