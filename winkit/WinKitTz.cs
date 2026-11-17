// SPDX-License-Identifier: GPL-2.0-or-later
// WinKit time zone: turns the iPhone's time zone (an IANA name such as "Asia/Shanghai", from the app's
// http://10.0.2.4/tz.txt) into Windows' zone ("China Standard Time") and sets it with tzutil. The mapping is
// Windows' own ICU (icu.dll, Windows 10 1903 and later: ucal_getWindowsTimeZoneID), so it matches the zones
// this Windows has; a short table covers common zones if that call is missing. Setting the zone needs no
// administrator rights (the Users group holds the time zone privilege by default).
// Loaded with Add-Type by the WinKit helper (agent.ps1, from cli_setup.ps1) and by clock_setup.ps1.
// C# 5 (Windows PowerShell 5.1 compiles it with the .NET Framework compiler).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class WinKitTz {
    [DllImport("icu.dll", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    static extern int ucal_getWindowsTimeZoneID(string id, int len, StringBuilder winid, int winidCapacity, ref int status);

    static readonly Dictionary<string, string> Table = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
        {"UTC", "UTC"}, {"Etc/UTC", "UTC"}, {"Etc/GMT", "UTC"}, {"GMT", "UTC"}, {"Etc/Universal", "UTC"},
        {"Asia/Shanghai", "China Standard Time"}, {"Asia/Chongqing", "China Standard Time"},
        {"Asia/Harbin", "China Standard Time"}, {"Asia/Hong_Kong", "China Standard Time"},
        {"Asia/Macau", "China Standard Time"}, {"PRC", "China Standard Time"},
        {"Asia/Taipei", "Taipei Standard Time"}, {"Asia/Tokyo", "Tokyo Standard Time"},
        {"Asia/Seoul", "Korea Standard Time"}, {"Asia/Singapore", "Singapore Standard Time"},
        {"Asia/Kuala_Lumpur", "Singapore Standard Time"}, {"Asia/Manila", "Singapore Standard Time"},
        {"Asia/Bangkok", "SE Asia Standard Time"}, {"Asia/Jakarta", "SE Asia Standard Time"},
        {"Asia/Ho_Chi_Minh", "SE Asia Standard Time"}, {"Asia/Saigon", "SE Asia Standard Time"},
        {"Asia/Kolkata", "India Standard Time"}, {"Asia/Calcutta", "India Standard Time"},
        {"Asia/Kathmandu", "Nepal Standard Time"}, {"Asia/Dhaka", "Bangladesh Standard Time"},
        {"Asia/Karachi", "Pakistan Standard Time"}, {"Asia/Dubai", "Arabian Standard Time"},
        {"Asia/Riyadh", "Arab Standard Time"}, {"Asia/Jerusalem", "Israel Standard Time"},
        {"Europe/London", "GMT Standard Time"}, {"Europe/Dublin", "GMT Standard Time"},
        {"Europe/Lisbon", "GMT Standard Time"}, {"Europe/Paris", "Romance Standard Time"},
        {"Europe/Brussels", "Romance Standard Time"}, {"Europe/Madrid", "Romance Standard Time"},
        {"Europe/Berlin", "W. Europe Standard Time"}, {"Europe/Amsterdam", "W. Europe Standard Time"},
        {"Europe/Rome", "W. Europe Standard Time"}, {"Europe/Vienna", "W. Europe Standard Time"},
        {"Europe/Zurich", "W. Europe Standard Time"}, {"Europe/Stockholm", "W. Europe Standard Time"},
        {"Europe/Oslo", "W. Europe Standard Time"}, {"Europe/Warsaw", "Central European Standard Time"},
        {"Europe/Prague", "Central Europe Standard Time"}, {"Europe/Budapest", "Central Europe Standard Time"},
        {"Europe/Athens", "GTB Standard Time"}, {"Europe/Bucharest", "GTB Standard Time"},
        {"Europe/Helsinki", "FLE Standard Time"}, {"Europe/Kiev", "FLE Standard Time"},
        {"Europe/Kyiv", "FLE Standard Time"}, {"Europe/Istanbul", "Turkey Standard Time"},
        {"Europe/Moscow", "Russian Standard Time"},
        {"Africa/Cairo", "Egypt Standard Time"}, {"Africa/Johannesburg", "South Africa Standard Time"},
        {"Africa/Lagos", "W. Central Africa Standard Time"}, {"Africa/Nairobi", "E. Africa Standard Time"},
        {"America/New_York", "Eastern Standard Time"}, {"America/Detroit", "Eastern Standard Time"},
        {"America/Toronto", "Eastern Standard Time"}, {"America/Chicago", "Central Standard Time"},
        {"America/Winnipeg", "Central Standard Time"}, {"America/Denver", "Mountain Standard Time"},
        {"America/Edmonton", "Mountain Standard Time"}, {"America/Phoenix", "US Mountain Standard Time"},
        {"America/Los_Angeles", "Pacific Standard Time"}, {"America/Vancouver", "Pacific Standard Time"},
        {"America/Anchorage", "Alaskan Standard Time"}, {"Pacific/Honolulu", "Hawaiian Standard Time"},
        {"America/Halifax", "Atlantic Standard Time"}, {"America/Mexico_City", "Central Standard Time (Mexico)"},
        {"America/Bogota", "SA Pacific Standard Time"}, {"America/Lima", "SA Pacific Standard Time"},
        {"America/Sao_Paulo", "E. South America Standard Time"},
        {"America/Argentina/Buenos_Aires", "Argentina Standard Time"}, {"America/Buenos_Aires", "Argentina Standard Time"},
        {"Australia/Sydney", "AUS Eastern Standard Time"}, {"Australia/Melbourne", "AUS Eastern Standard Time"},
        {"Australia/Brisbane", "E. Australia Standard Time"}, {"Australia/Perth", "W. Australia Standard Time"},
        {"Australia/Adelaide", "Cen. Australia Standard Time"}, {"Pacific/Auckland", "New Zealand Standard Time"},
    };

    static bool Exists(string win) {
        try { TimeZoneInfo.FindSystemTimeZoneById(win); return true; } catch { return false; }
    }

    // Windows' id for an IANA name, or null when neither ICU nor the table knows it (or this Windows lacks it).
    public static string ToWindows(string iana) {
        if (string.IsNullOrEmpty(iana)) return null;
        try {
            var sb = new StringBuilder(128);
            int status = 0;
            int n = ucal_getWindowsTimeZoneID(iana, iana.Length, sb, sb.Capacity, ref status);
            if (status <= 0 && n > 0) {
                string w = sb.ToString(0, Math.Min(n, sb.Length));
                if (Exists(w)) return w;
            }
        } catch (Exception) {}   // no icu.dll, or no such export: the table below
        string t;
        if (Table.TryGetValue(iana, out t) && Exists(t)) return t;
        return null;
    }

    // The zone Windows uses now (not the value this process cached at its start).
    public static string Current() {
        TimeZoneInfo.ClearCachedData();
        return TimeZoneInfo.Local.Id;
    }

    // Sets Windows' zone to match the IANA name. Returns the Windows id set (or already set); null when it
    // could not, with the reason in report ("unmapped ...", "failed ...").
    public static string Apply(string iana, out string report) {
        string win = ToWindows(iana);
        if (win == null) { report = "unmapped " + iana; return null; }
        if (string.Equals(Current(), win, StringComparison.OrdinalIgnoreCase)) { report = win; return win; }
        try {
            var psi = new ProcessStartInfo(Environment.ExpandEnvironmentVariables(@"%SystemRoot%\System32\tzutil.exe"),
                                           "/s \"" + win + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            using (var p = Process.Start(psi)) {
                string err = p.StandardError.ReadToEnd() + p.StandardOutput.ReadToEnd();
                if (!p.WaitForExit(15000)) { report = "failed " + win + ": tzutil did not finish"; return null; }
                if (p.ExitCode != 0) { report = "failed " + win + ": tzutil " + p.ExitCode + " " + err.Trim(); return null; }
            }
        } catch (Exception e) { report = "failed " + win + ": " + e.Message; return null; }
        if (!string.Equals(Current(), win, StringComparison.OrdinalIgnoreCase)) {
            report = "failed " + win + ": Windows still uses " + TimeZoneInfo.Local.Id;
            return null;
        }
        report = win;
        return win;
    }
}
