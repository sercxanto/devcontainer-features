#!/usr/bin/env bash
set -e
source dev-container-features-test-lib
check "pinned version is installed" bash -c 'opencode --version </dev/null | grep -Eq "(^| )v?2\.3\.1$"'
reportResults
