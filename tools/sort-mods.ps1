# Copies the mods from a CurseForge instance that belong on the server, leaving out
# client-only ones (shaders, minimaps, FPS/graphics modsetc.), into Downloads\server-mods.
#
# Run in PowerShell on your PC:
#   irm https://raw.githubusercontent.com/2m3s/aaa/main/tools/sort-mods.ps1 | iex
#
# How it decides, per mod:
#   1. Looks the exact file up on Modrinth, which tags every mod as client/server/both.
#   2. Not on Modrinth: checks the jar's own metadata for client-only markers,
#      then a list of well-known client-only mods.
#   3. Still unsure: copies it anyway and lists it in the report, so a missing
#      server mod doesn't stop players joining.

function Sort-ServerMods {
    $Instance = Join-Path $env:USERPROFILE 'curseforge\minecraft\Instances\server'
    $Dest     = Join-Path $env:USERPROFILE 'Downloads\server-mods'
    $Report   = Join-Path $env:USERPROFILE 'Downloads\server-mods-report.txt'

    $ModsDir = Join-Path $Instance 'mods'
    if (-not (Test-Path $ModsDir)) {
        Write-Host "Couldn't find $ModsDir" -ForegroundColor Yellow
        $Instance = (Read-Host 'Paste the path to your CurseForge instance folder').Trim('"', ' ')
        $ModsDir = Join-Path $Instance 'mods'
        if (-not (Test-Path $ModsDir)) { Write-Host "No mods folder in $Instance" -ForegroundColor Red; return }
    }

    # Warn if the instance isn't the same Minecraft/loader as the server.
    $infoFile = Join-Path $Instance 'minecraftinstance.json'
    if (Test-Path $infoFile) {
        try {
            $info = Get-Content $infoFile -Raw | ConvertFrom-Json
            $loader = $info.baseModLoader.name
            Write-Host "Instance: Minecraft $($info.gameVersion), $loader"
            if ($info.gameVersion -ne '1.21.1' -or $loader -notmatch '^neoforge') {
                Write-Host "WARNING: your server runs NeoForge 1.21.1. Mods for another version or loader won't load on it." -ForegroundColor Yellow
            }
        } catch { }
    }

    $jars = @(Get-ChildItem -Path $ModsDir -Filter '*.jar' -File)
    if ($jars.Count -eq 0) { Write-Host "No .jar files in $ModsDir" -ForegroundColor Red; return }
    Write-Host "Checking $($jars.Count) mods..."

    # --- 1. Modrinth lookup by file hash ---
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ua = '2m3s/aaa sort-mods (github.com/2m3s/aaa)'
    $hashOf = @{}
    foreach ($jar in $jars) { $hashOf[$jar.FullName] = (Get-FileHash -Algorithm SHA1 -LiteralPath $jar.FullName).Hash.ToLower() }

    $projectOfHash = @{}   # sha1 -> project id
    $project = @{}         # project id -> project (title, client_side, server_side)
    $online = $true
    try {
        $body = ConvertTo-Json -Compress -InputObject @{ hashes = @($hashOf.Values); algorithm = 'sha1' }
        $versions = Invoke-RestMethod -Method Post -Uri 'https://api.modrinth.com/v2/version_files' `
            -Body $body -ContentType 'application/json' -UserAgent $ua
        foreach ($p in $versions.PSObject.Properties) { $projectOfHash[$p.Name] = $p.Value.project_id }

        $ids = @($projectOfHash.Values | Sort-Object -Unique)
        for ($i = 0; $i -lt $ids.Count; $i += 50) {
            $batch = @($ids[$i..([Math]::Min($i + 49, $ids.Count - 1))])
            $q = [uri]::EscapeDataString((ConvertTo-Json -Compress -InputObject $batch))
            foreach ($proj in (Invoke-RestMethod -Uri "https://api.modrinth.com/v2/projects?ids=$q" -UserAgent $ua)) {
                $project[$proj.id] = $proj
            }
        }
    } catch {
        $online = $false
        Write-Host "Couldn't reach Modrinth ($($_.Exception.Message)). Falling back to checking the jars only." -ForegroundColor Yellow
    }

    # --- 2. Fallbacks for mods not on Modrinth ---
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    function Get-JarText($path, $entryName) {
        $zip = $null
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
            $entry = $zip.GetEntry($entryName)
            if (-not $entry) { return $null }
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
        } catch { return $null } finally { if ($zip) { $zip.Dispose() } }
    }

    # Well-known mods that only do something on the player's PC (and often crash a server).
    $knownClientOnly = @(
        'sodium', 'embeddium', 'rubidium', 'iris', 'oculus', 'sodium-extra', 'reeses-sodium-options',
        'entityculling', 'entity_?texture_?features', 'entity_?model_?features', 'immediatelyfast',
        'dynamic_?fps', 'dynamiclights', 'lambdynamiclights', 'sodiumdynamiclights', 'fpsreducer',
        'zoomify', 'okzoomer', 'betterf3', 'controlling', 'mousetweaks', 'mouse-tweaks', 'catalogue',
        'xaerominimap', 'xaeros?_?minimap', 'xaeroworldmap', 'xaeros?_?world_?map',
        'notenoughanimations', 'skinlayers3d', '3dskinlayers', 'waveycapes', 'fancymenu',
        'drippyloadingscreen', 'legendarytooltips', 'itemborders', 'visuality', 'fallingleaves',
        'presencefootsteps', 'sound-?physics', 'continuity', 'cull-?less-?leaves', 'betterclouds',
        'particlerain', 'chat_?heads', 'inventoryprofilesnext', 'betterthirdperson', 'shouldersurfing',
        'firstperson', 'enhancedvisuals', 'euphoria', 'blur', 'bettermodsbutton', 'modmenu', 'smoothswapping',
        'clickadv', 'appleskin-client', 'jeresources-client', 'torohealth', 'neat', 'craftpresence',
        'betterpingdisplay', 'fullbright', 'ambientsounds', 'eatinganimation', 'better-?ping', 'replaymod'
    )
    $knownRegex = '^(' + ($knownClientOnly -join '|') + ')([-_+ .\d]|$)'

    $copy = @(); $skip = @(); $unsure = @()
    foreach ($jar in $jars) {
        $name = $jar.Name
        $pid_ = $projectOfHash[$hashOf[$jar.FullName]]
        $proj = if ($pid_) { $project[$pid_] } else { $null }
        if ($proj) {
            $label = "$name  ($($proj.title): client=$($proj.client_side), server=$($proj.server_side))"
            if ($proj.server_side -eq 'unsupported') { $skip += "$label  [Modrinth]" } else { $copy += $jar; }
            continue
        }
        $toml = Get-JarText $jar.FullName 'META-INF/neoforge.mods.toml'
        if (-not $toml) { $toml = Get-JarText $jar.FullName 'META-INF/mods.toml' }
        $fabric = Get-JarText $jar.FullName 'fabric.mod.json'
        if ($toml -and ($toml -match 'displayTest\s*=\s*"IGNORE_ALL_VERSION"' -or $toml -match 'clientSideOnly\s*=\s*true')) {
            $skip += "$name  [jar says client-only]"
        } elseif ($fabric -and $fabric -match '"environment"\s*:\s*"client"') {
            $skip += "$name  [jar says client-only]"
        } elseif ($name.ToLower() -match $knownRegex) {
            $skip += "$name  [known client-only mod]"
        } else {
            $copy += $jar; $unsure += $name
        }
    }

    # --- 3. Copy ---
    if (Test-Path $Dest) { Get-ChildItem -Path $Dest -Filter '*.jar' -File | Remove-Item -Force }
    else { New-Item -ItemType Directory -Path $Dest | Out-Null }
    foreach ($jar in $copy) { Copy-Item -LiteralPath $jar.FullName -Destination $Dest }

    $lines = @(
        "Server mods report  ($(Get-Date))",
        "From: $ModsDir",
        "To:   $Dest",
        "",
        "COPIED for the server: $($copy.Count)",
        "LEFT OUT (client-only): $($skip.Count)"
    ) + ($skip | Sort-Object | ForEach-Object { "  - $_" }) + @(
        "",
        "COPIED BUT NOT SURE: $($unsure.Count)",
        "  Not on Modrinth and nothing marks them client-only. If the server crashes on start",
        "  with 'invalid dist DEDICATED_SERVER' or a client class, the mod named in that error",
        "  is client-only: delete it from the server's Mods tab."
    ) + ($unsure | Sort-Object | ForEach-Object { "  - $_" })
    if (-not $online) { $lines += @("", "NOTE: Modrinth couldn't be reached, so this used the fallback checks only. Re-run later for a better result.") }
    $lines | Set-Content -Path $Report -Encoding UTF8

    Write-Host ""
    Write-Host "Copied $($copy.Count) mods to $Dest" -ForegroundColor Green
    Write-Host "Left out $($skip.Count) client-only mods:" -ForegroundColor Cyan
    $skip | Sort-Object | ForEach-Object { Write-Host "  - $_" }
    if ($unsure.Count) {
        Write-Host "Copied but not sure about $($unsure.Count) (see report):" -ForegroundColor Yellow
        $unsure | Sort-Object | ForEach-Object { Write-Host "  - $_" }
    }
    Write-Host ""
    Write-Host "Full report: $Report"
    Write-Host "Next: open the web panel, go to Mods, drag everything from server-mods in, then click Restart."
    Invoke-Item $Dest
}

Sort-ServerMods
