# Removes the WinKit clipboard helper (clipboard_setup.ps1) again: its scheduled task, its program and log.
#   powershell -ExecutionPolicy Bypass -File uninstall_clipboard.ps1      (or: CLIPBOARD.bat remove)
& (Join-Path $PSScriptRoot 'clipboard_setup.ps1') -Remove
