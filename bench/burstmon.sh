#!/usr/bin/env bash
# Records the most active processes when the run queue exceeds 14 threads
# (detects external load that contaminates the measurements). Usage: bench/burstmon.sh <file> &
out="$1"
while :; do
  r=$(awk '{split($4,a,"/"); print a[1]}' /proc/loadavg)
  if [ "$r" -gt 14 ]; then
    { echo "== $(date +%T.%N | cut -c1-12) running=$r memfree=$(awk '/MemFree/{print int($2/1024)}' /proc/meminfo)MiB"
      ps -eo pid,ppid,pcpu,rss,nlwp,stat,comm,args --sort=-pcpu | head -6 | cut -c1-220
      ps -e -L -o pid,tid,stat,comm | awk '$3 ~ /^R/' | awk '{c[$1" "$4]++} END{for(k in c) print "  R threads:", k, c[k]}' | sort -k5 -nr | head -5
    } >> "$out"
  fi
  sleep 0.3
done
