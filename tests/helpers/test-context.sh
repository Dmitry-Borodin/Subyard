#!/usr/bin/env bash
# Deterministic, host-free context shared by tests that bypass the normal config layers.

setup_test_context() { # <temp-root> [incus-project] [instance-name]
  local root="${1:?setup_test_context needs a temp root}"
  export SUBYARD_OPERATOR_HOME="$root/home"
  export SUBYARD_CONFIG_HOME="$root/config"
  export SUBYARD_HOME="$root/subyard"
  export STORAGE_PATH="$SUBYARD_HOME/incus/storage"
  export HOST_BASE="$root/host-data"
  export RESTRICTED_DISK_PATHS="$HOST_BASE"
  export INSTANCE_TYPE=container
  export SHIFT_MODE=shift
  export FORWARD_SSH_AGENT=0
  export DEV_SUDO=0
  export DEV_UID=1000
  export INCUS_PROJECT="${2:-subyard}"
  export INSTANCE_NAME="${3:-yard}"
  export DEV_USER=dev
  export SSH_PORT=2222
}
