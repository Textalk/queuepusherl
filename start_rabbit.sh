#!/bin/sh

SCRIPT=`realpath $0`
SCRIPTPATH=`dirname $SCRIPT`
ROOTPATH=`dirname $SCRIPTPATH`
RABBITPATH="${ROOTPATH}/rabbitmq-server"

cd $RABBITPATH

export RABBITMQ_NODENAME="rabbit@localhost"
#export RABBITMQ_NODE_IP_ADDRESS=localhost
#export RABBITMQ_NODE_PORT=5672
export RABBITMQ_LOG_BASE=/tmp
export RABBITMQ_CONFIG_FILE=${SCRIPTPATH}/priv/rabbit
export RABBITMQ_CONSOLE_LOG=1

exec make run
