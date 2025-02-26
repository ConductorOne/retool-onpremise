#!/bin/bash

## Configure iptables that affect the unprivileged "retool_user" user

# See https://sipb.mit.edu/doc/safe-shell/
set -euf -o pipefail

getDataDogAgentHostIp() {
  if [[ "${DD_AGENT_HOST:-}" ]]; then
    # DD_AGENT_HOST is the host IP of the pod in prod
    echo "$DD_AGENT_HOST"
  elif [[ "${POD_HOST_IP:-}" ]]; then
    # POD_HOST_IP is set by Garden
    echo "$POD_HOST_IP"
  elif [[ "${K8S_NODE_IP:-}" ]]; then
    echo "$K8S_NODE_IP"
  else
    echo ""
  fi
}

CODE_EXECUTOR_PORT="${CODE_EXECUTOR_PORT:-3004}"

export DATADOG_ENABLE_TRACING="${DATADOG_ENABLE_TRACING:-false}"
export DATADOG_AGENT_HOST_IP=$(getDataDogAgentHostIp)
export DATADOG_AGENT_APM_PORT="${DATADOG_AGENT_APM_PORT:-8126}"

# todo(colin): re-enable once we have a better understanding of which ranges we need to allow
# if [[ "${DATADOG_ENABLE_TRACING:-}" == "true" && "${DATADOG_AGENT_HOST_IP:-}" ]]
# then
#   echo "iptables: Allowing connections to DataDog agent host IP $DATADOG_AGENT_HOST_IP:$DATADOG_AGENT_APM_PORT"
#   iptables-legacy -A OUTPUT -d $DATADOG_AGENT_HOST_IP -p tcp --dport $DATADOG_AGENT_APM_PORT -m owner --uid-owner retool_user -j ACCEPT

#   # Allow responses to any valid incoming requests to the code_executor application
#   iptables-legacy -A OUTPUT -m conntrack -p tcp --sport $CODE_EXECUTOR_PORT -m owner --uid-owner retool_user --ctstate ESTABLISHED -j ACCEPT

#   echo "iptables: Disallowing private ips"
#   iptables-legacy -A OUTPUT -d 10.0.0.0/8 -m owner --uid-owner retool_user -j DROP
# fi

# echo "iptables: Disallowing link-local addresses"
# iptables-legacy -A OUTPUT -d 169.254.0.0/16 -m owner --uid-owner retool_user -j DROP
# iptables-legacy -A OUTPUT -d 192.168.0.0/16 -m owner --uid-owner retool_user -j DROP

if [[ "${NODE_ENV:-}" = "development" ]]
then
  # need to run tsc-build before su because of filesystem permissions on retool_user
  yarn dev-tsc-build &
  # TODO: figure out why below doesn't properly refresh
  # yarn --cwd ../workflowCodeExecutor dev-tsc-build &
  su retool_user -c "yarn dev-server-autoreload"
else
  # A workround helper function to wait for a pid that is not the child process of this script.
  # Running the code executor process with `su` unfortunately disassociates it from the main process.
  # https://stackoverflow.com/questions/1157700/how-to-wait-for-exit-of-non-children-processes
  wait_for_pid() {
    p=$1
    while true; do
      if kill -0 $p > /dev/null 2>&1; then
        sleep 1
      else
        echo "Node process exited; exiting startup script"
        break
      fi
    done
  }
  sigterm_handler() {
    echo "Exit signal received"
    if [ ! -z $pid ]; then
      echo "Asking Node to exit gracefully from parent pid $pid"
      childpid=$(cat /proc/${pid}/task/${pid}/children)
      childpid=${childpid// }
      echo "Intermediate parent pid is $childpid"
      nodepid=$(cat /proc/${childpid}/task/${childpid}/children)
      nodepid=${nodepid// }
      echo "Terminating pid $nodepid"
      kill -TERM "$nodepid"
      wait_for_pid $nodepid
    fi
    echo "Node exited cleanly; exiting container"
    exit 143; # 128 + 15 -- SIGTERM
  }
  trap sigterm_handler SIGTERM SIGINT
  su retool_user -c "node /retool/code_executor/transpiled/main.js" &
  pid="$!"
  wait $pid
fi