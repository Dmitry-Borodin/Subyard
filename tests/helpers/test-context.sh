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
  export NESTED_E2E_VMS=0
  export E2E_VM_IMAGE=images:debian/13/cloud
  export E2E_VM_CPU=2
  export E2E_VM_MEMORY=4GiB
  export E2E_VM_DISK=10GiB
  export E2E_VM_TTL_MINUTES=240
  export E2E_VM_BOOT_TIMEOUT=300
  export INCUS_PROJECT="${2:-subyard}"
  export INSTANCE_NAME="${3:-yard}"
  export DEV_USER=dev
  export SSH_PORT=2222
}
