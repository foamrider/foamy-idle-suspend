#!/bin/bash
# foamy-idle-suspend's own tests; tests/validate.sh runs this after the linters.
#   --ci    no Quickshell, no Omarchy host: the node tests only
#   --fast  skip the offscreen Quickshell tests
# Nothing here can suspend, lock or notify: the runtime test reaches every
# command through bash mocks in a temporary HOME.
set -uo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." || exit 1
ci=0 fast=0
for arg in "$@"; do
  case $arg in
    --ci) ci=1 ;;
    --fast) fast=1 ;;
    *)
      echo "suite.sh: unknown argument $arg" >&2
      exit 2
      ;;
  esac
done
status=0
run() {
  echo "== $*"
  "$@" || status=1
}
skip() { echo "SKIP $*"; }
run node --test tests/policy.test.cjs
if ((ci || fast)); then
  skip "tests/runtime.py: offscreen Quickshell with mocked logind, lock and systemctl"
  skip "kit preview/i18n_runtime.py: offscreen Quickshell"
else
  kit=${FOAMY_KIT:-$HOME/GitHub/Personal/foamy-kit}
  run python3 -I -B tests/runtime.py
  run python3 -I -B "$kit/preview/i18n_runtime.py" .
fi
exit $status
