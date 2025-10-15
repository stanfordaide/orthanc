#!/bin/bash
echo "🧹 Cleaning up any existing NFS setup and installing fresh..."

# Stop NFS services first
sudo systemctl stop nfs-server 2>/dev/null || true
sudo systemctl disable nfs-server 2>/dev/null || true
sudo systemctl stop rpcbind 2>/dev/null || true

# Unmount any existing NFS mounts
sudo umount /nfs-share/data 2>/dev/null || true
sudo umount /srv/nfs/orthanc 2>/dev/null || true

# Remove from configuration files
sudo sed -i '/nfs-share/d' /etc/fstab 2>/dev/null || true
sudo sed -i '/srv\/nfs\/orthanc/d' /etc/fstab 2>/dev/null || true
sudo sed -i '/srv\/nfs\/orthanc/d' /etc/exports 2>/dev/null || true

# Clear NFS exports
sudo exportfs -ua 2>/dev/null || true
sudo exportfs -ra 2>/dev/null || true

# Remove directories
sudo rm -rf /nfs-share
sudo rm -rf /srv/nfs/orthanc
sudo rm -rf /srv/nfs
sudo rm -rf /opt/network-storage

# Remove firewall rules
sudo firewall-cmd --remove-service=nfs --permanent 2>/dev/null || true
sudo firewall-cmd --remove-service=rpc-bind --permanent 2>/dev/null || true
sudo firewall-cmd --reload 2>/dev/null || true

# Clean SELinux contexts
sudo semanage fcontext -d "/nfs-share/data(/.*)?" 2>/dev/null || true
sudo semanage fcontext -d "/srv/nfs/orthanc(/.*)?" 2>/dev/null || true
sudo setsebool -P use_nfs_home_dirs off 2>/dev/null || true

# Remove groups
sudo groupdel nfs-users 2>/dev/null || true

echo "✅ Cleanup complete. Setting up fresh NFS..."

# Install NFS utilities
sudo dnf install -y nfs-utils

# Start and enable services
sudo systemctl enable --now nfs-server
sudo systemctl enable --now rpcbind

# Create and export share
sudo mkdir -p /srv/nfs/orthanc
echo "/srv/nfs/orthanc *(rw,sync,no_subtree_check)" | sudo tee -a /etc/exports

# Configure firewall
sudo firewall-cmd --add-service=nfs --permanent
sudo firewall-cmd --add-service=rpc-bind --permanent
sudo firewall-cmd --reload

# Set ownership and permissions on source directory
sudo chown root:root /srv/nfs/orthanc
sudo chmod 755 /srv/nfs/orthanc

# Export and mount
sudo exportfs -ra
sudo mkdir -p /nfs-share/data
sudo mount -t nfs localhost:/srv/nfs/orthanc /nfs-share/data

# Configure SELinux
sudo setsebool -P use_nfs_home_dirs on
sudo restorecon -Rv /nfs-share/data 2>/dev/null || true

# Test write access
echo "Testing write access..."
if touch /nfs-share/data/write-test 2>/dev/null; then
    echo "✅ Write access confirmed for root"
    rm /nfs-share/data/write-test
    echo "🎉 NFS setup complete! Root can write to /nfs-share/data"
else
    echo "❌ Write access failed"
    ls -la /nfs-share/data
fi