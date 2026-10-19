<#
  FreeSync HDR Fix
  ----------------
  Turns off AMD "FreeSync Premium Pro" HDR (GPU-side tone mapping) on a monitor
  while KEEPING normal FreeSync / VRR, so games and the monitor handle HDR
  tone mapping themselves (HDR10 / ST.2084, Game HDR available).

  How: it reads the monitor's real EDID from the registry, replaces the AMD
  FreeSync data block (version 2/3 = Premium Pro) with a basic version-1
  FreeSync block that has the SAME refresh range, and installs the result as
  an EDID override - the same mechanism CRU uses. Nothing else in the EDID
  is touched. It does NOT delete FreeSync.

  Modes:
    -Mode Check   Show what would change. Changes nothing. (default)
    -Mode Apply   Install the override and restart the graphics driver.
    -Mode Revert  Remove the override this script installed and restart.

  Run as administrator. Re-run Apply after an AMD driver update if FreeSync
  Premium Pro comes back.
#>
[CmdletBinding()]
param(
    [ValidateSet('Check', 'Apply', 'Revert')]
    [string]$Mode = 'Check',
    [string]$RestartExe = ''
)

$ErrorActionPreference = 'Stop'
$MarkerName = 'FreeSyncHDRFix_Applied'

# ---------------------------------------------------------------- EDID helpers

function Get-EdidChecksum([byte[]]$Block) {
    $sum = 0
    for ($i = 0; $i -lt 127; $i++) { $sum += $Block[$i] }
    return [byte]((256 - ($sum % 256)) % 256)
}

function Test-EdidValid([byte[]]$Edid) {
    if ($null -eq $Edid -or $Edid.Length -lt 128 -or ($Edid.Length % 128) -ne 0) { return $false }
    $header = @(0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00)
    for ($i = 0; $i -lt 8; $i++) { if ($Edid[$i] -ne $header[$i]) { return $false } }
    for ($b = 0; $b -lt $Edid.Length / 128; $b++) {
        $sum = 0
        for ($i = 0; $i -lt 128; $i++) { $sum += $Edid[$b * 128 + $i] }
        if (($sum % 256) -ne 0) { return $false }
    }
    return $true
}

function Get-EdidManufacturer([byte[]]$Edid) {
    $v = ([int]$Edid[8] -shl 8) -bor $Edid[9]
    $c1 = [char](((($v -shr 10) -band 0x1F)) + 64)
    $c2 = [char](((($v -shr 5) -band 0x1F)) + 64)
    $c3 = [char](((($v) -band 0x1F)) + 64)
    return "$c1$c2$c3"
}

function Get-EdidName([byte[]]$Edid) {
    foreach ($off in 54, 72, 90, 108) {
        if ($Edid[$off] -eq 0 -and $Edid[$off + 1] -eq 0 -and $Edid[$off + 3] -eq 0xFC) {
            $chars = @()
            for ($i = $off + 5; $i -lt $off + 18; $i++) {
                if ($Edid[$i] -eq 0x0A) { break }
                $chars += [char]$Edid[$i]
            }
            return (-join $chars).Trim()
        }
    }
    return '(no name)'
}

# Finds AMD vendor-specific data blocks (OUI 00-00-1A) in every CTA-861 extension.
function Find-AmdVsdb([byte[]]$Edid) {
    $found = @()
    $blocks = [int]($Edid.Length / 128)
    for ($b = 1; $b -lt $blocks; $b++) {
        $base = $b * 128
        if ($Edid[$base] -ne 0x02) { continue }          # not a CTA-861 block
        $dtdStart = [int]$Edid[$base + 2]
        if ($dtdStart -lt 4) { continue }                  # no data block collection
        $pos = 4
        while ($pos -lt $dtdStart) {
            $hdr = $Edid[$base + $pos]
            $tag = $hdr -shr 5
            $len = $hdr -band 0x1F
            if ($tag -eq 3 -and $len -ge 8 -and
                $Edid[$base + $pos + 1] -eq 0x1A -and $Edid[$base + $pos + 2] -eq 0x00 -and $Edid[$base + $pos + 3] -eq 0x00) {
                $p = $base + $pos + 1                      # payload start (first OUI byte)
                $version = [int]$Edid[$p + 3]
                $minHz = [int]$Edid[$p + 5]
                $maxHz = [int]$Edid[$p + 6]
                if ($version -ge 3 -and $len -ge 15) {
                    $ext = [int]$Edid[$p + 13] -bor (([int]$Edid[$p + 14] -band 0x3) -shl 8)
                    if ($len -ge 21) { $ext = $ext -bor (([int]$Edid[$p + 20] -band 0x3) -shl 10) }
                    if ($ext -gt $maxHz) { $maxHz = $ext }
                }
                $found += [pscustomobject]@{
                    Block   = $b
                    Offset  = $pos
                    Length  = $len
                    Version = $version
                    Caps    = [int]$Edid[$p + 4]
                    MinHz   = $minHz
                    MaxHz   = $maxHz
                    VcpCode = [int]$Edid[$p + 7]
                }
            }
            $pos += $len + 1
        }
    }
    return , $found
}

# Returns a new EDID with every Premium Pro (v2+) AMD block replaced by a v1 block.
function Convert-EdidToBasicFreeSync([byte[]]$Edid) {
    $out = [byte[]]$Edid.Clone()
    $vsdbs = Find-AmdVsdb $out
    $premium = @($vsdbs | Where-Object { $_.Version -ge 2 })
    if ($premium.Count -eq 0) { return $null }

    foreach ($v in ($premium | Sort-Object Block, Offset -Descending)) {
        if ($v.MaxHz -gt 255 -or $v.MinHz -lt 1 -or $v.MinHz -ge $v.MaxHz) {
            throw "FreeSync range $($v.MinHz)-$($v.MaxHz) Hz can't be stored in a basic FreeSync block. Nothing was changed."
        }
        $base = $v.Block * 128
        $block = New-Object byte[] 128
        [Array]::Copy($out, $base, $block, 0, 128)

        # Basic FreeSync block: tag 3 / length 8, AMD OUI, version 1,
        # FreeSync supported, same min/max refresh, same MCCS VCP code.
        $newDb = [byte[]](0x68, 0x1A, 0x00, 0x00, 0x01, 0x01, [byte]$v.MinHz, [byte]$v.MaxHz, [byte]$v.VcpCode)
        $oldSize = $v.Length + 1
        $delta = $oldSize - $newDb.Length

        $rebuilt = New-Object System.Collections.Generic.List[byte]
        for ($i = 0; $i -lt $v.Offset; $i++) { $rebuilt.Add($block[$i]) }
        $rebuilt.AddRange($newDb)
        for ($i = $v.Offset + $oldSize; $i -lt 127; $i++) { $rebuilt.Add($block[$i]) }
        while ($rebuilt.Count -lt 127) { $rebuilt.Add(0) }

        $newBlock = $rebuilt.ToArray()
        $newBlock = [byte[]]($newBlock + [byte]0)
        $newBlock[2] = [byte]($block[2] - $delta)       # data block collection got shorter
        $newBlock[127] = Get-EdidChecksum $newBlock
        [Array]::Copy($newBlock, 0, $out, $base, 128)
    }

    if (-not (Test-EdidValid $out)) { throw 'Internal error: rebuilt EDID failed validation. Nothing was changed.' }
    $after = Find-AmdVsdb $out
    if (@($after | Where-Object { $_.Version -ge 2 }).Count -ne 0 -or @($after).Count -ne @($vsdbs).Count) {
        throw 'Internal error: FreeSync block was not rewritten correctly. Nothing was changed.'
    }
    return , $out
}

# Stop here when dot-sourced for testing.
if ($env:FSFIX_NO_MAIN) { return }

# ---------------------------------------------------------------- main

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and $Mode -ne 'Check') {
    Write-Host 'Please run this as administrator (use the .bat files, they ask for it).' -ForegroundColor Red
    exit 1
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$backupDir = Join-Path $scriptDir 'Backups'

function Find-RestartExe {
    $candidates = @()
    if ($RestartExe) { $candidates += $RestartExe }
    $candidates += (Join-Path $scriptDir 'restart64.exe')
    $candidates += (Join-Path $env:USERPROFILE 'Downloads\cru-1.5.2\restart64.exe')
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    # Any other CRU folder in Downloads or on the Desktop (cru-1.5.3, CRU, etc.)
    foreach ($root in (Join-Path $env:USERPROFILE 'Downloads'), (Join-Path $env:USERPROFILE 'Desktop')) {
        $hit = Get-ChildItem -Path $root -Filter 'restart64.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -match '(?i)cru' } | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Restart-GraphicsDriver {
    $exe = Find-RestartExe
    if ($exe) {
        Write-Host ''
        Write-Host 'Restarting the graphics driver (screens go black for a few seconds)...' -ForegroundColor Cyan
        Start-Process -FilePath $exe -Wait
        Write-Host 'Done.' -ForegroundColor Green
    } else {
        Write-Host ''
        Write-Host "CRU's restart64.exe wasn't found. Restart your PC to apply the change." -ForegroundColor Yellow
    }
}

$displayRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY'
$targets = @()
foreach ($model in Get-ChildItem $displayRoot -ErrorAction SilentlyContinue) {
    foreach ($inst in Get-ChildItem $model.PSPath -ErrorAction SilentlyContinue) {
        $dp = Join-Path $inst.PSPath 'Device Parameters'
        if (-not (Test-Path $dp)) { continue }
        $edid = (Get-ItemProperty -Path $dp -Name EDID -ErrorAction SilentlyContinue).EDID
        if ($null -eq $edid -or -not (Test-EdidValid ([byte[]]$edid))) { continue }
        $edid = [byte[]]$edid
        $props = Get-ItemProperty -Path $dp -ErrorAction SilentlyContinue
        $targets += [pscustomobject]@{
            Id          = "$($model.PSChildName)\$($inst.PSChildName)"
            ParamsPath  = $dp
            RegName     = "$($inst.Name)\Device Parameters"
            Edid        = $edid
            Name        = Get-EdidName $edid
            Maker       = Get-EdidManufacturer $edid
            Vsdbs       = Find-AmdVsdb $edid
            HasOverride = Test-Path (Join-Path $dp 'EDID_OVERRIDE')
            Ours        = ($null -ne $props.$MarkerName)
        }
    }
}

Write-Host ''
Write-Host "FreeSync HDR Fix - mode: $Mode" -ForegroundColor Cyan
Write-Host '-------------------------------------------'

$changed = 0
foreach ($t in $targets) {
    $premium = @($t.Vsdbs | Where-Object { $_.Version -ge 2 })
    $basic = @($t.Vsdbs | Where-Object { $_.Version -eq 1 })

    if ($Mode -eq 'Revert') {
        if ($t.Ours) {
            Remove-Item -Path (Join-Path $t.ParamsPath 'EDID_OVERRIDE') -Recurse -Force -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $t.ParamsPath -Name $MarkerName -ErrorAction SilentlyContinue
            Write-Host "Restored original EDID (FreeSync Premium Pro back): $($t.Name) [$($t.Id)]" -ForegroundColor Green
            $changed++
        }
        continue
    }

    if ($premium.Count -eq 0) {
        if ($basic.Count -gt 0) {
            Write-Host "$($t.Name) [$($t.Id)]: basic FreeSync only, nothing to change." -ForegroundColor DarkGray
        }
        continue
    }

    $p = $premium[0]
    Write-Host "$($t.Maker) $($t.Name) [$($t.Id)]" -ForegroundColor White
    Write-Host "  FreeSync Premium Pro block found (AMD block version $($p.Version)), range $($p.MinHz)-$($p.MaxHz) Hz"
    Write-Host "  Will become: basic FreeSync, range $($p.MinHz)-$($p.MaxHz) Hz (VRR kept, Premium Pro HDR removed)"
    if ($t.HasOverride -and -not $t.Ours) {
        Write-Host '  Note: an older CRU override exists here; it will be backed up and replaced.' -ForegroundColor Yellow
    }

    $newEdid = Convert-EdidToBasicFreeSync $t.Edid

    if ($Mode -eq 'Check') { continue }

    # Back up: original EDID + any existing override.
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeId = ($t.Id -replace '[\\/:*?"<>|]', '_')
    [IO.File]::WriteAllBytes((Join-Path $backupDir "$safeId-original-$stamp.bin"), $t.Edid)
    [IO.File]::WriteAllBytes((Join-Path $backupDir "$safeId-modified-$stamp.bin"), $newEdid)
    if ($t.HasOverride) {
        & reg.exe export "$($t.RegName)\EDID_OVERRIDE" (Join-Path $backupDir "$safeId-previous-override-$stamp.reg") /y | Out-Null
    }

    # Install override (same layout CRU uses: one 128-byte value per EDID block).
    $ovr = Join-Path $t.ParamsPath 'EDID_OVERRIDE'
    if (Test-Path $ovr) { Remove-Item -Path $ovr -Recurse -Force }
    New-Item -Path $ovr -Force | Out-Null
    for ($b = 0; $b -lt $newEdid.Length / 128; $b++) {
        $chunk = New-Object byte[] 128
        [Array]::Copy($newEdid, $b * 128, $chunk, 0, 128)
        New-ItemProperty -Path $ovr -Name "$b" -PropertyType Binary -Value $chunk -Force | Out-Null
    }
    New-ItemProperty -Path $t.ParamsPath -Name $MarkerName -PropertyType DWord -Value 1 -Force | Out-Null
    Write-Host '  Applied.' -ForegroundColor Green
    $changed++
}

Write-Host ''
if ($Mode -eq 'Check') {
    Write-Host 'Check only - nothing was changed. Run "2 - Remove FreeSync Premium Pro.bat" to apply.' -ForegroundColor Cyan
} elseif ($changed -eq 0) {
    if ($Mode -eq 'Revert') { Write-Host 'Nothing to restore - this script has not changed any display.' -ForegroundColor Yellow }
    else { Write-Host 'No monitor with FreeSync Premium Pro was found. Nothing was changed.' -ForegroundColor Yellow }
} else {
    Restart-GraphicsDriver
    if ($Mode -eq 'Apply') {
        Write-Host ''
        Write-Host 'Next: make sure FreeSync is on in AMD Software, turn on HDR in Windows,' -ForegroundColor Cyan
        Write-Host 'and check that the monitor now offers ST.2084 gamma and Game HDR.' -ForegroundColor Cyan
    }
}
