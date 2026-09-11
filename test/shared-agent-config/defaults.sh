#!/usr/bin/env bash
# The "defaults" scenario is the plain feature on the plain base image --
# exactly what test.sh already checks. Run it rather than duplicate it.
exec "$(dirname "$0")/test.sh"
