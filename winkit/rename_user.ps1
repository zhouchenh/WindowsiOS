# WinKit: changes the Windows user name (the account the image came with is named after its maker).
# Run through RENAME-USER.bat, or: powershell -ExecutionPolicy Bypass -File rename_user.ps1 [-NewName name]
param([string]$NewName)
$ErrorActionPreference = 'Stop'
$old = $env:USERNAME
Write-Host ''
Write-Host "Current user name: $old" -ForegroundColor Cyan
if (-not $NewName) { $NewName = Read-Host 'New user name (Enter = keep it)' }
$NewName = "$NewName".Trim()
if (-not $NewName -or $NewName -eq $old) { Write-Host 'User name not changed.'; return }
if ($NewName.Length -gt 20 -or $NewName -match '["/\\\[\]:;|=,+*?<>@]' -or $NewName.EndsWith('.')) {
    Write-Host 'That name is not allowed: at most 20 characters, none of " / \ [ ] : ; | = , + * ? < > @, no dot at the end.' -ForegroundColor Yellow
    return
}
$taken = $false
try { $taken = [bool]([ADSI]"WinNT://./$NewName,user").Name } catch {}
if ($taken) { Write-Host "An account named $NewName already exists." -ForegroundColor Yellow; return }

try {
    try { Rename-LocalUser -Name $old -NewName $NewName }
    catch { ([ADSI]"WinNT://./$old,user").Rename($NewName) | Out-Null }
} catch {
    Write-Host "Could not rename the account: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '(Administrator rights are needed: use RENAME-USER.bat.)' -ForegroundColor Red
    return
}
# The name shown on the Start menu and the sign-in screen.
try { $u = [ADSI]"WinNT://./$NewName,user"; $u.FullName = $NewName; $u.SetInfo() } catch {}
# Automatic sign-in keeps working: it stores the name.
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
try {
    if ((Get-ItemProperty $wl -ErrorAction Stop).DefaultUserName -eq $old) { Set-ItemProperty $wl -Name DefaultUserName -Value $NewName }
} catch {}
Write-Host "User name changed: $old -> $NewName" -ForegroundColor Green
Write-Host 'It shows after the next sign-in (sign out, or close the app and start Windows again).'
Write-Host "The profile folder stays C:\Users\$old; that is normal and nothing needs to be moved."
