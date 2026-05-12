# usv-manager Releases

Dieses Repository enthaelt oeffentliche Release-Pakete fuer usv-manager.

## Schnellstart

Hinweis: Der Installer in diesem Repository ist aktuell bewusst deaktiviert und ueberspringt die Installation, weil `usv-manager` derzeit nicht Bestandteil des SmartHub-Stacks ist.

Installer ausfuehren und Hinweis anzeigen:

```bash
curl -fsSL https://raw.githubusercontent.com/ehive-dev/usv_manager_releases/main/install.sh | sudo bash
```

Aktuelles `.deb` manuell installieren:

```bash
sudo apt-get update
sudo apt-get install -y curl jq
TAG=$(curl -fsSL https://api.github.com/repos/ehive-dev/usv_manager_releases/releases/latest | jq -r .tag_name)
VER=${TAG#v}
curl -fL -o /tmp/usv-manager.deb "https://github.com/ehive-dev/usv_manager_releases/releases/download/${TAG}/usv-manager_${VER}_all.deb"
sudo apt install -y /tmp/usv-manager.deb
```

## Service

```bash
systemctl status usv-manager --no-pager
journalctl -u usv-manager -f
```

## Lizenz

Die Nutzung ist fuer private und nicht-kommerzielle Zwecke erlaubt. Kommerzielle Nutzung benoetigt eine vorherige schriftliche Zustimmung von ehive. Siehe `LICENSE.txt` und `THIRD_PARTY_NOTICES.txt`.
