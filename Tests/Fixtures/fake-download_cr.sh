#!/bin/sh
# Mimics curl --progress-meter: \r-delimited repaints, no \n until the very end.
# Sleeps between updates so each progress line arrives in its own read/emit cycle,
# making the "intermediate progress observed" integration test deterministic
# (without the gaps, CI batches all reads into one chunk and the intermediate
# percentages are coalesced away before the @Published sink can observe them).
printf '  %% Total    %% Received %% Xferd\r' 1>&2
sleep 0.4
printf ' 25 80.8G   25 20.2G    0     0  85.2M      0\r' 1>&2
sleep 0.4
printf ' 60 80.8G   60 48.5G    0     0  85.2M      0\r' 1>&2
sleep 0.4
printf ' 100 80.8G  100 80.8G    0     0  85.2M      0\n' 1>&2
echo "Done."
exit 0
