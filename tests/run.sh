#!/bin/bash
set -u
here="$(cd "$(dirname "$0")" && pwd)"
rc=0
for suite in test-status.sh test-join-leave.sh test-safety.sh test-qml-markup.sh; do
  bash "$here/$suite" || rc=1
done
exit "$rc"
