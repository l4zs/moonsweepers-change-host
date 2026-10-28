<#
  Swap who owns the host ("local") player data in a MoonSweepers save.

  Put this script in the MoonSweepers folder (%USERPROFILE%\AppData\LocalLow\DragDropGames\MoonSweepers),
  next to MoonSessions, or pass -SessionsDir.

  Interactive:
    powershell -ExecutionPolicy Bypass -File swap-host.ps1

  Direct:
    powershell -ExecutionPolicy Bypass -File swap-host.ps1 <new host> <current host's account> [-Slot slot-2] [-DryRun]

    Players can be given as a SteamID64, a steamcommunity.com profile link (/profiles/... or /id/...),
    or a custom profile name.

  The game must be closed. A full backup of the slot is made before anything is written.
  Who is currently host per slot is remembered in swap-host-known.json next to this script.
#>
param(
    [Parameter(Position = 0)][string]$MakeLocal,
    [Parameter(Position = 1)][string]$LocalBecomes,
    [string]$Slot,
    [string]$SessionsDir,
    [switch]$DryRun,
    [switch]$Offline,
    [switch]$Yes
)
$ErrorActionPreference = "Stop"
$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $SessionsDir) { $SessionsDir = Join-Path $baseDir "MoonSessions" }
$knownFile = Join-Path $baseDir "swap-host-known.json"

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

public static class MoonSwap
{
    static bool IsIdAt(byte[] d, int p, out int n)
    {
        n = 0;
        if (p + 5 <= d.Length && d[p] == 'l' && d[p+1] == 'o' && d[p+2] == 'c' && d[p+3] == 'a' && d[p+4] == 'l') { n = 5; return true; }
        if (p + 23 <= d.Length && d[p] == 's' && d[p+1] == 't' && d[p+2] == 'e' && d[p+3] == 'a' && d[p+4] == 'm' && d[p+5] == '-')
        {
            for (int i = 6; i < 23; i++) if (d[p+i] < '0' || d[p+i] > '9') return false;
            n = 23; return true;
        }
        return false;
    }

    // Rewrites player IDs inside length-prefixed strings, either standalone or as the tail of "a/b/<id>".
    public static byte[] Transform(byte[] d, Dictionary<string, string> map, Dictionary<string, int> counts)
    {
        var o = new MemoryStream();
        int copied = 0, p = 0;
        while (p < d.Length)
        {
            int n;
            if (!IsIdAt(d, p, out n)) { p++; continue; }
            string id = Encoding.ASCII.GetString(d, p, n);
            int end = p + n, lenPos = -1;
            if (p >= 1 && d[p-1] == n) lenPos = p - 1;
            else if (p >= 1 && d[p-1] == '/')
            {
                for (int j = p - 2; j >= 0 && j >= p - 120; j--)
                {
                    if (d[j] == end - j - 1 && d[j+1] >= 'a' && d[j+1] <= 'z') { lenPos = j; break; }
                    if (d[j] < 0x20 || d[j] > 0x7e) break;
                }
            }
            if (lenPos < 0 || lenPos < copied) throw new Exception("Unrecognised data around '" + id + "' at offset " + p + ", aborting");

            counts[id] = (counts.ContainsKey(id) ? counts[id] : 0) + 1;
            string full = Encoding.ASCII.GetString(d, lenPos + 1, end - lenPos - 1);
            string newId = map.ContainsKey(id) ? map[id] : id;
            byte[] ns = Encoding.ASCII.GetBytes(full.Substring(0, full.Length - n) + newId);
            if (ns.Length > 127) throw new Exception("String too long: " + full);
            o.Write(d, copied, lenPos - copied);
            o.WriteByte((byte)ns.Length);
            o.Write(ns, 0, ns.Length);
            copied = p = end;
        }
        o.Write(d, copied, d.Length - copied);
        return o.ToArray();
    }

    // Player display names are stored as  27 B9 29 ?? <id> <name>  in the session.
    public static Dictionary<string, string> ReadNames(byte[] d)
    {
        var names = new Dictionary<string, string>();
        for (int p = 0; p + 6 < d.Length; p++)
        {
            if (d[p] != 0x27 || d[p+1] != 0xB9 || d[p+2] != 0x29) continue;
            int q = p + 4, n;
            if (q + 1 >= d.Length || !IsIdAt(d, q + 1, out n) || d[q] != n) continue;
            int nl = q + 1 + n, len = d[nl];
            if (len < 1 || len > 127 || nl + 1 + len > d.Length) continue;
            bool ok = true;
            for (int i = 0; i < len; i++) if (d[nl + 1 + i] < 0x20 || d[nl + 1 + i] == 0x7f) { ok = false; break; }
            if (ok) names[Encoding.ASCII.GetString(d, q + 1, n)] = Encoding.UTF8.GetString(d, nl + 1, len);
        }
        return names;
    }

    static string Sha256Hex(byte[] b)
    {
        using (var s = SHA256.Create())
        {
            var sb = new StringBuilder();
            foreach (var x in s.ComputeHash(b)) sb.Append(x.ToString("x2"));
            return sb.ToString();
        }
    }

    // 1PCM container: magic, int32 raw length, 7-bit-prefixed sha256 hex of raw, gzip(raw)
    public static byte[] Unpack(byte[] f)
    {
        if (Encoding.ASCII.GetString(f, 0, 4) != "1PCM" || f[8] != 0x40) throw new Exception("Not a 1PCM file");
        int len = BitConverter.ToInt32(f, 4);
        string hash = Encoding.ASCII.GetString(f, 9, 64);
        byte[] raw;
        using (var gz = new GZipStream(new MemoryStream(f, 73, f.Length - 73), CompressionMode.Decompress))
        using (var ms = new MemoryStream()) { gz.CopyTo(ms); raw = ms.ToArray(); }
        if (raw.Length != len || Sha256Hex(raw) != hash) throw new Exception("Save file is corrupt (size/hash mismatch)");
        return raw;
    }

    public static byte[] Pack(byte[] raw)
    {
        var o = new MemoryStream();
        o.Write(Encoding.ASCII.GetBytes("1PCM"), 0, 4);
        o.Write(BitConverter.GetBytes(raw.Length), 0, 4);
        o.WriteByte(0x40);
        var h = Encoding.ASCII.GetBytes(Sha256Hex(raw));
        o.Write(h, 0, h.Length);
        using (var gz = new GZipStream(o, CompressionMode.Compress, true)) gz.Write(raw, 0, raw.Length);
        return o.ToArray();
    }
}
'@

# ---------- Steam lookups ----------

$webCache = @{}
function Get-SteamXml([string]$url) {
    if ($Offline) { return $null }
    if ($webCache.ContainsKey($url)) { return $webCache[$url] }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $wc = New-Object Net.WebClient
        $wc.Encoding = [Text.Encoding]::UTF8
        $xml = $wc.DownloadString($url)
    } catch { $xml = $null }
    $webCache[$url] = $xml
    $xml
}

function Get-SteamName([string]$steamId) {
    $xml = Get-SteamXml "https://steamcommunity.com/profiles/$($steamId -replace '^steam-','')/?xml=1"
    if ($xml -and $xml -match '<steamID><!\[CDATA\[(.*?)\]\]></steamID>') { return $matches[1] }
    $null
}

# Accepts a SteamID64, "steam-<id>", a /profiles/ or /id/ link, or a custom URL name. Returns "steam-<id>".
function Resolve-SteamId([string]$text) {
    $t = $text.Trim().Trim('"')
    if ($t -match '^(steam-)?(?<id>7656\d{13})$' -or $t -match 'steamcommunity\.com/profiles/(?<id>7656\d{13})') { return "steam-$($matches['id'])" }
    $vanity = $null
    if ($t -match 'steamcommunity\.com/id/([^/?#\s]+)') { $vanity = $matches[1] }
    elseif ($t -match '^[A-Za-z0-9_-]{2,32}$') { $vanity = $t }
    if ($vanity) {
        if ($Offline) { throw "Can't look up '$vanity' in offline mode - use the 17-digit Steam ID" }
        $xml = Get-SteamXml "https://steamcommunity.com/id/$vanity/?xml=1"
        if ($xml -and $xml -match '<steamID64>(\d{17})</steamID64>') { return "steam-$($matches[1])" }
        throw "Couldn't find a Steam profile for '$vanity' (no internet, or the link is wrong)"
    }
    throw "'$text' is not a Steam ID or profile link"
}

# ---------- remembered hosts / names ----------

$known = @{ hosts = @{}; names = @{} }
if (Test-Path $knownFile) {
    $j = Get-Content $knownFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($section in 'hosts', 'names') {
        if ($j.$section) { foreach ($p in $j.$section.PSObject.Properties) { $known[$section][$p.Name] = $p.Value } }
    }
}

function Get-DisplayName([string]$id, $saveNames) {
    $n = Get-SteamName $id
    if ($n) { $known.names[$id] = $n; return $n }
    if ($known.names.ContainsKey($id)) { return $known.names[$id] }
    if ($saveNames.ContainsKey($id)) { return $saveNames[$id] }
    "?"
}

function Read-Choice([string]$prompt) {
    $answer = Read-Host $prompt
    if ($answer -match '^\s*(q|quit|exit)\s*$') { throw "Cancelled." }
    $answer
}

# ---------- main ----------

try {
    if (Get-Process | Where-Object { $_.ProcessName -match 'moon' }) { throw "MoonSweepers seems to be running - close the game first" }

    # Pick the slot
    if (-not $Slot) {
        $slots = @(Get-ChildItem $SessionsDir -Directory | Where-Object { $_.Name -match '^slot-' } | Sort-Object Name)
        if ($slots.Count -eq 0) { throw "No save slots found in $SessionsDir" }
        if ($slots.Count -eq 1) { $Slot = $slots[0].Name }
        else {
            Write-Host "Save slots:"
            for ($i = 0; $i -lt $slots.Count; $i++) {
                $info = ""
                $sj = Join-Path $slots[$i].FullName "slot.json"
                if (Test-Path $sj) {
                    $s = Get-Content $sj -Raw | ConvertFrom-Json
                    $info = "{0:N0} `$, {1:N1} h played, last played {2}" -f $s.dollars, ($s.playSeconds / 3600), (New-Object DateTime ([long]$s.lastPlayedTicks), ([DateTimeKind]::Utc)).ToLocalTime().ToString('g')
                }
                Write-Host ("  {0}) {1}   {2}" -f ($i + 1), $slots[$i].Name, $info)
            }
            $n = Read-Choice "Which slot? (number)"
            if ($n -notmatch '^\d+$' -or [int]$n -lt 1 -or [int]$n -gt $slots.Count) { throw "Invalid choice '$n'" }
            $Slot = $slots[[int]$n - 1].Name
        }
    }

    $slotDir = Join-Path $SessionsDir $Slot
    if (-not (Test-Path $slotDir)) { throw "Save slot not found: $slotDir" }
    $worlds = @(Get-ChildItem $slotDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName "session.moon") })
    if ($worlds.Count -ne 1) { throw "Expected exactly one world folder with session.moon in $slotDir, found $($worlds.Count)" }
    $world = $worlds[0].FullName

    # Who is in this save?
    $sessionRaw = [MoonSwap]::Unpack([IO.File]::ReadAllBytes((Join-Path $world "session.moon")))
    $present = New-Object 'System.Collections.Generic.Dictionary[string,int]'
    [void][MoonSwap]::Transform($sessionRaw, (New-Object 'System.Collections.Generic.Dictionary[string,string]'), $present)
    $saveNames = [MoonSwap]::ReadNames($sessionRaw)
    $players = @($present.Keys | Where-Object { $_ -ne 'local' } | Sort-Object)
    $hostId = if ($known.hosts.ContainsKey($Slot)) { $known.hosts[$Slot] } else { $null }

    Write-Host ""
    Write-Host "Players in $Slot$(if (-not $Offline) { ' (looking up Steam names...)' }):"
    $hostName = if ($hostId) { Get-DisplayName $hostId $saveNames } elseif ($saveNames.ContainsKey('local')) { $saveNames['local'] } else { '?' }
    Write-Host ("  host  {0,-24} {1}" -f $hostName, $(if ($hostId) { $hostId -replace '^steam-','' } else { '(Steam ID unknown)' }))
    for ($i = 0; $i -lt $players.Count; $i++) {
        Write-Host ("  {0,-5} {1,-24} {2}" -f "$($i + 1))", (Get-DisplayName $players[$i] $saveNames), ($players[$i] -replace '^steam-',''))
    }
    Write-Host ""

    # New host
    if (-not $MakeLocal) {
        $MakeLocal = Read-Choice "Who should become the host? (number, Steam ID or profile link, q = quit)"
        if ($MakeLocal -match '^\s*\d{1,2}\s*$') {
            $n = [int]$MakeLocal
            if ($n -lt 1 -or $n -gt $players.Count) { throw "Invalid choice '$n'" }
            $MakeLocal = $players[$n - 1]
        }
    }
    $newLocal = Resolve-SteamId $MakeLocal
    if (-not $present.ContainsKey($newLocal)) { throw "$newLocal has no data in this save - they need to have joined this world at least once" }

    # Where the current host's data goes
    if (-not $LocalBecomes) {
        if ($hostId -and $hostId -ne $newLocal) {
            $LocalBecomes = Read-Choice "Current host '$hostName' - which Steam account is that? (Enter = $($hostId -replace '^steam-',''), or paste ID / profile link)"
            if (-not $LocalBecomes.Trim()) { $LocalBecomes = $hostId }
        } else {
            $LocalBecomes = Read-Choice "Current host '$hostName' - which Steam account is that? (paste Steam ID or profile link)"
        }
    }
    $oldLocal = Resolve-SteamId $LocalBecomes
    if ($oldLocal -eq $newLocal) { throw "The new host and the current host can't be the same account" }
    if ($present.ContainsKey($oldLocal)) { throw "$oldLocal already has its own data in this save - refusing to merge two players" }

    $newName = Get-DisplayName $newLocal $saveNames
    $oldName = Get-DisplayName $oldLocal $saveNames
    Write-Host ""
    Write-Host "  $newName ($($newLocal -replace '^steam-','')) becomes the host"
    Write-Host "  current host's data moves to $oldName ($($oldLocal -replace '^steam-',''))"
    Write-Host ""

    $map = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $map['local'] = $oldLocal
    $map[$newLocal] = 'local'

    # Convert everything in memory first; only write once all files succeeded.
    $results = @()
    foreach ($name in 'session.moon', 'session.moon.bak', 'live.moon') {
        $path = Join-Path $world $name
        if (-not (Test-Path $path)) { continue }
        $bytes = [IO.File]::ReadAllBytes($path)
        $packed = $name -ne 'live.moon'
        $data = if ($packed) { [MoonSwap]::Unpack($bytes) } else { $bytes }
        $counts = New-Object 'System.Collections.Generic.Dictionary[string,int]'
        $out = [MoonSwap]::Transform($data, $map, $counts)
        if ($counts.ContainsKey($oldLocal)) { throw "$name already contains $oldLocal - refusing to merge two players" }
        if ($packed) { $out = [MoonSwap]::Pack($out); [void][MoonSwap]::Unpack($out) }
        $c = { param($k) if ($counts.ContainsKey($k)) { $counts[$k] } else { 0 } }
        Write-Host ("  {0,-17} {1,5} host entries moved, {2,5} entries of the new host" -f $name, (& $c 'local'), (& $c $newLocal))
        $results += ,@($path, $out)
    }

    if ($DryRun) { Write-Host "`nDry run - nothing written."; return }
    if (-not $Yes) {
        $ok = Read-Host "`nApply? (y/n)"
        if ($ok -notmatch '^\s*y') { throw "Cancelled, nothing written." }
    }

    $backup = Join-Path (Split-Path $SessionsDir) ("$Slot-backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item $slotDir $backup -Recurse
    Write-Host "Backup: $backup"

    foreach ($r in $results) {
        $time = (Get-Item $r[0]).LastWriteTime
        [IO.File]::WriteAllBytes($r[0], $r[1])
        (Get-Item $r[0]).LastWriteTime = $time
    }

    $known.hosts[$Slot] = $newLocal
    $known | ConvertTo-Json | Set-Content $knownFile -Encoding UTF8
    Write-Host "Done. $newName is now the host of $Slot."
}
catch {
    Write-Host "`n$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
