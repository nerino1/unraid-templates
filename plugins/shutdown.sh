#!/bin/bash
# iDRAC Fan Controller shutdown hook
# Called by rc.local.stop on Unraid shutdown/reboot
# Hands fan control back to Dell regardless of service state

CFG="/boot/config/plugins/idrac-fan-controller/idrac-fan-controller.cfg"
if [ -f "$CFG" ]; then
  source "$CFG"
  if [[ "$IDRAC_HOST" == "local" ]]; then
    LOGIN="open"
  else
    LOGIN="lanplus -H $IDRAC_HOST -U $IDRAC_USERNAME -P $IDRAC_PASSWORD"
  fi
  /usr/bin/ipmitool -I $LOGIN raw 0x30 0x30 0x01 0x01 > /dev/null 2>&1
  echo "$(date): iDRAC fan control returned to Dell default on shutdown" >> /mnt/user/appdata/idrac-fan-controller/service.log
fi
