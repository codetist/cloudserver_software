#!/bin/bash
. {{ monitoring_lib_dir }}/metricslib.sh

DATE=`date +%d.%m.%y-%T`
echo "Renewal on $DATE" > {{ geoip_dir }}/lastrun.log

incCounter "GEOIP_RENEW_RUN"

/usr/bin/geoipupdate >> {{ geoip_dir }}/lastrun.log
if [ $? -ne 0 ]
then
  setGauge "GEOIP_RENEW" 2
else
  setGauge "GEOIP_RENEW" 1
fi
