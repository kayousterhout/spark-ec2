#!/bin/bash

/root/spark-ec2/copy-dir /root/spark

# Make the directory for the event logs to go into.
if [ ! -d /tmp/spark-events ]; then
  mkdir /tmp/spark-events
fi
