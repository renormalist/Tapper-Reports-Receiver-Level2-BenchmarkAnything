use strict;
use warnings;
package Tapper::Reports::Receiver::Level2::BenchmarkAnything;
# ABSTRACT: Tapper - Level2 receiver plugin to forward BenchmarkAnything data

use Try::Tiny;
use Data::Dumper;
use Data::DPath 'dpath';
use Hash::Merge 'merge';
use Scalar::Util 'reftype';
use Tapper::Model 'model';
use Tapper::Config 5.0.2; # 5.0.2 provides {_last_used_tapper_config_file}

=head2 submit

Extract BenchmarkAnything data from a report and submit them to a
BenchmarkAnything store.

=cut

sub submit
{
    my ($util, $report, $options) = @_;

    local $Data::Dumper::Pair = ":";
    local $Data::Dumper::Terse = 2;
    local $Data::Dumper::Sortkeys = 1;

    my $benchmark_entries_path          = $options->{benchmark_entries_path};
    my $additional_metainfo_path        = $options->{additional_metainfo_path};
    my $store_metainfo_as_benchmarks    = $options->{store_metainfo_as_benchmarks};

    return unless $benchmark_entries_path;

    try {
        my $tap_dom = $report->get_cached_tapdom;

        my @benchmark_entries = dpath($benchmark_entries_path)->match($tap_dom);
        @benchmark_entries = @{$benchmark_entries[0]} while $benchmark_entries[0] && reftype $benchmark_entries[0] eq "ARRAY"; # deref all array envelops

        my @metainfo_entries = ();
        if ($additional_metainfo_path)
          {
              @metainfo_entries = dpath($additional_metainfo_path)->match($tap_dom);
              @metainfo_entries = @{$metainfo_entries[0]} while $metainfo_entries[0] && reftype $metainfo_entries[0] eq "ARRAY"; # deref all array envelops
          }

        return unless @benchmark_entries;

        require BenchmarkAnything::Storage::Frontend::Lib;
        my $balib = BenchmarkAnything::Storage::Frontend::Lib->new(cfgfile => Tapper::Config->subconfig->{_last_used_tapper_config_file});

        foreach my $benchmark (@benchmark_entries)
          {
              if (@metainfo_entries)
                {
                    Hash::Merge::set_behavior('LEFT_PRECEDENT');
                    foreach my $metainfo (@metainfo_entries)
                      {
                          # merge each $metainfo entry into current
                          # $benchmark chunk before submitting the chunk
                          $benchmark = merge($benchmark, $metainfo);
                      }
                }

              $util->log->debug("store benchmark: ".Dumper($benchmark));
              $balib->add ({BenchmarkAnythingData => [$benchmark]});
          }

        if ($store_metainfo_as_benchmarks)
          {
              foreach my $metainfo (@metainfo_entries)
                {
                    $util->log->debug("store metainfo: ".Dumper($metainfo));
                    $balib->add ({BenchmarkAnythingData => [$metainfo]});
                }
          }

        $balib->disconnect;
    }
    catch {
        $util->log->debug("error: $_");
        die "receiver:level2:benchmarkanything:error: $_";
    };

    return;
}

1;

=head1 ABOUT

I<Level 2 receivers> are other data receivers besides Tapper to
which data is forwarded when a report is arriving at the
Tapper::Reports::Receiver.

One example is to track benchmark values.

By convention, for BenchmarkAnything the data is already prepared in
the TAP report like this:

 ok - measurements
   ---
   BenchmarkAnythingData:
   - NAME: example.prove.duration
     VALUE: 2.19
   - NAME: example.some.metric
     VALUE: 7.00
   - NAME: example.some.other.metric
     VALUE: 1
   ...
 ok some other TAP stuff

I.e., it requires a key C<BenchmarkAnythingData> and the contained
array consists of chunks with keys that a BenchmarkAnything backend
store is expecting.

=head1 CONFIG

To activate that level2 receiver you should have an entry like this in
your C<tapper.cfg>:

 receiver:
   level2:
     BenchmarkAnything:
       # actual benchmark entries
       benchmark_entries_path: //data/BenchmarkAnythingData
       # optional meta info to merge into each chunk of benchmark entries
       additional_metainfo_path: //data/PlatformDescription
       # whether that metainfo should also stored into the benchmark store
       store_metainfo_as_benchmarks: 0
       # whether to skip that plugin
       disabled: 0

=cut
