unit class Concurrent::Progress;

class Report {
    has Int $.value is required;
    has Int $.target;
    method percent(--> Int) {
        $.target
            ?? (100 * $.value / $.target).Int
            !! Int
    }
}

# Set at construction time and then immutable, so safe.
has Real $.min-interval;
has Bool $.auto-done = True;
has Supplier $!update-sender;
has Supply $!publish-reports;

# Only ever written from inside a per-instance `supply` block, so safe.
has Int $!current-value = 0;
has Int $!current-target;

submethod TWEAK() {
    $!update-sender = Supplier.new;
    $!publish-reports = supply {
        whenever $!update-sender -> $update {
            given $update.key {
                when 'increment' {
                    $!current-value++;
                }
                my $value = $update.value;
                when 'add' {
                    $!current-value += $value;
                }
                when 'value' {
                    $!current-value = $value;
                }
                when 'addtarget' {
                    $!current-target += $value;
                }
                when 'target' {
                    $!current-target = $value;
                }
            }
            emit Report.new(
                value  => $!current-value,
                target => $!current-target
            );
        }
    }.share;
}

method increment(--> Nil) {
    self && $!update-sender.emit('increment' => 1);
}

method add(Int:D $amount --> Nil) {
    self && $!update-sender.emit('add' => $amount);
}

method set-value(Int:D $value --> Nil) {
    self && $!update-sender.emit('value' => $value);
}

method increment-target(--> Nil) {
    self && $!update-sender.emit('addtarget' => 1);
}

method add-target(Int:D $amount --> Nil) {
    self && $!update-sender.emit('addtarget' => $amount);
}

method set-target(Int:D $target --> Nil) {
    self && $!update-sender.emit('target' => $target);
}

method Supply(
  Real :$min-interval = $!min-interval,
  Bool :$auto-done    = $!auto-done
--> Supply:D) {
    my $result = $!publish-reports;
    if $auto-done {
        $result = add-auto-done($result);
    }
    with $min-interval {
        $result = add-throttle($result, $min-interval);
    }
    return $result;
}

sub add-auto-done($in) {
    supply {
        whenever $in {
            .emit;
            if .target.defined {
                if .target == .value {
                    done;
                }
            }
        }
    }
}

sub add-throttle($in, $interval) {
    supply {
        my $emit-allowed = True;
        my $emit-outstanding;

        whenever $in {
            if .target.defined && .value == .target {
                .emit;
                $emit-allowed = False;
                $emit-outstanding = Nil;
            }
            elsif $emit-allowed {
                .emit;
                $emit-allowed = False;
            }
            else {
                $emit-outstanding = $_;
            }
        }
        whenever Supply.interval($interval) {
            with $emit-outstanding {
                emit $emit-outstanding;
                $emit-outstanding = Nil;
            }
            else {
                $emit-allowed = True;
            }
        }
    }
}

=begin pod

=head1 NAME

Concurrent::Progress - Report on the progress of a concurrent operation

=head1 SYNOPSIS

In the operation that should report progress, take C<Concurrent::Progress>
as a parameter (usually optional) and use it. If no instance is passed,
then the method calls will be made on the type object, and will silently
do nothing.

=begin code :lang<raku>

use Concurrent::Progress;

sub some-async-operation(Concurrent::Progress :$progress) {
    start {
        # Optionally set a target (get percentage completion
        # calculation for free).
        my @things-to-do = ...;
        $progress.set-target(@things-to-do.elems);

        # Can add 1 to the count of things completed.
        for @things-to-do {
            ...;
            $progress.increment();
        }

        # Or can add many.
        for @things-to-do.batch(5) -> @batch {
            ...;
            $progress.add(@batch.elems);
        }

        # Or can just set the value, if we're counting by ourselves.
        for @things-to-do.kv -> $idx, $obj {
            ...;
            $progress.set-value($idx + 1);
        }
    }
}

=end code

Meanwhile, in the caller (note that C<whenever> automatically calls
C<Supply> on the C<Concurrent::Progress> object):

=begin code :lang<raku>

my $progress = Concurrent::Progress.new;
react {
    whenever $progress -> $status {
        say "$status.value() / $status.target() ($status.percent()%)";
    }

    whenever some-async-operation(:$progress) {
        say "Completed";
    }
}

=end code

=head1 DESCRIPTION

It's fairly straightforward to wire up concurrent progress reporting
in Raku: create a C<Supplier>, use it to emit progress reports, and
have things wishing to receive progress reports tap the C<Supply>.

That's exactly what this module does on this inside; it just saves
some boilerplate and helps get a little more intent into the code.
It is best suited to cases where "N out of M"-style progress reports
are desired, where N reaching M indicates completion.  However, it
may be used in cases where there is no target also.

=head1 CONSTRUCTION

A C<Concurrent::Progress> instance will usually be constructed by
the initiator of an asynchronous operation. No options are required,
but the following may be provided:

=head2 auto-done

Automatically emits a `done` message on the C<Supply> of progress
reports when the current value reaches the target. This means a
C<whenever> will complete (which is why the C<react> block in the
synopsis example terminates). Defaults to C<True>. Note this isi
only applicable if C<set-target> is called.

=head2 min-interval

The minimum time interval between progress updates. Can be provided
as a C<Real> (C<Int>, C<Rat>, C<Duration>, etc.) If provided, then
there will be at most one update per the specified time interval
(so, passing 1 means at most one update per second). If this option
is not specified, then every progress report will be emitted.

=head1 Methods for reporting progress

The following methods may be called to report progress:

=head2 set-target(Int $target)

Sets the target to be reached to indicate completion. In many cases,
where the total amount of work is known up-front, then this will be
called once. Calling it allows automatic computation of the percentage
complete in progress reports; if it is not called, then the percentage
complete will be undefined. It is allowed to call C<set-target>
multiple times if there is a "moving target", but if using C<auto-done>
then it is up to you to ensure the value never reaches the target
prematurely.

=head2 add-target(Int $amount)

Adds a specific value to the current target.

=head2 increment-target()

Increments the target value by one.

=head2 set-value(Int $value)

Sets the current value included in progress reports, and triggers
emitting a progress report if appropriate.

=head2 increment

Adds 1 to the current value. It is safe to make multiple concurrent
calls to C<increment> (making this highly convenient for divide and
conquer style code).

=head2 add(Int $n)

Adds C<$n> to the current value. As with C<increment>, multiple
concurrent calls are safe.

=head1 Methods for receiving progress reports

Progress reports are delivered using a C<Supply>. This is a I<live>
C<Supply>, so if it matters that you receive every progress report
then be sure to tap it prior to starting the work.

The C<Supply> method is used to obtain the C<Supply> of progress
reports (which means a C<Concurrent::Progress> object may be usedi
directly with C<whenever>).

The C<Supply> will C<emit> instances of C<Concurrent::Progress::Report>,
which has the following properties:

=head2 value

The current value (which will typically correspond to items processed,
bytes download/uploaded, etc.)

=head2 target

If set, the target to which the C<value> property is working (total
items to process, total bytes to be downloaded/uploaded, etc.)

=head2 percent

If C<target> is defined, then C<(100 * $.value / $.target).Int>; if
not, then an C<Int> type object will be returned.

Provided C<auto-done> was not disabled at construction time, then a
C<done> will be sent when C<value> reaches C<target>.

It is also possible to pass C<auto-done> and C<min-interval> to the
C<Supply> method, in order to override them on a per-Supply basis.
This may be useful if you did not have control over the creation of
the C<Concurrent::Progress> instance.

=head1 AUTHOR

Jonathan Worthington

=head1 COPYRIGHT AND LICENSE

Copyright 2017 - 2024 Jonathan Worthington

Copyright 2024 Raku Community

This library is free software; you can redistribute it and/or modify it under the Artistic License 2.0.

=end pod
