#!/usr/bin/env bash

set -Eeuo pipefail

# Exit early if no NVIDIA devices are present
if ! kmod-util has-nvidia-device; then
  echo >&2 "no NVIDIA devices are present, not loading kernel module!"
  exit 0
fi

# Constants
readonly NVIDIA_VENDOR_ID="10de"
readonly PCI_CLASS_CODES=(
  "0300" # VGA controller; instance types like g3, g4
  "0302" # 3D controller; instance types like p4, p5
)
readonly NVIDIA_GRID_SUBDEVICES=(
  "27b8:1733" # L4:L4-3Q
  "27b8:1735" # L4:L4-6Q
  "27b8:1737" # L4:L4-12Q
)

# Return the path of the file containing devices supported by the nvidia-open kmod
nvidia-open-supported-devices-file() {
  local kmod_major_version
  kmod_major_version=$(rpmquery kmod-nvidia-latest-dkms --queryformat '%{VERSION}' | cut -d. -f1)
  local supported_device_file="/etc/ecs/nvidia-open-supported-devices-${kmod_major_version}.txt"
  
  if [[ ! -f "${supported_device_file}" ]]; then
    echo >&2 "Supported device file not found for ${kmod_major_version}: ${supported_device_file}"
    exit 1
  fi
  
  echo "${supported_device_file}"
}

# Determine if all attached nvidia devices are supported by the open-source kernel module
devices-support-open() {
  local supported_device_file
  supported_device_file=$(nvidia-open-supported-devices-file)
  
  local pci_class_code nvidia_device_id
  for pci_class_code in "${PCI_CLASS_CODES[@]}"; do
    while IFS= read -r nvidia_device_id; do
      if ! grep -q "^0x${nvidia_device_id}[[:space:]]" "${supported_device_file}"; then
        return 1
      fi
    done < <(lspci -n -mm -d "${NVIDIA_VENDOR_ID}::${pci_class_code}" | awk '{print $4}' | tr -d '"' | tr '[:lower:]' '[:upper:]')
  done
  
  return 0
}

# Check if any device supports GRID virtualization
device-supports-grid() {
  local nvidia_grid_subdevice nvidia_subdevice
  for nvidia_grid_subdevice in "${NVIDIA_GRID_SUBDEVICES[@]}"; do
    while IFS= read -r nvidia_subdevice; do
      if [[ "${nvidia_grid_subdevice}" == "${nvidia_subdevice}" ]]; then
        return 0
      fi
    done < <(lspci -n -mm -d "${NVIDIA_VENDOR_ID}:" | awk '{print $4":"$7}' | tr -d '"')
  done
  
  return 1
}

# Determine and load the appropriate NVIDIA kernel module
main() {
  local module_name
  
  if device-supports-grid; then
    module_name="nvidia-open-grid"
  elif devices-support-open; then
    module_name="nvidia-open"
  else
    module_name="nvidia"
  fi
  
  echo "Loading NVIDIA kernel module: ${module_name}"
  exec kmod-util load "${module_name}"
}

main "$@"
