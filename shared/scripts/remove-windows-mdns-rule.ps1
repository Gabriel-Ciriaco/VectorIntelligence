# PowerShell script to cleanly remove windows-mdns firewall rules if uninstalled
Remove-NetFirewallRule -DisplayName "windows-mdns" -ErrorAction SilentlyContinue
Write-Host "windows-mdns firewall rules removed successfully!" -ForegroundColor Green
