#!/bin/bash
# A script to get commands to ssh into nodes in a run.
# You can provide run number, otherwise gets info for the last run
tmt_tmp=/var/tmp/tmt
if [ -n "$1" ]; then
    run=run-$1
else
    # Get last run
    # shellcheck disable=SC2010
    run=$(ls $tmt_tmp | grep "run-" | tail -n1)
fi
last_run_abs=$tmt_tmp/$run
plan_abs=$(find "$last_run_abs"/plans/* -maxdepth 0 -type d)
guests_yml=$plan_abs/provision/guests.yaml
nodes=$(yq -r ". | keys | .[]" "$guests_yml"| sort)
for node in $nodes; do
    id_ecdsa=$plan_abs/provision/$node/id_ecdsa
    ip_addr=$(yq -r ".\"$node\".primary-address" "$guests_yml")
    ssh_cmd="$node: ssh -oPasswordAuthentication=no -oStrictHostKeyChecking=no -i $id_ecdsa root@$ip_addr"
    echo "$ssh_cmd"
done
