#!/bin/bash
. {{ monitoring_lib_dir }}/metricslib.sh

DATE=`date +%d.%m.%y-%T`
echo "Renewal on $DATE" > {{ letsencrypt_root }}/lastrun.log

incCounter "LE_RENEW_RUN"

certbot renew >> {{ letsencrypt_root }}/lastrun.log
if [ $? -ne 0 ]
then
  setGauge "LE_RENEW" 2
else
  setGauge "LE_RENEW" 1
fi

systemctl restart nginx >> {{ letsencrypt_root }}/lastrun.log
