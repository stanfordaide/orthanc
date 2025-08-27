```
# Basic operations
./orthanc_manager.sh start
./orthanc_manager.sh status
./orthanc_manager.sh logs

# Updates and maintenance
./orthanc_manager.sh update
./orthanc_manager.sh backup
./orthanc_manager.sh clean

# Removal options
./orthanc_manager.sh delete    # Remove containers, keep data
./orthanc_manager.sh purge     # Remove everything (with final backup)

# Monitoring
./orthanc_manager.sh disk      # Show disk usage
```