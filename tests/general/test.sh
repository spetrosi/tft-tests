#!/bin/bash

. /usr/share/beakerlib/beakerlib.sh || exit 1

# test parameters:
# ANSIBLE_VER
#   ansible version to use for tests. E.g. "2.9" or "2.16".
# REPO_NAME
#   Name of the role repository to test.
# PR_NUM
#   Optional: Number of PR to test. If empty, tests the default branch.
# SYSTEM_ROLES_ONLY_TESTS
#  Optional: Space separated names of test playbooks to test. E.g. "tests_imuxsock_files.yml tests_relp.yml"
#  If empty, tests all tests in tests/tests_*.yml

rolesInstallAnsible() {
    local ansible_pkg
    local pkg_cmd
    if rlIsFedora || (rlIsRHELLike ">=8.6" && [ "$ANSIBLE_VER" != "2.9" ]); then
        pkg_cmd="dnf"
        ansible_pkg="ansible-core"
    elif rlIsRHELLike 8; then
        pkg_cmd="dnf"
        ansible_pkg="ansible-2.9"
    else
        # el7
        pkg_cmd="yum"
        ansible_pkg="ansible"
        rlRun "$pkg_cmd install epel-release -y"
    fi
    rlRun "$pkg_cmd install $ansible_pkg -y"
    rlAssertRpm "$ansible_pkg"
}

rolesClonePR() {
    local role_path
    if [ ! -d "$REPO_NAME" ]; then
        rlRun "git clone https://github.com/linux-system-roles/$REPO_NAME.git"
    fi
    if [ -n "$PR_NUM" ]; then
        rlRun "pushd $REPO_NAME || exit"
        rlRun "git fetch origin pull/$PR_NUM/head:test_pr"
        rlRun "git checkout test_pr"
        rlRun "popd || exit"
    fi
    role_path="$PWD"/"$REPO_NAME"
    return "$role_path"
}

# Handle Ansible Vault encrypted variables
rolesHandleVault() {
    local role_path=$1
    local playbook_file=$2
    local vault_pwd_file="$role_path/vault_pwd"
    local vault_variables_file="$role_path/vars/vault-variables.yml"
    local no_vault_file="$role_path/no-vault-variables.txt"
    local vault_play

    if [ -f "$vault_pwd_file" ] && [ -f "$vault_variables_file" ]; then
        if grep -q "^${playbook_file}\$" "$no_vault_file"; then
            rlLogInfo "Skipping vault variables because $3/$2 is in no-vault-variables.txt"
        else
            rlLogInfo "Including vault variables in $playbook_file"
            vault_play="- hosts: all
  gather_facts: false
  tasks:
    - name: Include vault variables
      include_vars:
        file: $vault_variables_file"
            rlRun "sed -i \"s|---||$vault_play\" $playbook_file"
        fi
    else
        rlLogInfo "Skipping vault variables because $vault_pwd_file and $vault_variables_file don't exist"
    fi
}

rolesInstallDependencies() {
    local coll_req_file="$1/meta/collection-requirements.yml"
    local coll_test_req_file="$1/tests/collection-requirements.yml"
    for req_file in $coll_req_file $coll_test_req_file; do
        if [ ! -f "$req_file" ]; then
            rlLogInfo "Skipping installing dependencies from $req_file, this file doesn't exist"
        else
            rlRun "ansible-galaxy collection install -p $2 -vv -r $req_file"
            rlRun "export ANSIBLE_COLLECTIONS_PATHS=$2"
            rlLogInfo "Dependencies were successfully installed"
        fi
    done
}

rolesEnableCallbackPlugins() {
    # Enable callback plugins for prettier ansible output
    callback_path=ansible_collections/ansible/posix/plugins/callback
    if [ ! -f "$1"/"$callback_path"/debug.py ] || [ ! -f "$1"/"$callback_path"/profile_tasks.py ]; then
        ansible_posix=$(mktemp -d)
        rlRun "ansible-galaxy collection install ansible.posix -p $ansible_posix -vv"
        if [ ! -d "$1"/"$callback_path"/ ]; then
            rlRun "mkdir -p $1/$callback_path"
        fi
        rlRun "cp $ansible_posix/$callback_path/{debug.py,profile_tasks.py} $1/$callback_path/"
        rlRun "rm -rf $ansible_posix"
    fi
    rlRun "ansible-config list | grep 'name: ANSIBLE_CALLBACKS_ENABLED'"
    if ansible-config list | grep -q "name: ANSIBLE_CALLBACKS_ENABLED"; then
        rlRun "export ANSIBLE_CALLBACKS_ENABLED=profile_tasks"
    else
        rlRun "export ANSIBLE_CALLBACK_WHITELIST=profile_tasks"
    fi
    rlRun "export ANSIBLE_STDOUT_CALLBACK=debug"
}

rolesConvertToCollection() {
    local role_path=$1
    local collection_path=$2
    local collection_script_url=https://raw.githubusercontent.com/linux-system-roles/auto-maintenance/main
    local coll_namespace=fedora
    local coll_name=linux_system_roles
    local subrole_prefix=private_"$REPO_NAME"_subrole_
    rlRun "curl -L -o $role_path/lsr_role2collection.py $collection_script_url/lsr_role2collection.py"
    rlRun "curl -L -o $role_path/runtime.yml $collection_script_url/lsr_role2collection/runtime.yml"
    # Remove role that was installed as a dependencie
    rlRun "rm -rf $collection_path/ansible_collections/fedora/linux_system_roles/roles/$REPO_NAME"
    rlRun "python -m pip install ruamel.yaml"
    rlRun "python $role_path/lsr_role2collection.py \
        --src-owner linux-system-roles \
        --role $REPO_NAME \
        --src-path $role_path \
        --dest-path $collection_path \
        --namespace $coll_namespace \
        --collection $coll_name \
        --subrole-prefix $subrole_prefix \
        --meta-runtime $role_path/runtime.yml"
}

rolesBuildInventory() {
    local inventory=$1
    local hostname=$2
    declare -n host_params=$1
    if [ ! -f "$inventory" ]; then
    echo "---
all:
  hosts:" > "$inventory"
    fi
    echo "    $hostname:" >> "$inventory"
    for key in "${!host_params[@]}"; do
        echo "      ${key}: ${host_params[${key}]}" >> "$inventory"
    done
    rlRun "cat $inventory"
}

rlJournalStart
    rlPhaseStartSetup
        rlRun "find / -name 'guests.yml'"
        rlRun "pwd"
        rlRun "echo $TMT_TREE"
        rlRun "ls $TMT_TREE"
        rlRun "echo $TMT_TOPOLOGY_YAML"
        rlRun "echo $TMT_TOPOLOGY_BASH"
        rlRun "awk 'BEGIN{for(v in ENVIRON) print v}'"
        # Reading topology from guests.yml for compatibility with tmt try
        guests_yml=${tmt_tree_provision}/guests.yaml

        rlRun "set -o pipefail"
        required_vars=("ANSIBLE_VER" "REPO_NAME")
        for required_var in "${required_vars[@]}"; do
            if [ -z "${!required_var}" ]; then
                rlDie "This required variable is unset: $required_var "
            fi
        done
        if [ -n "$ANSIBLE_VER" ]; then
            rolesInstallAnsible
        else
            rlLogInfo "ANSIBLE_VER not defined - using system ansible if installed"
        fi
        rolesClonePR
        role_path="$PWD"/"$REPO_NAME"
        for test_playbook in "$role_path"/tests/tests_*.yml; do
            rolesHandleVault "$role_path" "$test_playbook"
        done
        collection_path=$(mktemp -d)
        rolesInstallDependencies "$role_path" "$collection_path"
        rolesEnableCallbackPlugins "$collection_path"
        rolesConvertToCollection "$role_path" "$collection_path"
        inventory="$role_path/inventory.yml"
        hostname=managed_node
        tmt_tree_provision=${TMT_TREE%/*}/provision
        # TMT_TOPOLOGY_ variables are not available in tmt try.
        # Reading topology from guests.yml for compatibility with tmt try
        guests_yml=${tmt_tree_provision}/guests.yaml
        declare -A host_params
        host_params[ansible_port]=$(< "$guests_yml" yq '.managed_node.port' )
        host_params[ansible_host]=$(< "$guests_yml" yq '.managed_node.topology-address')
        host_params[ansible_ssh_private_key_file]="${tmt_tree_provision}/control_node/id_ecdsa"
        host_params[ansible_ssh_extra_args]="-o StrictHostKeyChecking=no"
        rolesBuildInventory "$inventory" "$hostname" host_params
    rlPhaseEnd

    rlPhaseStartTest
        tests_path="$collection_path"/ansible_collections/fedora/linux_system_roles/tests/"$REPO_NAME"/
        test_playbooks=$(find "$tests_path" -maxdepth 1 -type f -name "tests_*.yml" -printf '%f\n')
        for test_playbook in $test_playbooks; do
            if [ -n "$SYSTEM_ROLES_ONLY_TESTS" ]; then
                if echo "$SYSTEM_ROLES_ONLY_TESTS" | grep -q "$test_playbook"; then
                    rlRun "ansible-playbook -i $inventory $tests_path$test_playbook -v"
                fi
            else
                rlRun "ansible-playbook -i $inventory $tests_path$test_playbook -v"
            fi
        done
    rlPhaseEnd

    rlPhaseStartCleanup
        rlRun "rm -r $collection_path" 0 "Remove tmp directory"
        rlRun "rm -r $role_path" 0 "Remove role directory"
    rlPhaseEnd
rlJournalEnd
