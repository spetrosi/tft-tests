#!/bin/bash
# vim: dict=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Description: Library for system roles tests
#   Author: Sergei Petrosian <spetrosi@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   library-prefix = library
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

rolesPrepTMTVars() {
    tmt_tree_provision=${TMT_TREE%/*}/provision
    guests_yml=${tmt_tree_provision}/guests.yaml
}

rolesInstallAnsible() {
    # Hardcode to the only supported version on later ELs
    if rlIsRHELLike 8 && [ "$ANSIBLE_VER" == "2.9" ]; then
        PYTHON_VERSION=3.9
    elif rlIsRHELLike 8 && [ "$ANSIBLE_VER" != "2.9" ]; then
        # CentOS-8 supports either 2.9 or 2.16
        ANSIBLE_VER=2.16
    elif rlIsRHELLike 7; then
        PYTHON_VERSION=3
        ANSIBLE_VER=2.9
    fi

    if rlIsFedora || (rlIsRHELLike ">7" && [ "$ANSIBLE_VER" != "2.9" ]); then
        rlRun "dnf install python$PYTHON_VERSION-pip -y"
        rlRun "python$PYTHON_VERSION -m pip install ansible-core==$ANSIBLE_VER.* passlib"
    elif rlIsRHELLike 8; then
        # el8 ansible-2.9
        rlRun "dnf install python$PYTHON_VERSION -y"
        # selinux needed for delegate_to: localhost for file, copy, etc.
        # Providing passlib for password_hash module, see https://issues.redhat.com/browse/SYSROLES-81
        rlRun "python$PYTHON_VERSION -m pip install ansible==$ANSIBLE_VER.* selinux passlib"
    else
        # el7
        rlRun "yum install python$PYTHON_VERSION-pip ansible-$ANSIBLE_VER.* -y"
    fi
}

rolesCloneRepo() {
    local role_path=$1
    rlRun "git clone -q https://github.com/$GITHUB_ORG/$REPO_NAME.git $role_path --depth 1"
    if [ -n "$PR_NUM" ]; then
        # git on EL7 doesn't support -C option
        pushd "$role_path" || exit
        rlRun "git fetch origin pull/$PR_NUM/head"
        rlRun "git checkout FETCH_HEAD"
        popd || exit
        rlLog "Test from the pull request $PR_NUM"
    else
        rlLog "Test from the main branch"
    fi
}

rolesGetRoleDir() {
    if [ "$TEST_LOCAL_CHANGES" == true ] || [ "$TEST_LOCAL_CHANGES" == True ]; then
        rlLog "Test from local changes"
        role_path="$TMT_TREE"
    else
        role_path=$(mktemp --directory -t "$REPO_NAME"-XXX)
        rolesCloneRepo "$role_path"
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
    if [ -z "$test_playbooks" ]; then
        rlDie "No test playbooks found"
    fi
    echo "$test_playbooks"
}

# Handle Ansible Vault encrypted variables
rolesHandleVault() {
    local role_path=$1
    local playbook_file=$role_path/tests/$2
    local vault_pwd_file=$role_path/tests/vault_pwd
    local vault_variables_file=$role_path/tests/vars/vault-variables.yml
    local no_vault_file=$role_path/tests/no-vault-variables.txt
    local vault_play

    if [ ! -f "$vault_pwd_file" ] || [ ! -f "$vault_variables_file" ]; then
        rlLogInfo "Skipping vault variables because $vault_pwd_file and $vault_variables_file don't exist"
        return
    fi
    if [ -f "$no_vault_file" ]; then
        playbook_file_bsn=$(basename "$playbook_file")
        if grep -q "^${playbook_file_bsn}\$" "$no_vault_file"; then
            rlLogInfo "Skipping vault variables because $playbook_file_bsn is in no-vault-variables.txt"
            return
        fi
    fi
    rlLogInfo "Including vault variables in $playbook_file"
    export ANSIBLE_VAULT_PASSWORD_FILE="$vault_pwd_file"
    vault_play="---
- hosts: all
  gather_facts: false
  tasks:
    - name: Include vault variables
      include_vars:
        file: $vault_variables_file"
    sed -i "/---/d" "$playbook_file"
    cat <<< "$vault_play
$(cat "$playbook_file")" > "$playbook_file".tmp
    mv "$playbook_file".tmp "$playbook_file"
}

rolesIsAnsibleEnvVarSupported() {
    # Return 0 if supported, 1 if not supported
    local env_var_name=$1
    ansible-config list | grep -q "name: $env_var_name$"
}

rolesIsAnsibleCmdOptionSupported() {
    # Return 0 if supported, 1 if not supported
    local cmd=$1
    local option=$2
    $cmd --help | grep -q -e "$option"
}

rolesInstallDependencies() {
    local role_path=$1
    local collection_path=$2
    local coll_req_file="$1/meta/collection-requirements.yml"
    local coll_test_req_file="$1/tests/collection-requirements.yml"
    for req_file in $coll_req_file $coll_test_req_file; do
        if [ ! -f "$req_file" ]; then
            rlLogInfo "Skipping installing dependencies from $req_file, this file doesn't exist"
        else
            rlRun "ansible-galaxy collection install -p $collection_path -vv -r $req_file"
            if rolesIsAnsibleEnvVarSupported ANSIBLE_COLLECTION_PATH; then
                rlRun "export ANSIBLE_COLLECTIONS_PATH=$collection_path"
            else
                rlRun "export ANSIBLE_COLLECTIONS_PATHS=$collection_path"
            fi
            rlLogInfo "$req_file Dependencies were successfully installed"
        fi
    done
}

rolesEnableCallbackPlugins() {
    local collection_path=$1
    local cmd
    # Enable callback plugins for prettier ansible output
    callback_path=ansible_collections/ansible/posix/plugins/callback
    if [ ! -f "$collection_path"/"$callback_path"/debug.py ] || [ ! -f "$collection_path"/"$callback_path"/profile_tasks.py ]; then
        ansible_posix=$(mktemp --directory -t ansible_posix-XXX)
        cmd="ansible-galaxy collection install ansible.posix -p $ansible_posix -vv"
        if rolesIsAnsibleCmdOptionSupported "ansible-galaxy collection install" "--force-with-deps"; then
            rlRun "$cmd --force-with-deps"
        elif rolesIsAnsibleCmdOptionSupported "ansible-galaxy collection install" "--force"; then
            rlRun "$cmd --force"
        else
            rlRun "$cmd"
        fi
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
    local tmpdir=/tmp/lsr_role2collection
    local lsr_role2collection=$tmpdir/lsr_role2collection.py
    local runtime=$tmpdir/runtime.yml
    if [ ! -d "$tmpdir" ]; then
        mkdir -p "$tmpdir"
    fi
    if [ ! -f "$lsr_role2collection" ]; then
        rlRun "curl -L -o $lsr_role2collection $collection_script_url/lsr_role2collection.py"
    fi
    if [ ! -f "$runtime" ]; then
        rlRun "curl -L -o $runtime $collection_script_url/lsr_role2collection/runtime.yml"
    fi
    # Remove role that was installed as a dependencie
    rlRun "rm -rf $collection_path/ansible_collections/fedora/linux_system_roles/roles/$REPO_NAME"
    rlRun "python$PYTHON_VERSION -m pip install ruamel-yaml"
    # Remove symlinks in tests/roles
    if [ -d "$role_path"/tests/roles ]; then
        find "$role_path"/tests/roles -type l -exec rm {} \;
        if [ -d "$role_path"/tests/roles/linux-system-roles."$REPO_NAME" ]; then
            rlRun "rm -r $role_path/tests/roles/linux-system-roles.$REPO_NAME"
        fi
    fi
    rlRun "python$PYTHON_VERSION $lsr_role2collection \
--meta-runtime $runtime \
--src-owner linux-system-roles \
--role $REPO_NAME \
--src-path $role_path \
--dest-path $collection_path \
--namespace $coll_namespace \
--collection $coll_name \
--subrole-prefix $subrole_prefix"
}

rolesGetManagedNodes() {
    local guests_yml=$1
    grep -P -o '^managed_node(\d+)?' "$guests_yml" | sort
}

rolesPrepareInventoryVars() {
    local role_path=$1
    local tmt_tree_provision=$2
    local guests_yml=$3
    local inventory is_virtual  managed_nodes
    inventory="$role_path/inventory.yml"
    # TMT_TOPOLOGY_ variables are not available in tmt try.
    # Reading topology from guests.yml for compatibility with tmt try
    is_virtual=$(rolesIsVirtual "$tmt_tree_provision")
    managed_nodes=$(rolesGetManagedNodes "$guests_yml")
    rlRun "python$PYTHON_VERSION -m pip install yq -q"
    if [ ! -f "$inventory" ]; then
        echo "---
all:
  hosts:" > "$inventory"
    fi
    for managed_node in $managed_nodes; do
        ip_addr=$(yq ".$managed_node.\"primary-address\"" "$guests_yml")
        {
        echo "    $managed_node:"
        echo "      ansible_host: $ip_addr"
        echo "      ansible_ssh_extra_args: \"-o StrictHostKeyChecking=no\""
        } >> "$inventory"
        if [ "$is_virtual" -eq 0 ]; then
            echo "      ansible_ssh_private_key_file: ${tmt_tree_provision}/control_node/id_ecdsa" >> "$inventory"
        fi
    done
    rlRun "echo $inventory"
}

rolesIsVirtual() {
    # Returns 0 if provisioned with "how: virtual"
    local tmt_tree_provision=$1
    grep -q 'how: virtual' "$tmt_tree_provision"/step.yaml
    echo $?
}

rolesUploadLogs() {
    local logfile=$1
    local guests_yml=$2
    local id_rsa_path pr_substr os artifact_dirname target_dir
    if [ -z "$LINUXSYSTEMROLES_SSH_KEY" ]; then
        rlFileSubmit "$logfile"
        return
    fi
    id_rsa_path="$role_path/id_rsa"
    echo "$LINUXSYSTEMROLES_SSH_KEY" | \
        sed -e 's|-----BEGIN OPENSSH PRIVATE KEY----- |-----BEGIN OPENSSH PRIVATE KEY-----\n|' \
        -e 's| -----END OPENSSH PRIVATE KEY-----|\n-----END OPENSSH PRIVATE KEY-----|' > "$id_rsa_path" # notsecret
    chmod 600 "$id_rsa_path"
    if [ -z "$ARTIFACTS_DIR" ]; then
        os=$(yq '.control_node.facts."os-release-content".CENTOS_MANTISBT_PROJECT' "$guests_yml" | tr -d '""')
        printf -v date '%(%Y%m%d-%H%M%S)T' -1
        if [ -z "$PR_NUM" ]; then
            pr_substr=_main
        else
            pr_substr=_$PR_NUM
        fi
        artifact_dirname=tmt-"$REPO_NAME""$pr_substr"_"$os"_"$date"/artifacts
        target_dir="/srv/pub/alt/linuxsystemroles/logs"
        ARTIFACTS_DIR="$target_dir"/"$artifact_dirname"
        ARTIFACTS_URL=https://dl.fedoraproject.org/pub/alt/linuxsystemroles/logs/$artifact_dirname/
    fi
    ssh -i "$id_rsa_path" -o StrictHostKeyChecking=no "$LINUXSYSTEMROLES_USER"@"$LINUXSYSTEMROLES_DOMAIN" mkdir -p "$ARTIFACTS_DIR"
    scp -i "$id_rsa_path" -o StrictHostKeyChecking=no "$logfile" "$LINUXSYSTEMROLES_USER"@"$LINUXSYSTEMROLES_DOMAIN":"$ARTIFACTS_DIR"/
    rlLogInfo "Logs are uploaded at $ARTIFACTS_URL"
}

rolesRunPlaybook() {
    local tests_path=$1
    local test_playbook=$2
    local inventory=$3
    local skip_tags=$4
    local limit=$5
    local LOGFILE="${test_playbook%.*}"-ANSIBLE-"$ANSIBLE_VER"
    local result=FAIL
    local cmd log_msg
    cmd="ansible-playbook -i $inventory $skip_tags $limit $tests_path$test_playbook -vv"
    log_msg="Test $test_playbook with ANSIBLE-$ANSIBLE_VER on ${limit/--limit /}"
    # If LSR_TFT_DEBUG is true, print output to terminal
    if [ "$LSR_TFT_DEBUG" == true ] || [ "$LSR_TFT_DEBUG" == True ]; then
        rlRun "ANSIBLE_LOG_PATH=$LOGFILE $cmd && result=SUCCESS" 0 "$log_msg"
    else
        rlRun "$cmd &> $LOGFILE && result=SUCCESS" 0 "$log_msg"
    fi
    logfile_name=$LOGFILE-$result.log
    mv "$LOGFILE" "$logfile_name"
    LOGFILE=$logfile_name
    rolesUploadLogs "$LOGFILE"
}

rolesRunPlaybooksParallel() {
    # Run playbooks on managed nodes one by one
    # Supports running against a single node too
    local tests_path=$1
    local inventory=$2
    local skip_tags=$3
    local test_playbooks=$4
    local managed_nodes=$5
    local test_playbooks_arr

    mapfile -t test_playbooks_arr <<< "$test_playbooks"
    while [[ -n "${test_playbooks_arr[*]}" ]]; do
        for managed_node in $managed_nodes; do
            if ! pgrep -af "ansible-playbook" | grep -q "\--limit $managed_node\s"; then
                test_playbook=${test_playbooks_arr[0]}
                test_playbooks_arr=("${test_playbooks_arr[@]:1}") # Remove first element from array
                rolesRunPlaybook "$tests_path" "$test_playbook" "$inventory" "$skip_tags" "--limit $managed_node" &
                sleep 1
                break
            fi
        done
        sleep 1
    done
    # Wait for the last test to finish
    while true; do
        if ! pgrep -af "ansible-playbook" | grep -q "$tests_path$test_playbook"; then
            break
        fi
        sleep 1
    done
}

rolesCS8InstallPython() {
    # Install python on managed node when running CS8 with ansible!=2.9
    if [ "$ANSIBLE_VER" != "2.9" ] && grep -q 'CentOS Stream release 8' /etc/redhat-release; then
        rlRun "dnf install -y python$PYTHON_VERSION"
    fi
}

rolesDistributeSSHKeys() {
    # name: Distribute SSH keys when provisioned with how=virtual
    local tmt_tree_provision=$1
    local control_node_id_ecdsa_pub=$tmt_tree_provision/control_node/id_ecdsa.pub
    if [ -f "$control_node_id_ecdsa_pub" ]; then
        rlRun "cat $control_node_id_ecdsa_pub >> ~/.ssh/authorized_keys"
    fi
}

rolesEnableHA() {
# This function enables the ha repository on platforms that require it and do not have it enabled by default
# The ha repository is required by the mssql and ha_cluster roles
    local ha_reponame
    if rlIsRHELLike 7; then
        return
    fi
    if rlIsRHELLike 8; then
        ha_reponame=ha
    elif rlIsRHELLike ">8"; then
        ha_reponame=highavailability
    fi
    if [ -n "$ha_reponame" ]; then
        rlRun "dnf config-manager --set-enabled $ha_reponame"
    fi
}

rolesDisableNFV() {
    # The nfv-source repo causes troubles in CentOS-9 Stream compose while system-roles testing
    if [ "$(find /etc/yum.repos.d/ -name 'centos-addons.repo' | wc -l )" -gt 0 ]; then
        rlRun "sed -i '/^\[nfv-source\]/,/^$/d' /etc/yum.repos.d/centos-addons.repo"
    fi
}

rolesGenerateTestDisks() {
# This function generates test disks from provision.fmf
# This is required by storage and snapshot roles
    local provisionfmf
    local -i i=0
    local disk_provisioner_dir TARGETCLI_CMD disks disk file
    rolesGetRoleDir
    provisionfmf="$role_path"/tests/provision.fmf
    if [ ! -f "$provisionfmf" ]; then
        rlRun "rm -rf ${role_path}"
        return
    fi
    if ! grep -q drive: "$provisionfmf"; then
        rlRun "rm -rf ${role_path}"
        return
    fi
    rlRun "yum install targetcli -y"
    disks=$(sed -rn 's/^\s*-?\s+size:\s+(.*)/\1/p' "$provisionfmf")
    # Nothing to do
    [ -z "$disks" ] && return

    # disk_provisioner needs at least 10GB - if /tmp does not have enough space, use /var/tmp
    if rolesCheckPartitionSize "/tmp" -gt 10485760; then
        disk_provisioner_dir=$(mktemp --directory --tmpdir=/tmp)
    else
        disk_provisioner_dir=$(mktemp --directory --tmpdir=/var/tmp)
    fi

    TARGETCLI_CMD="set global auto_cd_after_create=true
/loopback create
set global auto_cd_after_create=false"

    for disk in $disks; do
        file="${disk_provisioner_dir}/disk${i}"
        rlRun "truncate -s $disk $file"
		TARGETCLI_CMD="${TARGETCLI_CMD}
/backstores/fileio create disk${i} ${file}
luns/ create /backstores/fileio/disk${i}"
        ((++i))
    done
    targetcli <<< "$TARGETCLI_CMD"

    rlRun "rm -rf ${disk_provisioner_dir}"
    rlRun "rm -rf ${role_path}"
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Verification
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   This is a verification callback which will be called by
#   rlImport after sourcing the library to make sure everything is
#   all right. It makes sense to perform a basic sanity test and
#   check that all required packages are installed. The function
#   should return 0 only when the library is ready to serve.
#
#   This library does not do anything, it is only a list of functions, so simply returning 0
libraryLibraryLoaded() {
    rlLog "Library loaded!"
    return 0
}
