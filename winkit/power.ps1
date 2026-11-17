# WinKit: Windows never sleeps, hibernates, dims, turns the screen off or acts on the battery by itself.
# The app shows the iPhone's battery in Windows (app Settings > System > Battery): unplugged, Windows is on
# battery power, and its defaults would then turn the screen off, warn, switch on energy saver and shut down
# at a low charge. This sets, in EVERY power plan, plugged in (AC) and on battery (DC) alike:
#   - every on-battery value the same as its plugged-in value (processor, PCIe, USB and the rest), then:
#   - sleep, hibernate, unattended sleep, turn off display, dim display, display off when locked and
#     turn off hard disk: never; hybrid sleep: off
#   - low and critical battery action: do nothing; low, critical and reserve battery level: the lowest
#     allowed; low and critical battery notification: off (where Windows has them)
#   - energy saver: never turns on by itself (threshold 0)
#   - lid and sleep button: do nothing. The power button: shut down, because the app's
#     "Shut down (ask Windows)" presses it; -PowerButtonDoesNothing makes it do nothing too.
# and turns hibernation off (powercfg /h off). Plain powercfg, no group policy: everything stays
# changeable in Windows' settings. Safe to run again: it changes only what differs and prints each change.
# Needs administrator rights: run it through POWER.bat (START.bat runs it too).
#   powershell -ExecutionPolicy Bypass -File power.ps1
#   powershell -ExecutionPolicy Bypass -File power.ps1 -PowerButtonDoesNothing
param([switch]$PowerButtonDoesNothing)
$ErrorActionPreference = 'Continue'

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Write-Host '  Administrator rights are needed: double-click POWER.bat instead.' -ForegroundColor Yellow
    exit 1
}

$log = New-Object System.Collections.Generic.List[string]
function Say($t, $color) {
    $log.Add([string]$t)
    if ($color) { Write-Host $t -ForegroundColor $color } else { Write-Host $t }
}
# The result also goes to the app's Shared folder (power.txt), like tune.ps1's tune.txt.
function Send {
    $p = Join-Path $env:TEMP 'power.txt'
    try {
        $log | Out-File -Encoding utf8 $p
        Invoke-WebRequest -UseBasicParsing -Method Put -Uri 'http://10.0.2.4/power.txt' -InFile $p -TimeoutSec 5 | Out-Null
    } catch {}
}

$guidRe = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

$SUB_SLEEP   = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
$SUB_VIDEO   = '7516b95f-f776-4464-8c53-06167f40cc99'
$SUB_DISK    = '0012ee47-9041-4b5d-9b77-535fba8b1442'
$SUB_BUTTONS = '4f971e89-eebd-4455-a8de-9e59040e7347'
$SUB_BATTERY = 'e73a048d-bf27-4f12-9731-8b2076e8891f'
$SUB_ES      = 'de830923-a562-41af-a086-e3a2c6bad2da'

# Power button: 3 = shut down (what the app's "Shut down (ask Windows)" needs), 0 = do nothing.
$pbutton = 3
if ($PowerButtonDoesNothing) { $pbutton = 0 }

# sub, setting, alias, value ('min' = the lowest value the setting allows)
$rules = @(
    @($SUB_SLEEP,   '29f6c1db-86da-48c5-9fdb-f2b67b1f44da', 'STANDBYIDLE (sleep after)', 0),
    @($SUB_SLEEP,   '9d7815a6-7ee4-497e-8888-515a05f02364', 'HIBERNATEIDLE (hibernate after)', 0),
    @($SUB_SLEEP,   '94ac6d29-73ce-41a6-809f-6363ba21b47e', 'HYBRIDSLEEP (hybrid sleep)', 0),
    @($SUB_SLEEP,   '7bc4a2f9-d8fc-4469-b07b-33eb785aaca0', 'UNATTENDSLEEP (unattended sleep after)', 0),
    @($SUB_VIDEO,   '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e', 'VIDEOIDLE (turn off display after)', 0),
    @($SUB_VIDEO,   '17aaa29b-8b43-4b94-aafe-35f64daaf1ee', 'VIDEODIM (dim display after)', 0),
    @($SUB_VIDEO,   '8ec4b3a5-6868-48c2-be75-4f3044be88a7', 'VIDEOCONLOCK (display off when locked)', 0),
    @($SUB_DISK,    '6738e2c4-e8a5-4a42-b16a-e040e769756e', 'DISKIDLE (turn off hard disk after)', 0),
    @($SUB_BUTTONS, '5ca83367-6e45-459f-a27b-476b1d01c936', 'LIDACTION (lid close action)', 0),
    @($SUB_BUTTONS, '96996bc0-ad50-47ec-923b-6f41874dd9eb', 'SBUTTONACTION (sleep button action)', 0),
    @($SUB_BUTTONS, '7648efa3-dd9c-4e3e-b566-50f929386280', 'PBUTTONACTION (power button action)', $pbutton),
    @($SUB_BATTERY, '637ea02f-bbcb-4015-8e2c-a1c7b9c0b546', 'BATACTIONCRIT (critical battery action)', 0),
    @($SUB_BATTERY, 'd8742dcb-3e6a-4b3c-b3fe-374623cdcf06', 'BATACTIONLOW (low battery action)', 0),
    @($SUB_BATTERY, '9a66d8d7-4ff7-4ef9-b5a2-5a326ca2a469', 'BATLEVELCRIT (critical battery level)', 'min'),
    @($SUB_BATTERY, '8183ba9a-e910-48da-8769-14ae6dc1170a', 'BATLEVELLOW (low battery level)', 'min'),
    @($SUB_BATTERY, 'f3c5027d-cd16-4930-aa6b-90db844a8f00', 'BATLEVELRESERVE (reserve battery level)', 'min'),
    @($SUB_BATTERY, 'bcded951-187b-4d05-bccc-f7e51960c258', 'BATFLAGSLOW (low battery notification)', 0),
    @($SUB_BATTERY, '5dbb7c9f-38e9-40d2-9749-4f8a0e9f640f', 'BATFLAGSCRIT (critical battery notification)', 0),
    @($SUB_ES,      'e69653ca-cf7f-4f05-aa73-cb833fa90ad4', 'ESBATTTHRESHOLD (energy saver turns on at %)', 0)
)

# The settings powercfg lists for these arguments (a plan, or a plan + subgroup + setting), hidden ones
# included (/qh; /q where /qh is not known). Parsed without relying on the display language: the first
# GUID line is the plan; a GUID line followed by hex values is a setting (its last two values are the
# plugged-in and on-battery index, a range setting lists its minimum first); one followed directly by
# another GUID line is a subgroup.
function Read-Settings([string[]]$qargs) {
    $out = $null
    foreach ($q in '/qh', '/q') {
        $out = & powercfg $q @qargs 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { break }
        $out = $null
    }
    $list = New-Object System.Collections.Generic.List[object]
    if (-not $out) { return , $list }
    $planSeen = $false
    $sub = $null
    $pend = $null
    # a last GUID line (all zero) flushes the last setting
    foreach ($line in @($out) + @('00000000-0000-0000-0000-000000000000')) {
        $m = [regex]::Match([string]$line, "($guidRe)\s*(?:\((.*)\))?\s*\*?\s*$")
        if ($m.Success) {
            if (-not $planSeen) { $planSeen = $true; continue }
            if ($pend) {
                $h = $pend.Hex
                if ($h.Count -ge 2) {
                    $min = 0
                    if ($h.Count -ge 5) { $min = $h[0] }
                    $list.Add([pscustomobject]@{ Sub = $sub; Guid = $pend.Guid; Name = $pend.Name; Min = $min
                                                 AC = $h[$h.Count - 2]; DC = $h[$h.Count - 1]; WantAC = $null; WantDC = $null })
                } else {
                    $sub = $pend.Guid
                }
            }
            $pend = @{ Guid = $m.Groups[1].Value.ToLower(); Name = $m.Groups[2].Value.Trim(); Hex = New-Object System.Collections.Generic.List[long] }
        } elseif ($pend) {
            foreach ($x in [regex]::Matches([string]$line, '0x([0-9a-fA-F]{1,8})\b')) {
                $pend.Hex.Add([Convert]::ToInt64($x.Groups[1].Value, 16))
            }
        }
    }
    return , $list
}

function Set-Index($plan, $e, [string]$which, [long]$value) {
    $op = '/setacvalueindex'
    if ($which -eq 'DC') { $op = '/setdcvalueindex' }
    & powercfg $op $plan $e.Sub $e.Guid $value 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

Say '=== Power settings: Windows never acts on idle time or the battery by itself ===' 'Green'
if ($PowerButtonDoesNothing) { Say '  (power button: do nothing; the app''s "Shut down (ask Windows)" will do nothing)' 'Yellow' }

$plans = @()
foreach ($line in (& powercfg /list 2>$null)) {
    $m = [regex]::Match([string]$line, "($guidRe)\s*\((.*)\)")
    if ($m.Success) { $plans += [pscustomobject]@{ Guid = $m.Groups[1].Value.ToLower(); Name = $m.Groups[2].Value.Trim() } }
}
$active = $null
$m = [regex]::Match([string](& powercfg /getactivescheme 2>$null), $guidRe)
if ($m.Success) { $active = $m.Value.ToLower() }
if (-not $plans) { Say 'powercfg /list showed no power plans: nothing done.' 'Red'; Send; exit 1 }

$changed = 0
$failed = 0
$missing = @{}
foreach ($plan in $plans) {
    $label = $plan.Name
    if ($plan.Guid -eq $active) { $label = "$label (active)" }
    $settings = Read-Settings @($plan.Guid)
    if ($settings.Count -eq 0) { Say "  ${label}: powercfg could not list its settings, skipped" 'Yellow'; $failed++; continue }
    $byGuid = @{}
    foreach ($e in $settings) {
        $byGuid[$e.Guid] = $e
        # on battery the same as plugged in
        $e.WantAC = $e.AC
        $e.WantDC = $e.AC
    }
    foreach ($r in $rules) {
        $e = $byGuid[$r[1]]
        if (-not $e) {
            $one = Read-Settings @($plan.Guid, $r[0], $r[1])
            foreach ($x in $one) { if ($x.Guid -eq $r[1]) { $e = $x; $e.WantAC = $e.AC; $e.WantDC = $e.DC; $settings.Add($e); $byGuid[$e.Guid] = $e } }
        }
        if (-not $e) { $missing[$r[2]] = $true; continue }
        $v = $r[3]
        if ('min' -eq $v) { $v = $e.Min }
        $e.WantAC = [long]$v
        $e.WantDC = [long]$v
        $e.Name = $r[2]
    }
    foreach ($e in $settings) {
        $name = $e.Name
        if (-not $name) { $name = $e.Guid }
        foreach ($which in 'AC', 'DC') {
            $now = $e.$which
            $want = $e."Want$which"
            if ($null -eq $want -or $want -eq $now) { continue }
            $where = 'plugged in'
            if ($which -eq 'DC') { $where = 'on battery' }
            if (Set-Index $plan.Guid $e $which $want) {
                Say ("  {0}: {1}, {2}: {3} -> {4}" -f $label, $name, $where, $now, $want)
                $changed++
            } else {
                Say ("  {0}: {1}, {2}: could not set {3} (stays {4})" -f $label, $name, $where, $want, $now) 'Yellow'
                $failed++
            }
        }
    }
}
foreach ($k in $missing.Keys) { Say "  not in this Windows (left alone): $k" }

# The active plan takes the new values now.
if ($active) { & powercfg /setactive $active 2>$null | Out-Null }

$hib = $null
try { $hib = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction Stop).HibernateEnabled } catch {}
if ($hib -ne 0) {
    & powercfg /h off 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Say '  hibernation: on -> off'; $changed++ }
    else { Say '  hibernation: powercfg /h off failed' 'Yellow'; $failed++ }
}

# Energy saver cannot be switched off with powercfg: it is only reported (it never turns on by itself now).
try {
    $es = [Windows.System.Power.PowerManager, Windows.System.Power, ContentType = WindowsRuntime]::EnergySaverStatus
    if ([string]$es -eq 'On') { Say '  energy saver is on right now: turn it off in Quick Settings (it will not turn on by itself again)' 'Yellow' }
} catch {}

if ($changed -eq 0 -and $failed -eq 0) { Say 'Nothing to change: every plan was already set.' 'Green' }
elseif ($failed -eq 0) { Say "Done: $changed change(s) in $($plans.Count) power plan(s)." 'Green' }
else { Say "Done with problems: $changed change(s), $failed failure(s)." 'Yellow' }
Send
