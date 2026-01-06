# usv-manager

Kleiner Dienst für eHive/OpenArc, der per GPIO eine USV (Power/Ladepfad/Status) überwacht und bei Stromverlust einen geregelten Shutdown auslösen kann.

## Features

- systemd Service (`usv-manager.service`)
- Konfiguration über `/etc/default/usv-manager`
- Installation/Update über GitHub Releases (.deb)
- Logs über `journalctl`

## Installation


```bash
curl -fsSL https://raw.githubusercontent.com/ehive-dev/usv-manager-releases/main/install.sh | sudo bash

curl -fsSL https://raw.githubusercontent.com/ehive-dev/usv-manager-releases/main/install.sh | sudo bash -s -- --pre

curl -fsSL https://raw.githubusercontent.com/ehive-dev/usv-manager-releases/main/install.sh | sudo bash -s -- --pre
