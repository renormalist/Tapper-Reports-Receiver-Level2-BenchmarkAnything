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

# TAP aggregation metrics per type
our @boolean_aggregation_metrics  = qw(all_passed has_errors has_problems);
our @counter_aggregation_metrics  = qw(failed parse_errors total passed skipped todo todo_passed);
our @textual_aggregation_metrics  = qw(status);

=head2 submit

Extract BenchmarkAnything data from a report and submit them to a
BenchmarkAnything store.

=cut

sub submit {
  my ($util, $report, $options) = @_;

  my $benchmark_entries_path          = $options->{benchmark_entries_path};
  my $additional_metainfo_path        = $options->{additional_metainfo_path};
  my $store_metainfo_as_benchmarks    = $options->{store_metainfo_as_benchmarks};
  my $store_testmetrics_as_benchmarks = $options->{store_testmetrics_as_benchmarks};

  return unless $benchmark_entries_path;

  try {
    my $tap_dom = $report->get_cached_tapdom;

    # debug log
    my @test_metrics = ();
    my %test_metrics_aggregated = ();
    for my $section (@{$tap_dom || []})
      {
        foreach my $section_name (keys %{$section->{section} || {}}) # there should be only one, but loop anyway...
          {
            $section = $section->{section}{$section_name};

            my $metric_name = $section_name;
            $metric_name =~ s/\.t$//;
            $metric_name =~ s/\W+/_/g;
            $util->log->debug("section metric_name: $metric_name");

            # Metric name contemplation:
            # --------------------------
            #
            # There is a decision to make between 1) having
            # $metric_name as part of the NAME field or 2) having
            # generic NAMEs with $metric_name as an attribute of
            # it.
            #
            # Here we make it part of NAME (option 1).
            #
            # With this it is easier to track a particular test as
            # a metric and store expectations for that test with
            # test independent attributes but consisting of the
            # context in which we measured that metric. That
            # "scope", i.e., the fields that we use to match which
            # expectation to choose, consists then of that many
            # dimensions as we need to describe the context,
            # independent of the number of metrics we have.
            #
            # If we had the metric as additional attribute we had
            # thousands of scope dimensions to maintain because we
            # have thousands of metric names; and we could not
            # clearly separate between the test and its context.
            #
            # From a test philosophical perspective, that decision
            # sets the focus on the *actual result* we care for,
            # instead of some generic detail like "success".
            #
            # From a data performance and complexity perspective,
            # I also think that having more metrics, each with
            # "normal" amount of describing attributes is better
            # distributing the data than having few generic
            # metrics with thousands of different describing
            # attributes and gazillions of data points per
            # metric. Though I'm not an expert here.
            #
            foreach my $entry (@boolean_aggregation_metrics, @counter_aggregation_metrics, @textual_aggregation_metrics)
              {
                push @test_metrics, { NAME  => "tap.summary.${metric_name}.${entry}",
                                      VALUE => $section->{tap}{summary}{$entry},
                                    };
              }

            # summarize all sections
            # - bool metrics -
            foreach my $entry (@boolean_aggregation_metrics) {
              $test_metrics_aggregated{$entry} ||= $section->{tap}{summary}{$entry};
            }
            # - counter metrics -
            foreach my $entry (@counter_aggregation_metrics) {
              $test_metrics_aggregated{$entry} += ($section->{tap}{summary}{$entry} || 0);
            }
            # - no textual aggregation -
          }
      }

    # Actual aggregated metrics
    #
    # Note, that with "all.sections" containing a dot and the actual
    # metric names above not containing dots there are no collisions
    # in NAME.
    foreach my $entry (@boolean_aggregation_metrics, @counter_aggregation_metrics) {
      push @test_metrics, { NAME  => "tap.summary.all.sections.${entry}",
                            VALUE => $test_metrics_aggregated{$entry},
                          };
    }

    $util->log->debug("test metrics: ".Dumper(\@test_metrics));

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
    my $benchmark_counter = 0;
    $balib->{queuemode} = 1;

    # Part 1 - actual BenchmarkAnything data points
    foreach my $entry (@benchmark_entries)
      {
        if (@metainfo_entries)
          {
            Hash::Merge::set_behavior('LEFT_PRECEDENT');
            foreach my $metainfo (@metainfo_entries)
              {
                # merge each $metainfo entry into current
                # chunk before submitting the chunk
                $entry = merge($entry, $metainfo);
              }
          }

        # additional context info
        $entry->{tapper_report} ||= $report->id;
        $entry->{tapper_testrun} ||= $report->reportgrouptestrun->testrun_id if $report->reportgrouptestrun && $report->reportgrouptestrun->testrun_id;
        $entry->{tapper_reportgroup_arbitrary} ||= $report->reportgrouparbitrary->arbitrary_id if $report->reportgrouparbitrary && $report->reportgrouparbitrary->arbitrary_id;

        # debug log
        {
          # You MUST localize Data::Dumper settings to strictly ONLY cover
          # the debug output - otherwise it wrongly serializes the tap_dom
          # cache into the DB during get_cached_tapdom().
          local $Data::Dumper::Pair = ":";
          local $Data::Dumper::Terse = 2;
          local $Data::Dumper::Sortkeys = 1;
          $util->log->debug("store benchmark: ".Dumper($entry));
        }

        # actually submit data
        $balib->add ({BenchmarkAnythingData => [$entry]});
        $benchmark_counter++;
      }

    # Part 2 - store summary numbers from test/TAP as additional metrics
    if ($store_testmetrics_as_benchmarks)
      {
        foreach my $entry (@test_metrics)
          {
            if (@metainfo_entries)
              {
                Hash::Merge::set_behavior('LEFT_PRECEDENT');
                foreach my $metainfo (@metainfo_entries)
                  {
                    # merge each $metainfo entry into current
                    # chunk before submitting the chunk
                    $entry = merge($entry, $metainfo);
                  }
              }

            # additional context info
            $entry->{tapper_report} ||= $report->id;
            $entry->{tapper_testrun} ||= $report->reportgrouptestrun->testrun_id if $report->reportgrouptestrun && $report->reportgrouptestrun->testrun_id;
            $entry->{tapper_reportgroup_arbitrary} ||= $report->reportgrouparbitrary->arbitrary_id if $report->reportgrouparbitrary && $report->reportgrouparbitrary->arbitrary_id;

            # debug log
            {
              # You MUST localize Data::Dumper settings to strictly ONLY cover
              # the debug output - otherwise it wrongly serializes the tap_dom
              # cache into the DB during get_cached_tapdom().
              local $Data::Dumper::Pair = ":";
              local $Data::Dumper::Terse = 2;
              local $Data::Dumper::Sortkeys = 1;
              $util->log->debug("store test metric: ".Dumper($entry));
            }

            # actually submit data
            $balib->add ({BenchmarkAnythingData => [$entry]});
            $benchmark_counter++;
          }
      }

    # Part 3 - store metainfo as additional metrics
    if ($store_metainfo_as_benchmarks)
      {
        foreach my $entry (@metainfo_entries)
          {
            {
              # You MUST localize Data::Dumper settings to strictly ONLY cover
              # the debug output - otherwise it wrongly serializes the tap_dom
              # cache into the DB during get_cached_tapdom().
              local $Data::Dumper::Pair = ":";
              local $Data::Dumper::Terse = 2;
              local $Data::Dumper::Sortkeys = 1;
              $util->log->debug("store metainfo: ".Dumper($entry));
            }
            $balib->add ({BenchmarkAnythingData => [$entry]});
            $benchmark_counter++;
          }
      }

    # process the queue; cleanup processed queue entries; disconnect.
    #
    # This might take a while but we are a forked child process anyway
    # and if we would fail the BenchmarkAnything 'processqueue'
    # mechnanism is robust and the next child will continue. By
    # doubling the batch size we process more than we submitted which
    # should help cleaning up a big pile of data in case of crashes.
    $balib->process_raw_result_queue(2 * $benchmark_counter);
    $balib->gc;
    $balib->disconnect;
  }

    catch
      {
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
       # whether test/TAP summary metrics should also stored into the benchmark store
       store_testmetrics_as_benchmarks: 0
       # whether to skip that plugin
       disabled: 0

=cut
