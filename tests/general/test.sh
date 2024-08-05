#!/bin/bash

. /usr/share/beakerlib/beakerlib.sh || exit 1

# Test parameters:
# ANSIBLE_VER
#   ansible version to use for tests. E.g. "2.9" or "2.16".
#
# REPO_NAME
#   Name of the role repository to test.
#
# TEST_LOCAL_CHANGES
#   Optional: When true, tests from local changes. When false, test from a repository PR number (when PR_NUM is set) or main branch.
TEST_LOCAL_CHANGES="${TEST_LOCAL_CHANGES:-false}"
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
fi
# SKIP_TAGS
#   Ansible tags that must be skipped
SKIP_TAGS="--skip-tags tests::nvme,tests::infiniband"
# LSR_TFT_DEBUG
#   Print output of ansible playbooks to terminal in addition to printing it to logfile
if [ "$(echo "$SYSTEM_ROLES_ONLY_TESTS" | wc -w)" -eq 1 ]; then
    LSR_TFT_DEBUG=true
else
    LSR_TFT_DEBUG="${LSR_TFT_DEBUG:-false}"
fi
# REQUIRED_VARS
#   Env variables required by this test
REQUIRED_VARS=("ANSIBLE_VER" "REPO_NAME")

tmt_tree_provision=${TMT_TREE%/*}/provision
guests_yml=${tmt_tree_provision}/guests.yaml

rlJournalStart
    rlPhaseStartSetup
        rlRun "rlImport library"
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
        if [ "$TEST_LOCAL_CHANGES" == true ] || [ "$TEST_LOCAL_CHANGES" == True ]; then
            rlLog "Test from local changes"
            role_path=$TMT_TREE
        else
            role_path=$TMT_TREE/$REPO_NAME
            rolesCloneRepo "$role_path"
        fi
        test_playbooks=$(rolesGetTests "$role_path")
        rlLogInfo "Test playbooks: $test_playbooks"
        for test_playbook in $test_playbooks; do
            rolesHandleVault "$role_path" "$test_playbook"
        done
        collection_path=$(mktemp --directory)
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
rlJournalEnd
