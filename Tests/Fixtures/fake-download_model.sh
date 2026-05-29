#!/bin/sh
# Emits two curl-meter style progress updates then succeeds.
printf '  %% Total    %% Received %% Xferd\n' 1>&2
printf ' 42 80.8G   42 34.0G    0     0  85.2M      0\r' 1>&2
printf ' 100 80.8G  100 80.8G    0     0  85.2M      0\n' 1>&2
echo "Done."
exit 0
