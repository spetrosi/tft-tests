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
#   Optional: Space separated names of test playbooks to exclude from test.
#
# GITHUB_ORG
#   Optional: GitHub org to fetch test repository from. Default: linux-system-roles. Can be set to a fork for test purposes.
GITHUB_ORG="${GITHUB_ORG:-linux-system-roles}"
# LINUXSYSTEMROLES_SSH_KEY
#   Optional: When provided, test uploads artifacts to LINUXSYSTEMROLES_DOMAIN instead of uploading them with rlFileSubmit "$logfile".
#   A Single-line SSH key.
#   When provided, requires LINUXSYSTEMROLES_USER and LINUXSYSTEMROLES_DOMAIN.
# LINUXSYSTEMROLES_USER
#   Username used when uploading artifacts.
# LINUXSYSTEMROLES_DOMAIN: secondary01.fedoraproject.org
#   Domain where to upload artifacts.
# PYTHON_VERSION
#   Python version to install ansible-core with (EL 8, 9, 10 only).
if rlIsFedora || rlIsRHELLike ">7"; then
    PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
# hardcode for el7 because it won\t update
else
    PYTHON_VERSION=3
    rlRun "yum install python$PYTHON_VERSION-pip -y"
fi
# SKIP_TAGS
#   Ansible tags that must be skipped
SKIP_TAGS="--skip-tags tests::nvme,tests::infiniband"
# REQUIRED_VARS
#   Env variables required by this test
REQUIRED_VARS=("ANSIBLE_VER" "REPO_NAME")

tmt_tree_provision=${TMT_TREE%/*}/provision
guests_yml=${tmt_tree_provision}/guests.yaml
role_path=$TMT_TREE/$REPO_NAME

rlJournalStart
    rlPhaseStartSetup
        # rlImport "$tmt_tree_discover/Run-test-playbooks-from-control_node/libs/rolesLib/library/lib.sh"
        rlRun "rlImport tft-tests/library"
        for required_var in "${REQUIRED_VARS[@]}"; do
            if [ -z "${!required_var}" ]; then
                rlDie "This required variable is unset: $required_var "
            fi
        done
        if [ -n "$ANSIBLE_VER" ]; then
            rolesInstallAnsible
        else
            rlLogInfo "ANSIBLE_VER not defined - using system ansible if installed"
        fi
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
        inventory=$(rolesPrepareInventoryVars "$role_path" "$tmt_tree_provision" "$guests_yml")
        rlRun "cat $inventory"
    rlPhaseEnd

    rlPhaseStartTest
        tests_path="$collection_path"/ansible_collections/fedora/linux_system_roles/tests/"$REPO_NAME"/
        for test_playbook in $test_playbooks; do
            rolesRunPlaybook "$tests_path" "$test_playbook" "$inventory" "$SKIP_TAGS"
        done
    rlPhaseEnd

    rlPhaseStartCleanup
        rlRun "rm -r $collection_path" 0 "Remove tmp directory"
        rlRun "rm -r $role_path" 0 "Remove role directory"
    rlPhaseEnd
rlJournalEnd
