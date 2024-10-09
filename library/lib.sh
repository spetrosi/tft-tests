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

lsrPrepTestVars() {
    tmt_tree_parent=${TMT_TREE%/*}
    tmt_plan=$(basename "$tmt_tree_parent")
    tmt_tree_provision=$tmt_tree_parent/provision
    guests_yml=${tmt_tree_provision}/guests.yaml
    declare -gA ANSIBLE_ENVS
}

lsrLabBosRepoWorkaround() {
    sed -i 's|\.lab\.bos.|.devel.|g' /etc/yum.repos.d/*.repo
}

lsrInstallAnsible() {
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

lsrCloneRepo() {
    local role_path=$1
    local repo_name=$2
    rlRun "git clone -q https://github.com/$GITHUB_ORG/$repo_name.git $role_path --depth 1"
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

lsrGetRoleDir() {
    local repo_name=$1
    if [ "$TEST_LOCAL_CHANGES" == true ] || [ "$TEST_LOCAL_CHANGES" == True ]; then
        rlLog "Test from local changes"
        role_path="$TMT_TREE"
    else
        role_path=$(mktemp --directory -t "$repo_name"-XXX)
        lsrCloneRepo "$role_path" "$repo_name"
    fi
}

lsrGetTests() {
    local tests_path=$1
    local test_playbooks_all test_playbooks
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
    # Convert to a space-separated str, a format that users provide in env vars
    echo "$test_playbooks" | xargs
}

# Handle Ansible Vault encrypted variables
lsrHandleVault() {
    local playbook_file=$1
    local tests_path
    tests_path=$(dirname "$playbook_file")
    local vault_pwd_file=$tests_path/vault_pwd
    local vault_variables_file=$tests_path/vars/vault-variables.yml
    local no_vault_file=$tests_path/no-vault-variables.txt
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
    if [ -z "${ANSIBLE_ENVS[ANSIBLE_VAULT_PASSWORD_FILE]}" ]; then
        ANSIBLE_ENVS[ANSIBLE_VAULT_PASSWORD_FILE]="$vault_pwd_file"
    fi
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

lsrIsAnsibleEnvVarSupported() {
    # Return 0 if supported, 1 if not supported
    local env_var_name=$1
    ansible-config list | grep -q "name: $env_var_name$"
}

lsrIsAnsibleCmdOptionSupported() {
    # Return 0 if supported, 1 if not supported
    local cmd=$1
    local option=$2
    $cmd --help | grep -q -e "$option"
}

lsrGetCollectionPath() {
    collection_path=$(mktemp --directory -t collections-XXX)
    if lsrIsAnsibleEnvVarSupported ANSIBLE_COLLECTIONS_PATH; then
        ANSIBLE_ENVS[ANSIBLE_COLLECTIONS_PATH]="$collection_path"
    else
        ANSIBLE_ENVS[ANSIBLE_COLLECTIONS_PATHS]="$collection_path"
    fi
}

lsrInstallDependencies() {
    local role_path=$1
    local collection_path=$2
    local coll_req_file="$1/meta/collection-requirements.yml"
    local coll_test_req_file="$1/tests/collection-requirements.yml"
    for req_file in $coll_req_file $coll_test_req_file; do
        if [ ! -f "$req_file" ]; then
            rlLogInfo "Skipping installing dependencies from $req_file, this file doesn't exist"
            continue
        fi
        rlRun "ansible-galaxy collection install -p $collection_path -vv -r $req_file"
        rlLogInfo "$req_file Dependencies were successfully installed"
    done
}

lsrEnableCallbackPlugins() {
    local collection_path=$1
    local cmd
    # Enable callback plugins for prettier ansible output
    callback_path=ansible_collections/ansible/posix/plugins/callback
    if [ ! -f "$collection_path"/"$callback_path"/debug.py ] || [ ! -f "$collection_path"/"$callback_path"/profile_tasks.py ]; then
        ansible_posix=$(mktemp --directory -t ansible_posix-XXX)
        cmd="ansible-galaxy collection install ansible.posix -p $ansible_posix -vv"
        if lsrIsAnsibleCmdOptionSupported "ansible-galaxy collection install" "--force-with-deps"; then
            rlRun "$cmd --force-with-deps"
        elif lsrIsAnsibleCmdOptionSupported "ansible-galaxy collection install" "--force"; then
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
    if lsrIsAnsibleEnvVarSupported ANSIBLE_CALLBACKS_ENABLED; then
        ANSIBLE_ENVS[ANSIBLE_CALLBACKS_ENABLED]="profile_tasks"
    else
        ANSIBLE_ENVS[ANSIBLE_CALLBACK_WHITELIST]="profile_tasks"
    fi
    ANSIBLE_ENVS[ANSIBLE_STDOUT_CALLBACK]="debug"
}

lsrConvertToCollection() {
    local role_path=$1
    local collection_path=$2
    local role_name=$3
    local collection_script_url=https://raw.githubusercontent.com/linux-system-roles/auto-maintenance/main
    local coll_namespace=fedora
    local coll_name=linux_system_roles
    local subrole_prefix=private_"$role_name"_subrole_
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
    # Remove role that was installed as a dependency
    rlRun "rm -rf $collection_path/ansible_collections/fedora/linux_system_roles/roles/$role_name"
    # Remove performancecopilot vendored by metrics. It will be generated during a conversion to collection.
    if [ "$role_name" = "metrics" ]; then
        rlRun "rm -rf $collection_path/ansible_collections/fedora/linux_system_roles/vendor/github.com/performancecopilot/ansible-pcp"
    fi
    rlRun "python$PYTHON_VERSION -m pip install ruamel-yaml"
    # Remove symlinks in tests/roles
    if [ -d "$role_path"/tests/roles ]; then
        find "$role_path"/tests/roles -type l -exec rm {} \;
        if [ -d "$role_path"/tests/roles/linux-system-roles."$role_name" ]; then
            rlRun "rm -r $role_path/tests/roles/linux-system-roles.$role_name"
        fi
    fi
    rlRun "python$PYTHON_VERSION $lsr_role2collection \
--meta-runtime $runtime \
--src-owner linux-system-roles \
--role $role_name \
--src-path $role_path \
--dest-path $collection_path \
--namespace $coll_namespace \
--collection $coll_name \
--subrole-prefix $subrole_prefix"
}

lsrGetManagedNodes() {
    local guests_yml=$1
    sed --quiet --regexp-extended 's/(^managed.*):$/\1/p' "$guests_yml" | sort
}

lsrGetNodes() {
    local guests_yml=$1
    sed --quiet --regexp-extended 's/(^[^ ]*):$/\1/p' "$guests_yml" | sort
}

lsrGetNodeName() {
    local guests_yml=$1
    local node_pat=$2
    sed --quiet --regexp-extended "s/(^$node_pat.*):$/\1/p" "$guests_yml"
}

lsrGetCurrNodeHostname() {
    local guests_yml=$1
    local ip_addr
    ip_addr=$(hostname -I | awk '{print $1}')
    grep "primary-address: $ip_addr" "$guests_yml" -B 10 | sed --quiet --regexp-extended 's/(^[^ ]*):$/\1/p'
}

lsrGetNodeIp() {
    local guests_yml=$1
    local node=$2
    # awk '$1=$1' to remove extra spaces
    sed --quiet "/^$node:$/,/^[^ ]/p" "$guests_yml"  | sed --quiet --regexp-extended 's/primary-address: (.*)/\1/p' | awk '$1=$1'
}

lsrGetNodeOs() {
    local guests_yml=$1
    local node=$2
    sed --quiet "/^$node:$/,/^[^ ]/p" "$guests_yml" | sed --quiet --regexp-extended 's/distro: (.*)/\1/p' | awk '$1=$1'
}

lsrGetNodeKeyPrivate() {
    local guests_yml=$1
    local node=$2
    # Key is a list containing SSH keys, the first key is private
    sed --quiet "/^$node:$/,/^[^ ]/p" "$guests_yml"  | grep 'key:' -A1 | tail -n1 | grep -o '/.*'
}

lsrGetNodeKeyPublic() {
    local guests_yml=$1
    local node=$2
    # Append .pub to the private key
    lsrGetNodeKeyPrivate "$guests_yml" "$node" | awk '{print $1".pub"}'
}

lsrPrepareInventoryVars() {
    local tmt_tree_provision=$1
    local guests_yml=$2
    local inventory is_virtual  managed_nodes
    inventory=$(mktemp -t inventory-XXX.yml)
    # TMT_TOPOLOGY_ variables are not available in tmt try.
    # Reading topology from guests.yml for compatibility with tmt try
    is_virtual=$(lsrIsVirtual "$tmt_tree_provision")
    managed_nodes=$(lsrGetManagedNodes "$guests_yml")
    control_node_name=$(lsrGetNodeName "$guests_yml" "control-node")
    echo "---
all:
  hosts:" > "$inventory"
    for managed_node in $managed_nodes; do
        ip_addr=$(lsrGetNodeIp "$guests_yml" "$managed_node")
        {
        echo "    $managed_node:"
        echo "      ansible_host: $ip_addr"
        echo "      ansible_ssh_extra_args: \"-o StrictHostKeyChecking=no\""
        } >> "$inventory"
        if [ "$is_virtual" -eq 0 ]; then
            echo "      ansible_ssh_private_key_file: ${tmt_tree_provision}/$control_node_name/id_ecdsa" >> "$inventory"
        fi
    done
    rlRun "echo $inventory"
}

lsrIsVirtual() {
    # Returns 0 if provisioned with "how: virtual"
    local tmt_tree_provision=$1
    grep -q 'how: virtual' "$tmt_tree_provision"/step.yaml
    echo $?
}

lsrUploadLogs() {
    local logfile=$1
    local guests_yml=$2
    local role_name=$3
    local id_rsa_path pr_substr os artifact_dirname target_dir
    rlFileSubmit "$logfile"
    if [ -z "$LINUXSYSTEMROLES_SSH_KEY" ]; then
        return
    fi
    id_rsa_path=$(mktemp -t id_rsa-XXXXX)
    echo "$LINUXSYSTEMROLES_SSH_KEY" | \
        sed -e 's|-----BEGIN OPENSSH PRIVATE KEY----- |-----BEGIN OPENSSH PRIVATE KEY-----\n|' \
        -e 's| -----END OPENSSH PRIVATE KEY-----|\n-----END OPENSSH PRIVATE KEY-----|' > "$id_rsa_path" # notsecret
    chmod 600 "$id_rsa_path"
    if [ -z "$ARTIFACTS_DIR" ]; then
        control_node_name=$(lsrGetNodeName "$guests_yml" "control-node")
        os=$(lsrGetNodeOs "$guests_yml" "$control_node_name")
        printf -v date '%(%Y%m%d-%H%M%S)T' -1
        if [ -z "$PR_NUM" ]; then
            pr_substr=_main
        else
            pr_substr=_$PR_NUM
        fi
        artifact_dirname=tmt-"$role_name""$pr_substr"_"$os"_"$date"/artifacts
        target_dir="/srv/pub/alt/linuxsystemroles/logs"
        ARTIFACTS_DIR="$target_dir"/"$artifact_dirname"
        ARTIFACTS_URL=https://dl.fedoraproject.org/pub/alt/linuxsystemroles/logs/$artifact_dirname/
    fi
    rlRun "ssh -i $id_rsa_path -o StrictHostKeyChecking=no $LINUXSYSTEMROLES_USER@$LINUXSYSTEMROLES_DOMAIN mkdir -p $ARTIFACTS_DIR"
    chmod +r "$guests_yml"
    rlRun "scp -i $id_rsa_path -o StrictHostKeyChecking=no $logfile $guests_yml $LINUXSYSTEMROLES_USER@$LINUXSYSTEMROLES_DOMAIN:$ARTIFACTS_DIR/"
    rlLogInfo "Logs are uploaded at $ARTIFACTS_URL"
    rlRun "rm $id_rsa_path"
}

lsrArrtoStr() {
    local keys values key value
    local arr_name=$1
    # Convert associative array into a space separated key=value list
    eval "keys=(\${!$arr_name[@]})"
    eval "values=(\${$arr_name[@]})"
    for i in $(seq 0 $((${#keys[@]} - 1))); do
        key="${keys[$i]}"
        value="${values[$i]}"
        printf "%s=%s " "$key" "$value"
    done
    echo
}

lsrRunPlaybook() {
    local tests_path=$1
    local test_playbook=$2
    local inventory=$3
    local skip_tags=$4
    local limit=$5
    local LOGFILE=$6
    local role_name=$7
    local result=FAIL
    local cmd log_msg
    local ans_debug=""
    if [ "${GET_PYTHON_MODULES:-}" = true ]; then
        ans_debug="ANSIBLE_DEBUG=true"
    fi
    cmd="$(lsrArrtoStr ANSIBLE_ENVS) $ans_debug ansible-playbook -i $inventory $skip_tags $limit $tests_path$test_playbook -vv"
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
    lsrUploadLogs "$LOGFILE" "$guests_yml" "$role_name"
    if [ "${GET_PYTHON_MODULES:-}" = true ]; then
        cmd="$(lsrArrtoStr ANSIBLE_ENVS) ansible-playbook -i $inventory $skip_tags $limit process_python_modules_packages.yml -vv"
        local packages="$LOGFILE.packages"
        rlRun "$cmd -e packages_file=$packages -e logfile=$LOGFILE &> $LOGFILE.modules" 0 "process python modules"
        lsrUploadLogs "$LOGFILE.modules" "$guests_yml" "$role_name"
        lsrUploadLogs "$packages" "$guests_yml" "$role_name"
    fi
}

lsrRunPlaybooksParallel() {
    # Run playbooks on managed nodes one by one
    # Supports running against a single node too
    local tests_path=$1
    local inventory=$2
    local skip_tags=$3
    local test_playbooks=$4
    local managed_nodes=$5
    local role_name=$6
    local test_playbooks_arr

    read -ra test_playbooks_arr <<< "$test_playbooks"
    while [ "${#test_playbooks_arr[*]}" -gt 0 ]; do
        for managed_node in $managed_nodes; do
            if ! pgrep -af "ansible-playbook" | grep -q "\--limit $managed_node\s"; then
                test_playbook=${test_playbooks_arr[0]}
                test_playbooks_arr=("${test_playbooks_arr[@]:1}") # Remove first element from array
                LOGFILE="${test_playbook%.*}"-ANSIBLE-"$ANSIBLE_VER"-$tmt_plan
                lsrRunPlaybook "$tests_path" "$test_playbook" "$inventory" "$skip_tags" "--limit $managed_node" "$LOGFILE" "$role_name" &
                sleep 1
                break
            fi
        done
        sleep 1
    done
    # Wait for the last test to finish
    while true; do
        if ! pgrep -af "ansible-playbook" | grep -q "$tests_path"; then
            break
        fi
        sleep 1
    done
}

lsrDistributeSSHKeys() {
    local tmt_tree_provision=$1
    local control_node_key_pub control_node_name
    control_node_name=$(lsrGetNodeName "$guests_yml" "control-node")
    control_node_key_pub=$(lsrGetNodeKeyPublic "$guests_yml" "$control_node_name")
    control_node_key_pub_content=$(cat "$control_node_key_pub")
    if [ -f "$control_node_key_pub" ] && ! grep "$control_node_key_pub_content" ~/.ssh/authorized_keys; then
        rlRun "cat $control_node_key_pub >> ~/.ssh/authorized_keys"
    fi
}

lsrSetHostname() {
    local guests_yml=$1
    hostname=$(lsrGetCurrNodeHostname "$guests_yml")
    rlRun "hostnamectl set-hostname $hostname"
}

lsrBuildEtcHosts() {
    local guests_yml=$1
    managed_nodes=$(lsrGetManagedNodes "$guests_yml")
    for managed_node in $managed_nodes; do
        managed_node_ip=$(lsrGetNodeIp "$guests_yml" "$managed_node")
        if ! grep -q "$managed_node_ip $managed_node" /etc/hosts; then
            rlRun "echo $managed_node_ip $managed_node >> /etc/hosts"
        fi
    done
    rlRun "cat /etc/hosts"
}

lsrEnableHA() {
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

lsrDisableNFV() {
    # The nfv-source repo causes troubles in CentOS-9 Stream compose while system-roles testing
    if [ "$(find /etc/yum.repos.d/ -name 'centos-addons.repo' | wc -l )" -gt 0 ]; then
        rlRun "sed -i '/^\[nfv-source\]/,/^$/d' /etc/yum.repos.d/centos-addons.repo"
    fi
}

lsrDiskProvisionerRequired() {
# check if the test requires additional disk devices
# to be provisioned
    local tests_path=$1
    local provision_fmf="$tests_path/provision.fmf"
    if grep -q "drive:" "$provision_fmf" 2> /dev/null; then
        return 0
    fi
    return 1
}

lsrGenerateTestDisks() {
    local tests_path=$1
    local provisionfmf="$tests_path"/provision.fmf
    local disk_provisioner_script=disk_provisioner.sh
    local disk_provisioner_dir
    if ! lsrDiskProvisionerRequired "$tests_path"; then
        return 0
    fi
    managed_nodes=$(lsrGetManagedNodes "$guests_yml")
    control_node_name=$(lsrGetNodeName "$guests_yml" "control-node")
    control_node_key=$(lsrGetNodeKeyPrivate "$guests_yml" "$control_node_name")

    for managed_node in $managed_nodes; do
        node_ip=$(lsrGetNodeIp "$guests_yml" "$managed_node")
        ssh_cmd="ssh -o StrictHostKeyChecking=no -i $control_node_key root@$node_ip"
        rlRun "available=$($ssh_cmd 'df -k /tmp --output=avail | tail -1')"
        # available is defined above
        # shellcheck disable=SC2154
        if [ "$available" -gt 10485760 ]; then
            disk_provisioner_dir=/tmp/disk_provisioner
        else
            disk_provisioner_dir=/var/tmp/disk_provisioner
        fi
        rlRun "scp -o StrictHostKeyChecking=no -i $control_node_key $disk_provisioner_script $provisionfmf root@$node_ip:/tmp/"
        rlRun "$ssh_cmd \"WORK_DIR=$disk_provisioner_dir FMF_DIR=/tmp/ /tmp/$disk_provisioner_script start\""
        # Ensure that a new devices really exists
        rlRun "$ssh_cmd \"fdisk -l | grep 'Disk /dev/'\""
        rlRun "$ssh_cmd \"lsblk -l | cut -d\  -f1 | grep -v NAME | sed 's/^/\/dev\//' | xargs ls -l\""
    done
}

lsrMssqlHaUpdateInventory() {
    local keys values key value
    local inventory=$1
    local arr_name=$2
    eval "keys=(\${!$arr_name[@]})"
    eval "values=(\${$arr_name[@]})"
    rlRun "cat $inventory"
    for i in $(seq 0 $((${#keys[@]} - 1))); do
        key="${keys[$i]}"
        if grep "$key" "$inventory"; then
            value="${values[$i]}"
            rlRun "sed -i \"/$key:/a\ \ \ \ \ \ mssql_ha_replica_type: $value\" $inventory"
        fi
    done
    rlRun "cat $inventory"
}

# prepare test playbooks for gathering information about python
# module usage
lsrSetupGetPythonModules() {
    local tests_dir test_pb
    tests_dir="$1"; shift
    for test_pb in "$@"; do
        cp "$tests_dir$test_pb" "$tests_dir$test_pb.orig"
        sed -e '/^  hosts:/a\
  environment:\
    PYTHONVERBOSE: "1"' -i "$tests_dir$test_pb"
    done
}

lsrSetAnsibleGathering() {
    local value=$1
    if [[ ! $value =~ ^(implicit|explicit|smart)$ ]]; then
        rlLogError "Value for ANSIBLE_GATHERING must be one of implicit, explicit, smart"
        rlLogError "Provided value: $value"
        return 1
    fi
    ANSIBLE_ENVS[ANSIBLE_GATHERING]="$value"
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
