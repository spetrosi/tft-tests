# tft-tests

This repository stores test plans for running tests in Testing Farm.

So far, it contains a single plan and a single test.

## Prerequisites

1. Install [tmt](https://tmt.readthedocs.io/en/latest/guide.html#the-first-steps)
2. Edit `environment` section in `plans/general.fmf`with corresponding values.

## Running tests

You can run tests on local VMs, or in [Testing Farm](https://docs.testing-farm.io/Testing%20Farm/0.1/index.html) if you have a token.

### Running tests on local VMs

Enter `tmt try` with a platform that you wish to test, e.g. `tmt try CentOS-Stream-9`.

### Running in Testing Farm

Make a reservation by following [Test Environment Reservation](https://docs.testing-farm.io/Testing%20Farm/0.1/cli.html#reserve).

## Upstream tests

Upstream tests are run with the [Schedule tests on Testing Farm](https://github.com/marketplace/actions/schedule-tests-on-testing-farm) GitHub action.