#!/bin/bash

# Assume the Python script is in the same directory as this script
SCRIPT_PATH=$(dirname $0)/your_python_script.py

# Create the systemd service file
echo "[Unit]" > /etc/systemd/system/your_service.service
echo "Description=Your Python Script Service" >> /etc/systemd/system/your_service.service
echo "After=network.target" >> /etc/systemd/system/your_service.service
echo "" >> /etc/systemd/system/your_service.service
echo "[Service]" >> /etc/systemd/system/your_service.service
echo "User=yourserviceuser" >> /etc/systemd/system/your_service.service
echo "ExecStart=/usr/bin/python $SCRIPT_PATH" >> /etc/systemd/system/your_service.service
echo "Restart=always" >> /etc/systemd/system/your_service.service
echo "" >> /etc/systemd/system/your_service.service
echo "[Install]" >> /etc/systemd/system/your_service.service
echo "WantedBy=multi-user.target" >> /etc/systemd/system/your_service.service

# Reload the systemd daemon
sudo systemctl daemon-reload

# Start the service
sudo systemctl start your_service

# Enable the service to start automatically on boot
sudo systemctl enable your_service
