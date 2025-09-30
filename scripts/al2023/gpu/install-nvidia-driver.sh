#!/usr/bin/env bash
set -ex

# Only proceed for AL2023 GPU AMIs
if [[ $AMI_TYPE != "al2023"*"gpu" ]]; then
    exit 0
fi

### Install GPU Drivers and Required Packages
# Set executable permissions and move kernel module utilities to /usr/bin
# (kmod utilities are copied to /tmp by Packer)
sudo chmod +x "/tmp/kmod-util"
sudo mv "/tmp/kmod-util" /usr/bin/

# Configure DKMS for parallel compilation to reduce NVIDIA driver build time
# This optimization enables multi-threaded compilation using all available CPU cores,
sudo mkdir -p /etc/dkms
echo "MAKE[0]=\"'make' -j$(grep -c processor /proc/cpuinfo) modules\"" | sudo tee /etc/dkms/nvidia.conf

# Install base requirements
RUNNING_KERNEL=$(uname -r)
sudo dnf install -y \
  "dnf-command(versionlock)" \
  "kernel-devel-${RUNNING_KERNEL}" \
  "kernel-headers-${RUNNING_KERNEL}" \
  "kernel-modules-extra-${RUNNING_KERNEL}" \
  "kernel-modules-extra-common-${RUNNING_KERNEL}" \
  dkms \
  patch

# Lock kernel version to prevent automatic updates that could break DKMS modules
sudo dnf versionlock 'kernel*'

# Enable DKMS service
sudo systemctl enable --now dkms

# nvidia-release creates an nvidia repo file at /etc/yum.repos.d/amazonlinux-nvidia.repo
sudo dnf install -y nvidia-release

function archive-proprietary-kmod() {
  sudo dnf -y install "kmod-nvidia-latest-dkms"
  
  NVIDIA_PROPRIETARY_VERSION=$(kmod-util module-version nvidia)
  sudo dkms remove "nvidia/$NVIDIA_PROPRIETARY_VERSION" --all
  sudo sed -i 's/PACKAGE_NAME="nvidia"/PACKAGE_NAME="nvidia-proprietary"/' /usr/src/nvidia-$NVIDIA_PROPRIETARY_VERSION/dkms.conf
  sudo mv /usr/src/nvidia-$NVIDIA_PROPRIETARY_VERSION /usr/src/nvidia-proprietary-$NVIDIA_PROPRIETARY_VERSION
  sudo dkms add -m nvidia-proprietary -v $NVIDIA_PROPRIETARY_VERSION
  sudo dkms build -m nvidia-proprietary -v $NVIDIA_PROPRIETARY_VERSION
  sudo dkms install -m nvidia-proprietary -v $NVIDIA_PROPRIETARY_VERSION

  sudo kmod-util archive nvidia-proprietary
  sudo kmod-util remove nvidia-proprietary
  sudo rm -rf /usr/src/nvidia-proprietary*
  sudo dnf -y remove --all "kmod-nvidia-latest-dkms*"
}

function archive-open-kmod() {
  sudo dnf -y install "kmod-nvidia-open-dkms"
  
  NVIDIA_OPEN_VERSION=$(kmod-util module-version nvidia)
  sudo kmod-util archive nvidia

  # Copy the source files to a new directory for GRID driver installation
  sudo mkdir /usr/src/nvidia-grid-$NVIDIA_OPEN_VERSION
  sudo cp -R /usr/src/nvidia-$NVIDIA_OPEN_VERSION/* /usr/src/nvidia-grid-$NVIDIA_OPEN_VERSION

  sudo kmod-util remove nvidia
}

function archive-grid-kmod() {
  local MACHINE
  MACHINE=$(uname -m)
  if [ "$MACHINE" != "x86_64" ]; then
    return
  fi
  NVIDIA_OPEN_VERSION=$(ls -d /usr/src/nvidia-grid-* | sed 's/.*nvidia-grid-//')
  sudo sed -i 's/PACKAGE_NAME="nvidia"/PACKAGE_NAME="nvidia-grid"/g' /usr/src/nvidia-grid-$NVIDIA_OPEN_VERSION/dkms.conf
  sudo sed -i "s/MAKE\[0\]=\"'make'/MAKE\[0\]=\"'make' GRID_BUILD=1 GRID_BUILD_CSP=1 /g" /usr/src/nvidia-grid-$NVIDIA_OPEN_VERSION/dkms.conf
  sudo dkms build -m nvidia-grid -v $NVIDIA_OPEN_VERSION
  sudo dkms install nvidia-grid/$NVIDIA_OPEN_VERSION

  sudo kmod-util archive nvidia-grid
  sudo kmod-util remove nvidia-grid
  sudo rm -rf /usr/src/nvidia-grid*
}

# Archive kernel modules for dynamic driver selection
archive-proprietary-kmod
archive-open-kmod
archive-grid-kmod

# Install NVIDIA drivers and tools
sudo dnf install -y "nvidia-open" \
    nvidia-fabric-manager \
    pciutils \
    xorg-x11-server-Xorg \
    nvidia-container-toolkit \
    oci-add-hooks

sudo dnf versionlock 'nvidia*'
sudo dnf versionlock 'kmod*'
sudo dnf versionlock 'libnvidia*'

### Package installation and setup to support P6 instances
sudo dnf install -y libibumad infiniband-diags nvlsm

# Load the User Mode API driver for InfiniBand
sudo modprobe ib_umad

# Ensure the ib_umad module is loaded at boot
echo ib_umad | sudo tee /etc/modules-load.d/ib_umad.conf

sudo chmod +x /tmp/nvidia-kmod-load.sh
sudo mv /tmp/nvidia-kmod-load.sh /etc/ecs/
sudo mv /tmp/nvidia-kmod-load.service /etc/systemd/system/nvidia-kmod-load.service
sudo systemctl daemon-reload
sudo systemctl enable nvidia-kmod-load.service

### Configure NVIDIA Services
# The Fabric Manager service needs to be started and enabled on EC2 P4d instances
# in order to configure NVLinks and NVSwitches
sudo systemctl enable nvidia-fabricmanager

# NVIDIA Persistence Daemon needs to be started and enabled on P5 instances
# to maintain persistent software state in the NVIDIA driver.
sudo systemctl enable nvidia-persistenced
