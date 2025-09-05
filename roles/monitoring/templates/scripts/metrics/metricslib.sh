#!/bin/bash

# base url of pushgateway
PUSHGATEWAY_BASE_URL=http://{{ ansible_host }}:9091/pushgateway

# enable/disable debug output
DEBUG_MODE=0

# metrics persistence file
METRICS_FILE={{ monitoring_lib_dir }}/.metrics
# metrics lock file
METRICS_LOCK_FILE={{ monitoring_lib_dir }}/.metricslock
# metrics in pushgateway format
METRICS_PUSHGATEWAY_FILE={{ monitoring_lib_dir}}/.pushgateway
# definition of available metrics
METRICS_CONF_FILE={{ monitoring_lib_dir }}/conf/metrics.conf
# definition of metrics types
METRICS_TYPES_CONF_FILE={{ monitoring_lib_dir }}/conf/metrics.types.conf

# representation of current metrics values
# maps shortname to full metric definition
declare -A METRICS_NAME_MAP
# maps shortname to current value
declare -A METRICS_VALUE_MAP
# metric type definitions
declare -A METRIC_TYPES_MAP

##
## INIT
##

# make sure conf files exist. Empty is okay, but they have to exist.
touch $METRICS_FILE
touch $METRICS_TYPES_CONF_FILE

##
## public functions
##
incCounter() {
  METRIC_SHORT_NAME=$1

  acquireLock
  initCurrentMetrics

  incCounterInternal $METRIC_SHORT_NAME

  writeCurrentMetrics
  generatePrometheusMetrics
  sendToPushgateway
  releaseLock
}

setGauge() {
  METRIC_SHORT_NAME=$1
  METRIC_VALUE=$2

  acquireLock
  initCurrentMetrics

  setGaugeInternal $METRIC_SHORT_NAME $METRIC_VALUE

  writeCurrentMetrics
  generatePrometheusMetrics
  sendToPushgateway
  releaseLock
}

# Just regenerate all metrics, so they get initialized
# and sent to pushgateway
refresh() {
  acquireLock
  initCurrentMetrics
  writeCurrentMetrics
  generatePrometheusMetrics
  sendToPushgateway
  releaseLock
}

##
## Internal functions
##

#
# init metric maps
# - read current metrics from config
# - initialize new metrics
# - apply values of existing metrics
# - remove metrics not longer in config
#
initCurrentMetrics() {
  debug "initCurrentMetrics..."

  debug "initializing values for all configured metrics..."
  while IFS= read -r line dest
  do
    # trim
    line=$(echo "$line" | awk '{$1=$1; print}')

    # ignore comments
    ! [[ $line =~ ^#.* ]] || continue

    # ignore lines that do not match shortname::full metric syntax
    [[ $line =~ (.*)::(.*) ]] || continue

    metricShortName=${BASH_REMATCH[1]}
    metricFull=${BASH_REMATCH[2]}

    # trim
    metricShortName=$(echo "$metricShortName" | awk '{$1=$1; print}')
    metricFull=$(echo "$metricFull" | awk '{$1=$1; print}')

    METRICS_NAME_MAP[$metricShortName]=$metricFull
    METRICS_VALUE_MAP[$metricShortName]=0

    debug "added pair: $metricShortName=$metricFull, with value: 0"
  done < $METRICS_CONF_FILE

  debug "applying existing values..."

  while IFS= read -r line dest
  do
    # ignore lines that do not match shortname::value
    [[ $line =~ (.*)==(.*) ]] || continue

    metricShortName=${BASH_REMATCH[1]}
    metricValue=${BASH_REMATCH[2]}

    # keep value only, if metric is still configured,
    # otherwise remove
    if [[ ${METRICS_NAME_MAP[$metricShortName]+_} ]]; then
      METRICS_VALUE_MAP[$metricShortName]=$metricValue
      debug "applies existing value: $metricShortName, value: $metricValue"
    else
      debug "removed not longer existing key: $metricShortName"
    fi
  done < $METRICS_FILE
}

#
# increment counter value
# (metric type is not validated)
#
incCounterInternal() {
  METRIC_SHORT_NAME=$1

  if [[ ${METRICS_NAME_MAP[$METRIC_SHORT_NAME]+_} ]]; then
    oldMetricValue="${METRICS_VALUE_MAP[$METRIC_SHORT_NAME]}"
    newMetricValue=$((${METRICS_VALUE_MAP[$METRIC_SHORT_NAME]}+1))
    METRICS_VALUE_MAP[$METRIC_SHORT_NAME]=$newMetricValue
    debug "applied new value: $metricShortName, value: $newMetricValue (was: $oldMetricValue)"
  else
    debug "unknown key $METRIC_SHORT_NAME ignored..."
  fi
}

#
# set gauge value
# (metric type is not validated)
#
setGaugeInternal() {
  METRIC_SHORT_NAME=$1
  METRIC_VALUE=$2

  if [[ ${METRICS_NAME_MAP[$METRIC_SHORT_NAME]+_} ]]; then
    METRICS_VALUE_MAP[$METRIC_SHORT_NAME]=$METRIC_VALUE
    debug "applied new value: $metricShortName, value: $METRIC_VALUE"
  else
    debug "unknown key $METRIC_SHORT_NAME ignored..."
  fi
}

#
# write current metric values to metrics file
#
writeCurrentMetrics() {
  debug "writing new metrics file..."
  for metricShortName in "${!METRICS_VALUE_MAP[@]}"; do
    echo "$metricShortName==${METRICS_VALUE_MAP[$metricShortName]}"
  done > $METRICS_FILE
}

#
# generate prometheus file
# - map metric and values to strings
# - sort alphabetically, to achieve all metrics with the same name are in one block
# - appends type header (if available)
# - write to file
generatePrometheusMetrics() {
  debug "creating prometheus metrics..."
  prometheusList=()

  for metricShortName in "${!METRICS_NAME_MAP[@]}"; do
    metric="${METRICS_NAME_MAP[$metricShortName]}"
    metricValue="${METRICS_VALUE_MAP[$metricShortName]}"

    metricFloatValue=$(awk -v v="$metricValue" 'BEGIN { printf("%.1f", v) }')

    metricLine="$metric $metricFloatValue"
    prometheusList+=("$metricLine")

    debug "appended: $metricLine"
  done

  debug "sorting metrics..."
  readarray -t sortedPrometheusList < <(printf "%s\n" "${prometheusList[@]}" | sort)

  debug "reading metric types..."
  while IFS= read -r line dest
  do
    # trim (also reduces multiple space to only one)
    line=$(echo "$line" | awk '{$1=$1; print}')

    # ignore comments
    ! [[ $line =~ ^#.* ]] || continue

    # ignore lines that do not match shortname::full metric syntax
    [[ $line =~ (.*)::(.*) ]] || continue

    metricName=${BASH_REMATCH[1]}
    metricType=${BASH_REMATCH[2]}

    # trim
    metricName=$(echo "$metricName" | awk '{$1=$1; print}')
    metricType=$(echo "$metricType" | awk '{$1=$1; print}')

    # put to list
    METRIC_TYPES_MAP[$metricName]=$metricType

    debug "added metric: $metricName with type: $metricType"
  done < $METRICS_TYPES_CONF_FILE

  debug "generating pushgateway file..."
  previousLinesMetricName="###unknown###"
  pushgatewayLines=()

  for metricLine in "${sortedPrometheusList[@]}"; do

    # get metric name without labels and values
    # remove values (after and including first space)
    metricName="${metricLine%% *}"
    # remove labels (after and including first curly bracket)
    metricName="${metricName%%\{*}"

    debug "current line: $metricLine"
    debug "current metric: $metricName"

    if [[ ${METRIC_TYPES_MAP[$metricName]+_} ]]; then
      typeName="${METRIC_TYPES_MAP[$metricName]}"
      debug "metric is of type: $typeName"
    else
      debug "no type information found"
    fi

    # found new metric (as metricLines are sorted alphabetically)
    # add
    if ! [[ "$previousLinesMetricName" == "$metricName" ]]; then
      pushgatewayLines+=("# TYPE $metricName $typeName")
    fi

    previousLinesMetricName="$metricName"

    # add metric line
    pushgatewayLines+=("$metricLine")
  done

  # write lines to file
  printf "%s\n" "${pushgatewayLines[@]}" > $METRICS_PUSHGATEWAY_FILE
}

sendToPushgateway() {
  curl --data-binary @$METRICS_PUSHGATEWAY_FILE $PUSHGATEWAY_BASE_URL/metrics/job/pushgateway
  if [ $? -ne 0 ]
  then
    debug "Pushing metrics failed."
    exit 1
  fi
}

#
# acquire lock
# Only one instance of this script is allowed to modify metrics at
# a time. Possible other calls will wait up to 5 seconds or fail.
#
acquireLock() {
  exec 9>"$METRICS_LOCK_FILE"    # File descriptor 9 opens lock file
  flock --exclusive --timeout 5 9 || {
      echo "Could not acquire lock."
      exit 1
  }
}

#
# release lock
# if the script dies, the lock is release automatically
#
releaseLock() {
  exec 9>&-
}

#
# print debug messages
#
debug() {
  if [[ $DEBUG_MODE -ne 0 ]]; then
    echo "DEBUG: $1"
  fi
}

