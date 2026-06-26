#!/usr/bin/env bash
set -euo pipefail

# These suites spawn background processes or tmux panes, so keep them isolated
# while the rest of the package runs with SwiftPM's parallel test runner.
SERIAL_TEST_FILTER=${SERIAL_TEST_FILTER:-'AgentBackgroundTests|BackgroundTaskManagerTests|BashBackgroundRunnerTests|BashToolBackgroundTests|BashToolTests|TaskStatusToolTests|TmuxSessionManagerTests|TmuxToolTests|WaitTaskToolTests'}

if (($#)); then
  echo "usage: Scripts/test.sh" >&2
  exit 64
fi

swift test --parallel --skip "$SERIAL_TEST_FILTER"
swift test --skip-build --no-parallel --filter "$SERIAL_TEST_FILTER"
