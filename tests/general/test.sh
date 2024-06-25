#!/bin/bash

. /usr/share/beakerlib/beakerlib.sh || exit 1

# Test parameters:
# ANSIBLE_VER
#   ansible version to use for tests. E.g. "2.9" or "2.16".
#
# REPO_NAME
#   Name of the role repository to test.
#
# PR_NUM
#   Optional: Number of PR to test. If empty, tests the default branch.
#
# SYSTEM_ROLES_ONLY_TESTS
#  Optional: Space separated names of test playbooks to test. E.g. "tests_imuxsock_files.yml tests_relp.yml"
#  If empty, tests all tests in tests/tests_*.yml
#
# SYSTEM_ROLES_EXCLUDE_TESTS
#   Optiona: Space separated names of test playbooks to exclude from test.
#
# PYTHON_VERSION
# Python version to install ansible-core with.
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"

rolesInstallAnsible() {
    if rlIsFedora || (rlIsRHELLike ">=8.6" && [ "$ANSIBLE_VER" != "2.9" ]); then
        rlRun "dnf install python$PYTHON_VERSION-pip -y"
        rlRun "python$PYTHON_VERSION -m pip install ansible-core==$ANSIBLE_VER.*"
    elif rlIsRHELLike 8; then
        rlRun "dnf install python$PYTHON_VERSION-pip -y"
        rlRun "python$PYTHON_VERSION -m pip install ansible==$ANSIBLE_VER.*"
    else
        # el7
        rlRun "yum install ansible-$ANSIBLE_VER -y"
    fi
}

rolesCloneRepo() {
    local role_path=$1
    if [ ! -d "$REPO_NAME" ]; then
        rlRun "git clone https://github.com/linux-system-roles/$REPO_NAME.git $role_path"
    fi
    if [ -n "$PR_NUM" ]; then
        rlRun "pushd $role_path || exit"
        rlRun "git fetch origin pull/$PR_NUM/head:test_pr"
        rlRun "git checkout test_pr"
        rlRun "popd || exit"
    fi
}

rolesGetTests() {
    local role_path=$1
    local test_playbooks_all test_playbooks
    tests_path="$role_path"/tests/
    test_playbooks_all=$(find "$tests_path" -maxdepth 1 -type f -name "tests_*.yml" -printf '%f\n')
    if [ -n "$SYSTEM_ROLES_ONLY_TESTS" ]; then
        for test_playbook in $test_playbooks_all; do
            if echo "$SYSTEM_ROLES_ONLY_TESTS" | grep -q "$test_playbook"; then
                test_playbooks="$test_playbooks $test_playbook"
            fi
        done
    else
        test_playbooks="$test_playbooks_all"
    fi
    if [ -n "$SYSTEM_ROLES_EXCLUDE_TESTS" ]; then
        test_playbooks_excludes=""
        for test_playbook in $test_playbooks; do
            if ! echo "$SYSTEM_ROLES_EXCLUDE_TESTS" | grep -q "$test_playbook"; then
                test_playbooks_excludes="$test_playbooks_excludes $test_playbook"
            fi
        done
        test_playbooks=$test_playbooks_excludes
    fi
    echo "$test_playbooks"
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
    local collection_path=$1
    # Enable callback plugins for prettier ansible output
    callback_path=ansible_collections/ansible/posix/plugins/callback
    if [ ! -f "$collection_path"/"$callback_path"/debug.py ] || [ ! -f "$collection_path"/"$callback_path"/profile_tasks.py ]; then
        ansible_posix=$(TMPDIR=$TMT_TREE mktemp --directory)
        rlRun "ansible-galaxy collection install ansible.posix -p $ansible_posix -vv"
        if [ ! -d "$1"/"$callback_path"/ ]; then
            rlRun "mkdir -p $collection_path/$callback_path"
        fi
        rlRun "cp $ansible_posix/$callback_path/{debug.py,profile_tasks.py} $collection_path/$callback_path/"
        rlRun "rm -rf $ansible_posix"
    fi
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
    rlRun "curl -L -o $TMT_TREE/lsr_role2collection.py $collection_script_url/lsr_role2collection.py"
    rlRun "curl -L -o $TMT_TREE/runtime.yml $collection_script_url/lsr_role2collection/runtime.yml"
    # Remove role that was installed as a dependencie
    rlRun "rm -rf $collection_path/ansible_collections/fedora/linux_system_roles/roles/$REPO_NAME"
    if rlIsFedora || rlIsRHELLike ">7"; then
        dnf install python3-ruamel-yaml -y
    # el 7: python36-ruamel-yaml RPM ships ancient ruamel-yaml version that doesn't have YAML class
    else
        rlRun "yum install python3-pip -y"
        rlRun "python3 -m pip install ruamel-yaml"
    fi
    # Remove symlinks
    rlRun "find $role_path -type l -exec rm {} \;"
    rlRun "python3 $TMT_TREE/lsr_role2collection.py \
--meta-runtime $TMT_TREE/runtime.yml \
--src-owner linux-system-roles \
--role $REPO_NAME \
--src-path $role_path \
--dest-path $collection_path \
--namespace $coll_namespace \
--collection $coll_name \
--subrole-prefix $subrole_prefix"
}

rolesPrepareInventoryVars() {
    local role_path=$1
    local inventory hostname tmt_tree_provision is_virtual guests_yml host_params
    inventory="$role_path/inventory.yml"
    hostname=managed_node
    # TMT_TOPOLOGY_ variables are not available in tmt try.
    # Reading topology from guests.yml for compatibility with tmt try
    tmt_tree_provision=${TMT_TREE%/*}/provision
    guests_yml=${tmt_tree_provision}/guests.yaml
    is_virtual=$(rolesIsVirtual "$tmt_tree_provision")
    declare -A host_params
    if head "$guests_yml" | grep -q 'managed_node:'; then
        host_params[ansible_host]=$(< "$guests_yml" grep -oP -m 1 'topology-address: \K(.*)')
    else
        host_params[ansible_host]=$(< "$guests_yml" grep -oP -m 2 'topology-address: \K(.*)' | tail -1)
    fi
    if [ "$is_virtual" -eq 0 ]; then
        host_params[ansible_ssh_private_key_file]="${tmt_tree_provision}/control_node/id_ecdsa"
    fi
    host_params[ansible_ssh_extra_args]="-o StrictHostKeyChecking=no"
    if [ ! -f "$inventory" ]; then
        echo "---
all:
  hosts:" > "$inventory"
    fi
    echo "    $hostname:" >> "$inventory"
    for key in "${!host_params[@]}"; do
        echo "      ${key}: ${host_params[${key}]}" >> "$inventory"
    done
    rlRun "echo $inventory"
}

# This function can be used to build inventory for multihost scenarios
rolesBuildInventory() {
    local inventory=$1
    local hostname=$2
    declare -n host_params=$3
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

rolesIsVirtual() {
    # Returns 0 if provisioned with "how: virtual"
    local tmt_tree_provision=$1
    grep -q 'how: virtual' "$tmt_tree_provision"/step.yaml
    echo $?
}

rolesRunPlaybook() {
    local tests_path=$1
    local test_playbook=$2
    local inventory=$3
    LOGFILE="${test_playbook%.*}"-ANSIBLE-"$ANSIBLE_VER".log
    rlRun "ANSIBLE_LOG_PATH=$LOGFILE ansible-playbook -i $inventory $tests_path$test_playbook -v" 0 "Test $test_playbook with ANSIBLE-$ANSIBLE_VER"
    rlFileSubmit "$LOGFILE"
}

rlJournalStart
    rlPhaseStartSetup
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
        role_path=$TMT_TREE/$REPO_NAME
        rolesCloneRepo "$role_path"
        test_playbooks=$(rolesGetTests "$role_path")
        rlLogInfo "Test playbooks: $test_playbooks"
        for test_playbook in $test_playbooks; do
            rolesHandleVault "$role_path" "$test_playbook"
        done
        rlRun "collection_path=$(TMPDIR=$TMT_TREE mktemp --directory)"
        rolesInstallDependencies "$role_path" "$collection_path"
        rolesEnableCallbackPlugins "$collection_path"
        rolesConvertToCollection "$role_path" "$collection_path"
        inventory=$(rolesPrepareInventoryVars "$role_path")
        rlRun "cat $inventory"
    rlPhaseEnd

    rlPhaseStartTest
        tests_path="$collection_path"/ansible_collections/fedora/linux_system_roles/tests/"$REPO_NAME"/
        for test_playbook in $test_playbooks; do
            rolesRunPlaybook "$tests_path" "$test_playbook" "$inventory"
        done
    rlPhaseEnd

    rlPhaseStartCleanup
        rlRun "rm -r $collection_path" 0 "Remove tmp directory"
        rlRun "rm -r $role_path" 0 "Remove role directory"
    rlPhaseEnd
rlJournalEnd
