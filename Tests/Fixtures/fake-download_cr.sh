#!/bin/sh
# Mimics curl --progress-meter: \r-delimited repaints, no \n until the very end.
printf '  %% Total    %% Received %% Xferd\r' 1>&2
printf ' 25 80.8G   25 20.2G    0     0  85.2M      0\r' 1>&2
printf ' 60 80.8G   60 48.5G    0     0  85.2M      0\r' 1>&2
printf ' 100 80.8G  100 80.8G    0     0  85.2M      0\n' 1>&2
echo "Done."
exit 0
