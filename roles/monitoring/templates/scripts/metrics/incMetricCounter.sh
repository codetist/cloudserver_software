#!/bin/bash
. {{ monitoring_lib_dir }}/metricslib.sh

COUNTER_METRIK=$(echo "$1" | awk '{$1=$1; print}')

if ! [ -z "${COUNTER_METRIK}" ]; then
  incCounter "$1"
else
  echo "Metric name expected!"
fi
