# Installing Digital Firefighter Plugins

## Via SFTP (WiFi — recommended)

Enable KOReader's SSH server: **Top menu → Tools → SSH server → Start**

```bash
sftp root@<DEVICE_IP>
cd /mnt/onboard/.adds/koreader/plugins/
put -r transferbridge.koplugin
put -r mangaflow.koplugin
put -r seriesos.koplugin
put -r readingvault.koplugin
put -r powerguard.koplugin
put -r clipsync.koplugin
exit
```

Restart KOReader. Plugins appear under **Top menu → Tools → Plugin manager**.

## Via USB

1. Connect Kobo via USB
2. Copy each `.koplugin` folder to `/mnt/onboard/.adds/koreader/plugins/`
3. Safely eject and reboot KOReader
