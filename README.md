# tft-tests

This repository stores test plans for running tests in Testing Farm.

So far, it contains a single plan and a single test.

## Prerequisites

1. Install [tmt](https://tmt.readthedocs.io/en/latest/guide.html#the-first-steps)
2. Edit `environment` section in `plans/general.fmf`with corresponding values.

## Running tests

You can run tests on local VMs, or in [Testing Farm](https://docs.testing-farm.io/Testing%20Farm/0.1/index.html).

### Running in Testing Farm

`testing-farm` CLI does not support running multihost test plans, but you can keep the tests running in the CI and SSH into the test systems for troubleshooting.
To do this, uncomment the discover step `reserve_system` in a test plan.
This step inserts `sleep 5h` at the end of the test to keep systems running.

You can SSH into the systems using 1minutetip id_rsa.
If you do not have access to 1minutetip id_rsa, you can provide a `ID_RSA_PUB` evnironment variable, in this case the test would copy the provided key to `~/.ssh/authorized_keys`.
You can find system's IP addresses in guests.yaml file uploaded to Fedora storage together with test playbooks logs.

For singlehost tests, make a reservation by following [Test Environment Reservation](https://docs.testing-farm.io/Testing%20Farm/0.1/cli.html#reserve).

### Running tests on local VMs

Enter `tmt try` with a plan and platform that you wish to test, e.g. `tmt try -p general CentOS-Stream-9`.

Multihost tests with more than 2 hosts break terminal, see https://github.com/teemtee/tmt/issues/3138.

You can use `get_ssh_cmds.sh` to generate ssh commands from a run number to be able to ssh into test systems.

## Upstream tests

Upstream tests are run with the [Schedule tests on Testing Farm](https://github.com/marketplace/actions/schedule-tests-on-testing-farm) GitHub action.