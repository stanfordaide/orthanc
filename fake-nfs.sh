#!/bin/bash
echo "🧹 Cleaning up any existing NFS setup and installing fresh..."

# Function to run commands with timeout
run_with_timeout() {
    timeout 30 "$@" 2>/dev/null || true
}

# Kill any hanging processes
sudo pkill -f nfs-server 2>/dev/null || true
sudo pkill -f rpcbind 2>/dev/null || true

# Stop NFS services with timeout
echo "Stopping services..."
run_with_timeout sudo systemctl stop nfs-server
run_with_timeout sudo systemctl disable nfs-server
run_with_timeout sudo systemctl stop rpcbind

# Force unmount any existing mounts
echo "Unmounting filesystems..."
sudo umount -f -l /nfs-share/data 2>/dev/null || true
sudo umount -f -l /srv/nfs/orthanc 2>/dev/null || true

# Clear all NFS exports
echo "Clearing NFS exports..."
sudo exportfs -ua 2>/dev/null || true

# Remove from configuration files
echo "Cleaning config files..."
sudo sed -i '/nfs-share/d' /etc/fstab 2>/dev/null || true
sudo sed -i '/srv\/nfs\/orthanc/d' /etc/fstab 2>/dev/null || true
sudo cp /etc/exports /etc/exports.backup 2>/dev/null || true
sudo sed -i '/srv\/nfs\/orthanc/d' /etc/exports 2>/dev/null || true

# Remove directories
echo "Removing directories..."
sudo rm -rf /nfs-share
sudo rm -rf /srv/nfs
sudo rm -rf /opt/network-storage

# Quick firewall cleanup
echo "Cleaning firewall..."
run_with_timeout sudo firewall-cmd --remove-service=nfs --permanent
run_with_timeout sudo firewall-cmd --remove-service=rpc-bind --permanent
run_with_timeout sudo firewall-cmd --reload

# Remove groups
sudo groupdel nfs-users 2>/dev/null || true

# Clean SELinux (with timeout)
echo "Cleaning SELinux..."
run_with_timeout sudo setsebool -P use_nfs_home_dirs off

echo "✅ Cleanup complete. Setting up fresh NFS..."

# Install NFS utilities
echo "Installing NFS utilities..."
sudo dnf install -y nfs-utils

# Start services
echo "Starting NFS services..."
sudo systemctl enable --now nfs-server
sleep 2
sudo systemctl enable --now rpcbind
sleep 2

# Verify services are running
if ! sudo systemctl is-active --quiet nfs-server; then
    echo "⚠️ NFS server failed to start, trying again..."
    sudo systemctl start nfs-server
    sleep 3
fi

# Create and export share
echo "Setting up NFS share..."
sudo mkdir -p /srv/nfs/orthanc
sudo chown root:root /srv/nfs/orthanc
sudo chmod 755 /srv/nfs/orthanc

# Create exports file entry
echo "/srv/nfs/orthanc *(rw,sync,no_subtree_check)" | sudo tee /etc/exports

# Configure firewall
echo "Configuring firewall..."
sudo firewall-cmd --add-service=nfs --permanent
sudo firewall-cmd --add-service=rpc-bind --permanent
sudo firewall-cmd --reload

# Export the share
echo "Exporting NFS share..."
sudo exportfs -ra
sleep 2

# Verify export
echo "Verifying exports..."
sudo exportfs -v

# Create mount point and mount
echo "Mounting NFS share..."
sudo mkdir -p /nfs-share/data
sudo mount -t nfs localhost:/srv/nfs/orthanc /nfs-share/data

# Configure SELinux
echo "Configuring SELinux..."
run_with_timeout sudo setsebool -P use_nfs_home_dirs on
run_with_timeout sudo restorecon -Rv /nfs-share/data

# Test write access
echo "Testing write access..."
if touch /nfs-share/data/write-test 2>/dev/null; then
    echo "✅ Write access confirmed for root"
    rm /nfs-share/data/write-test
    echo "🎉 NFS setup complete! Root can write to /nfs-share/data"
    echo "📁 NFS share available at: /nfs-share/data"
else
    echo "❌ Write access failed - checking status:"
    echo "Mount status:"
    mount | grep nfs-share
    echo "Directory permissions:"
    ls -la /nfs-share/data
    echo "Source directory:"
    ls -la /srv/nfs/orthanc
fi

echo "🔍 Final status check:"
echo "NFS Server: $(sudo systemctl is-active nfs-server)"
echo "RPC Bind: $(sudo systemctl is-active rpcbind)"
echo "Exports:"
sudo showmount -e localhost 2>/dev/null || echo "No exports found"