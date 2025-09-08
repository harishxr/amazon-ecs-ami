#!/usr/bin/env bash
set -ex

# Only proceed for AL2023 GPU AMIs
if [[ $AMI_TYPE != "al2023"*"gpu" ]]; then
    exit 0
fi

### Install GPU Drivers and Required Packages
# Set executable permissions and move kernel module utilities to /usr/bin
# (kmod utilities are copied to /tmp/gpu by Packer)
sudo chmod +x "/tmp/kmod-util"
sudo chmod +x "/tmp/kmod-util-simple"
sudo mv "/tmp/kmod-util" /usr/bin/
sudo mv "/tmp/kmod-util-simple" /usr/bin/

# Clean DNF cache thoroughly
sudo dnf clean all
sudo rm -rf /var/cache/dnf/*
sudo dnf makecache

# Install base requirements
sudo dnf install -y dkms kernel-modules-extra-$(uname -r) kernel-devel-$(uname -r)

# Enable DKMS service
sudo systemctl enable --now dkms

# Clean cache again before nvidia packages
sudo dnf clean packages
sudo dnf makecache

# nvidia-release creates an nvidia repo file at /etc/yum.repos.d/amazonlinux-nvidia.repo
sudo dnf install -y nvidia-release

# Clean cache and rebuild after adding nvidia repo
sudo dnf clean all
sudo dnf makecache

# Install NVIDIA drivers and tools
echo "Installing NVIDIA drivers and tools..."
sudo dnf install -y nvidia-driver \
    nvidia-fabric-manager \
    pciutils \
    xorg-x11-server-Xorg \
    nvidia-container-toolkit \
    oci-add-hooks

### Package installation and setup to support P6 instances
sudo dnf install -y libibumad infiniband-diags nvlsm

# Load the User Mode API driver for InfiniBand
sudo modprobe ib_umad

# Ensure the ib_umad module is loaded at boot
echo ib_umad | sudo tee /etc/modules-load.d/ib_umad.conf

### Configure NVIDIA Services
# The Fabric Manager service needs to be started and enabled on EC2 P4d instances
# in order to configure NVLinks and NVSwitches
sudo systemctl enable nvidia-fabricmanager

# NVIDIA Persistence Daemon needs to be started and enabled on P5 instances
# to maintain persistent software state in the NVIDIA driver.
sudo systemctl enable nvidia-persistenced
