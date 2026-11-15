# Removes the 3D driver again (back to the basic display). Run elevated.
$ErrorActionPreference = "Continue"
$txt = pnputil /enum-drivers | Out-String
foreach ($b in ($txt -split "(\r?\n){2,}")) {
    if ($b -match "Original Name:\s+viogpu3d\.inf" -and $b -match "Published Name:\s+(oem\d+\.inf)") { pnputil /delete-driver $Matches[1] /uninstall /force }
}
Write-Host "Done. Restart the VM."
