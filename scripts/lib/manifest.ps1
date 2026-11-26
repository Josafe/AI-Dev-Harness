# Run manifest library (Phase 3 work package B1: FR-304, FR-305, FR-306, FR-309 derived status).
#
# Dot-sourced by the unified CLI and its tests. Nothing here runs a stage, parses a
# command line or prints to the console; every function returns data or throws.
#
#   Run ids and the run directory (FR-304)
#     Test-HarnessRunId        grammar and device-name check of a GIVEN id
#     New-HarnessRunId         <UTC yyyyMMddTHHmmssZ>-<8 lowercase hex>
#     Request-HarnessRunClaim  claim of runs\<id>\ : CreateDirectory, then .claim with CreateNew
#     New-HarnessRunClaim      -RunId, else AI_HARNESS_RUN_ID, else a generated id
#
#   Manifest I/O (FR-305)
#     Write-HarnessManifest    temp file in the same folder, then File.Replace (Move when absent)
#     Read-HarnessManifestText / Read-HarnessManifest   shared-read open, retried
#     Read-HarnessTextFile, Get-HarnessFileSha256, Get-HarnessTextSha256,
#     Get-HarnessUtcTimestamp  string and hash sources that come from .NET I/O
#
#   Validation (FR-306) and derived status (FR-309)
#     Test-HarnessManifest     { valid, errors[] } against lib\run-manifest.schema.json
#     Get-HarnessRunStatus     recorded status, derived status, liveness flag
#
# Errors are thrown as "<token>: <text>" (invalid_arguments, manifest_invalid,
# internal_error), the same style as the engine. PowerShell 5.1, ASCII only.

$script:HarnessRunIdPattern = '\A[A-Za-z0-9](?:[A-Za-z0-9_-]|\.(?!\z)){0,63}\z'
$script:HarnessRunIdFinalPattern = '\A[A-Za-z0-9](?:[A-Za-z0-9_-]|\.(?!\z)){0,68}\z'
$script:HarnessDeviceNamePattern = '\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\z'

# ---------------------------------------------------------------------------
# Strings and hashes from .NET I/O (FR-305: ConvertTo-Json of a Get-Content string hangs)
# ---------------------------------------------------------------------------

# UTC timestamp text of the manifest: yyyy-MM-ddTHH:mm:ss.fffZ (the schema pattern accepts it).
function Get-HarnessUtcTimestamp {
    param([AllowNull()][Nullable[datetime]]$At = $null)

    $moment = [datetime]::UtcNow
    if ($null -ne $At) { $moment = ([datetime]$At).ToUniversalTime() }
    return $moment.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
}

# A file as a plain .NET string (UTF-8, a BOM is dropped). Never Get-Content.
function Read-HarnessTextFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    return [System.IO.File]::ReadAllText($Path, $utf8)
}

function ConvertTo-HarnessHex {
    param([byte[]]$Bytes)

    $builder = New-Object System.Text.StringBuilder
    foreach ($b in $Bytes) { [void]$builder.Append($b.ToString('x2', [System.Globalization.CultureInfo]::InvariantCulture)) }
    return $builder.ToString()
}

# SHA-256 of the file bytes, 64 lowercase hex characters.
function Get-HarnessFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)))
    try { return (ConvertTo-HarnessHex -Bytes $sha.ComputeHash($stream)) }
    finally { $stream.Dispose(); $sha.Dispose() }
}

# SHA-256 of the UTF-8 bytes (no BOM) of a text.
function Get-HarnessTextSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (ConvertTo-HarnessHex -Bytes $sha.ComputeHash($utf8.GetBytes($Text))) }
    finally { $sha.Dispose() }
}

function New-HarnessRandomHex {
    param([Parameter(Mandatory = $true)][int]$Length)

    $bytes = New-Object byte[] ([int][math]::Ceiling($Length / 2.0))
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (ConvertTo-HarnessHex -Bytes $bytes).Substring(0, $Length)
}

# ---------------------------------------------------------------------------
# Run ids and the claim of the run directory (FR-304, D-309)
# ---------------------------------------------------------------------------

# True when the text is a valid GIVEN run id: 1 to 64 characters of the grammar, a dot
# never last, and the text before the first dot is not a device name (any case).
function Test-HarnessRunId {
    param([AllowNull()][AllowEmptyString()][string]$Id)

    if ([string]::IsNullOrEmpty($Id)) { return $false }
    if ($Id -cnotmatch $script:HarnessRunIdPattern) { return $false }
    $stem = $Id.Split([char]'.')[0].ToUpperInvariant()
    if ($stem -cmatch $script:HarnessDeviceNamePattern) { return $false }
    return $true
}

function New-HarnessRunId {
    $stamp = [datetime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    return ($stamp + '-' + (New-HarnessRandomHex -Length 8))
}

function Get-HarnessRunPath {
    param([Parameter(Mandatory = $true)][string]$HarnessRoot, [Parameter(Mandatory = $true)][string]$RunId)
    return (Join-Path (Join-Path $HarnessRoot 'runs') $RunId)
}

function Get-HarnessManifestPath {
    param([Parameter(Mandatory = $true)][string]$HarnessRoot, [Parameter(Mandatory = $true)][string]$RunId)
    return (Join-Path (Get-HarnessRunPath -HarnessRoot $HarnessRoot -RunId $RunId) 'manifest.json')
}

# Id text for a message: control characters and non-ASCII become '?', cut at 80.
function Format-HarnessIdForMessage {
    param([AllowNull()][string]$Id)

    if ($null -eq $Id) { return '' }
    $builder = New-Object System.Text.StringBuilder
    foreach ($c in $Id.ToCharArray()) {
        if ($c -ge [char]32 -and $c -le [char]126) { [void]$builder.Append($c) } else { [void]$builder.Append('?') }
        if ($builder.Length -ge 80) { break }
    }
    return $builder.ToString()
}

# One claim attempt on an id that is already valid. The creator of .claim (CreateNew)
# owns the id: CreateDirectory succeeds for every caller, CreateNew for exactly one.
# Returns $true (won) or $false (the claim file exists).
function Request-HarnessRunClaim {
    param([Parameter(Mandatory = $true)][string]$HarnessRoot, [Parameter(Mandatory = $true)][string]$RunId)

    if (-not [System.IO.Path]::IsPathRooted($HarnessRoot)) { throw "internal_error: the harness root must be an absolute path: '$HarnessRoot'." }
    $directory = Get-HarnessRunPath -HarnessRoot $HarnessRoot -RunId $RunId
    $claimPath = Join-Path $directory '.claim'
    [void][System.IO.Directory]::CreateDirectory($directory)
    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream($claimPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        return $true
    }
    catch [System.IO.IOException] {
        # The file exists (or the winner still holds it): the id is not ours. Any other
        # IOException (path too long, disk) is a real failure.
        if ([System.IO.File]::Exists($claimPath)) { return $false }
        throw
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

# Claims the run directory and returns { RunId, RunPath, ManifestPath, Source, Warnings[] }.
#   -RunId given (any non-null value): it must be valid and unused, else invalid_arguments.
#   else a valid -EnvRunId (default AI_HARNESS_RUN_ID): used as it is when free; when its
#     directory exists, <id>-<4 lowercase hex> with a new suffix until the claim succeeds
#     (at most 69 characters), warning run_id_env_reused; it never fails.
#     An invalid value is ignored with the warning invalid_run_id_env.
#   else <UTC>-<8 hex>.
# Setting and restoring $env:AI_HARNESS_RUN_ID is the caller's job (FR-304).
function New-HarnessRunClaim {
    param(
        [Parameter(Mandatory = $true)][string]$HarnessRoot,
        $RunId = $null,
        [AllowNull()][AllowEmptyString()][string]$EnvRunId = $env:AI_HARNESS_RUN_ID
    )

    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $finalId = $null
    $source = $null

    if ($null -ne $RunId) {
        $given = [string]$RunId
        $shown = Format-HarnessIdForMessage -Id $given
        if (-not (Test-HarnessRunId -Id $given)) { throw "invalid_arguments: '$shown' is not a valid run id." }
        if (-not (Request-HarnessRunClaim -HarnessRoot $HarnessRoot -RunId $given)) { throw "invalid_arguments: run id '$shown' already exists." }
        $finalId = $given
        $source = 'parameter'
    }
    else {
        $candidate = $null
        if (-not [string]::IsNullOrEmpty($EnvRunId)) {
            if (Test-HarnessRunId -Id $EnvRunId) { $candidate = $EnvRunId }
            else { $warnings.Add('invalid_run_id_env') }
        }

        if ($null -ne $candidate) {
            if (Request-HarnessRunClaim -HarnessRoot $HarnessRoot -RunId $candidate) { $finalId = $candidate }
            else {
                for ($try = 0; $try -lt 100000 -and $null -eq $finalId; $try++) {
                    $suffixed = $candidate + '-' + (New-HarnessRandomHex -Length 4)
                    if (Request-HarnessRunClaim -HarnessRoot $HarnessRoot -RunId $suffixed) { $finalId = $suffixed }
                }
                if ($null -eq $finalId) { throw "internal_error: could not claim a suffixed run id for '$(Format-HarnessIdForMessage -Id $candidate)'." }
                $warnings.Add('run_id_env_reused')
            }
            $source = 'environment'
        }
        else {
            for ($try = 0; $try -lt 100 -and $null -eq $finalId; $try++) {
                $generated = New-HarnessRunId
                if (Request-HarnessRunClaim -HarnessRoot $HarnessRoot -RunId $generated) { $finalId = $generated }
            }
            if ($null -eq $finalId) { throw 'internal_error: could not claim a generated run id.' }
            $source = 'generated'
        }
    }

    return [pscustomobject][ordered]@{
        RunId        = [string]$finalId
        RunPath      = Get-HarnessRunPath -HarnessRoot $HarnessRoot -RunId $finalId
        ManifestPath = Get-HarnessManifestPath -HarnessRoot $HarnessRoot -RunId $finalId
        Source       = $source
        Warnings     = @($warnings.ToArray())
    }
}

# ---------------------------------------------------------------------------
# Manifest write and read (FR-305, D-309)
# ---------------------------------------------------------------------------

# A plain copy of a manifest value: dictionaries and objects become ordered
# dictionaries, sequences become object[], every string is cast to [string] so that
# no PowerShell wrapper (the extra members of a Get-Content string) reaches
# ConvertTo-Json. Other scalars are kept as they are.
function ConvertTo-HarnessPlainData {
    param([AllowNull()]$Value, [int]$Depth = 0)

    if ($Depth -gt 20) { throw 'internal_error: the manifest value is nested deeper than 20 levels.' }
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return [string]$Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) { $copy[[string]$key] = ConvertTo-HarnessPlainData -Value $Value[$key] -Depth ($Depth + 1) }
        return $copy
    }
    if (Test-HarnessIsCustomObject -Value $Value) {
        $copy = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $copy[[string]$property.Name] = ConvertTo-HarnessPlainData -Value $property.Value -Depth ($Depth + 1) }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $Value) { $items.Add((ConvertTo-HarnessPlainData -Value $item -Depth ($Depth + 1))) }
        return , ($items.ToArray())
    }
    return $Value
}

# Writes the manifest atomically: UTF-8 without BOM, ConvertTo-Json -Depth 10, a temp
# file in the same folder, then File.Replace(temp, manifest, [NullString]::Value)
# (File.Move when the manifest does not exist yet), retried 50 times 20 ms apart on
# IOException and UnauthorizedAccessException. Readers that open with
# FileShare.ReadWrite, Delete never see a partial file.
function Write-HarnessManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Manifest,
        [int]$Retries = 50,
        [int]$DelayMs = 20
    )

    $plain = ConvertTo-HarnessPlainData -Value $Manifest
    $json = ConvertTo-Json -InputObject $plain -Depth 10
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $bytes = $utf8.GetBytes($json)

    $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
    $temp = Join-Path $directory ([System.IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $stream = New-Object System.IO.FileStream($temp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    catch {
        $stream.Dispose()
        [System.IO.File]::Delete($temp)
        throw
    }
    $stream.Dispose()

    $lastMessage = ''
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($temp, $Path, [NullString]::Value) }
            else { [System.IO.File]::Move($temp, $Path) }
            return
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            $lastMessage = $_.Exception.Message
            if ($attempt -lt $Retries) { [System.Threading.Thread]::Sleep($DelayMs) }
        }
    }
    try { [System.IO.File]::Delete($temp) } catch { }
    throw "internal_error: the manifest could not be written after $Retries attempts: $lastMessage"
}

# The manifest text. Opens with FileShare.ReadWrite, Delete and retries 25 times 20 ms
# apart on IOException (a missing file included) and UnauthorizedAccessException.
function Read-HarnessManifestText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Retries = 25,
        [int]$DelayMs = 20
    )

    $share = [System.IO.FileShare]([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    $lastMessage = ''
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $stream = $null
        try {
            $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
            $memory = New-Object System.IO.MemoryStream
            $stream.CopyTo($memory)
            $bytes = $memory.ToArray()
            $offset = 0
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $offset = 3 }
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            return $utf8.GetString($bytes, $offset, $bytes.Length - $offset)
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            $lastMessage = $_.Exception.Message
            if ($attempt -lt $Retries) { [System.Threading.Thread]::Sleep($DelayMs) }
        }
        finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }
    throw "manifest_invalid: cannot read '$Path' after $Retries attempts: $lastMessage"
}

# The manifest as an object. Unreadable and not-JSON are both manifest_invalid; a parse
# failure is never retried (a partial file cannot exist with the atomic write).
function Read-HarnessManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Retries = 25,
        [int]$DelayMs = 20
    )

    $text = Read-HarnessManifestText -Path $Path -Retries $Retries -DelayMs $DelayMs
    try { return (ConvertFrom-Json -InputObject $text -ErrorAction Stop) }
    catch { throw "manifest_invalid: '$Path' is not valid JSON." }
}

# ---------------------------------------------------------------------------
# Schema subset and validator (FR-306)
# ---------------------------------------------------------------------------

# Member lookup by ordinal name on a dictionary or an object. Returns $true and sets
# $Value, or $false.
function Get-HarnessManifestMember {
    param([AllowNull()]$Object, [Parameter(Mandatory = $true)][string]$Name, [ref]$Value)

    $Value.Value = $null
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::Ordinal)) { $Value.Value = $Object[$key]; return $true }
        }
        return $false
    }
    foreach ($property in $Object.PSObject.Properties) {
        if ([string]::Equals($property.Name, $Name, [System.StringComparison]::Ordinal)) { $Value.Value = $property.Value; return $true }
    }
    return $false
}

function Get-HarnessManifestMemberNames {
    param([AllowNull()]$Object)

    if ($null -eq $Object) { return @() }
    if ($Object -is [System.Collections.IDictionary]) { return @($Object.Keys | ForEach-Object { [string]$_ }) }
    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

# An object made by [pscustomobject] or ConvertFrom-Json. Not "-is [pscustomobject]": in
# Windows PowerShell 5.1 that is true for anything wrapped in a PSObject (a parsed array).
function Test-HarnessIsCustomObject {
    param([AllowNull()]$Value)
    return (($null -ne $Value) -and ($Value.GetType().FullName -ceq 'System.Management.Automation.PSCustomObject'))
}

function Test-HarnessIsObject {
    param([AllowNull()]$Value)
    return (($Value -is [System.Collections.IDictionary]) -or (Test-HarnessIsCustomObject -Value $Value))
}

function Test-HarnessIsArray {
    param([AllowNull()]$Value)
    return (($null -ne $Value) -and ($Value -is [System.Collections.IEnumerable]) -and ($Value -isnot [string]) -and -not (Test-HarnessIsObject -Value $Value))
}

function Test-HarnessIsNumber {
    param([AllowNull()]$Value)
    return (($Value -is [int]) -or ($Value -is [long]) -or ($Value -is [int16]) -or ($Value -is [byte]) -or ($Value -is [sbyte]) -or
        ($Value -is [uint16]) -or ($Value -is [uint32]) -or ($Value -is [uint64]) -or ($Value -is [decimal]) -or ($Value -is [double]) -or ($Value -is [single]))
}

function Test-HarnessJsonType {
    param([AllowNull()]$Value, [Parameter(Mandatory = $true)][string]$TypeName)

    switch -CaseSensitive ($TypeName) {
        'null'    { return ($null -eq $Value) }
        'string'  { return ($Value -is [string]) }
        'boolean' { return ($Value -is [bool]) }
        'object'  { return (Test-HarnessIsObject -Value $Value) }
        'array'   { return (Test-HarnessIsArray -Value $Value) }
        'number'  { return (Test-HarnessIsNumber -Value $Value) }
        'integer' {
            if (-not (Test-HarnessIsNumber -Value $Value)) { return $false }
            if (($Value -is [double]) -or ($Value -is [single])) {
                if ([double]::IsNaN([double]$Value) -or [double]::IsInfinity([double]$Value)) { return $false }
                return ([math]::Floor([double]$Value) -eq [double]$Value)
            }
            if ($Value -is [decimal]) { return ([math]::Floor($Value) -eq $Value) }
            return $true
        }
        default   { return $false }
    }
}

# Validates one value against one schema node; appends "<path>: <code>" to $Errors.
function Test-HarnessSchemaNode {
    param([AllowNull()]$Value, $Schema, [Parameter(Mandatory = $true)][string]$Path, $Errors)

    $typeSpec = $null
    if (Get-HarnessManifestMember -Object $Schema -Name 'type' -Value ([ref]$typeSpec)) {
        $matched = $false
        foreach ($name in @($typeSpec)) {
            if (Test-HarnessJsonType -Value $Value -TypeName ([string]$name)) { $matched = $true; break }
        }
        if (-not $matched) { $Errors.Add("${Path}: wrong_type"); return }
    }
    if ($null -eq $Value) { return }

    $enumSpec = $null
    if (Get-HarnessManifestMember -Object $Schema -Name 'enum' -Value ([ref]$enumSpec)) {
        $found = $false
        foreach ($allowed in @($enumSpec)) {
            if ($null -eq $allowed) { continue }
            if (($allowed -is [string]) -and ($Value -is [string])) {
                if ([string]::Equals($allowed, $Value, [System.StringComparison]::Ordinal)) { $found = $true; break }
            }
            elseif ((Test-HarnessIsNumber -Value $allowed) -and (Test-HarnessIsNumber -Value $Value)) {
                if ([decimal]$allowed -eq [decimal]$Value) { $found = $true; break }
            }
            elseif (($allowed -is [bool]) -and ($Value -is [bool]) -and ($allowed -eq $Value)) { $found = $true; break }
        }
        if (-not $found) {
            if ($Path -ceq '$.schemaVersion') { $Errors.Add("${Path}: unsupported_schema_version") }
            else { $Errors.Add("${Path}: not_in_enum") }
        }
    }

    $patternSpec = $null
    if (($Value -is [string]) -and (Get-HarnessManifestMember -Object $Schema -Name 'pattern' -Value ([ref]$patternSpec))) {
        if ($Value -cnotmatch ([string]$patternSpec)) { $Errors.Add("${Path}: pattern_mismatch") }
    }

    $minimumSpec = $null
    if ((Test-HarnessIsNumber -Value $Value) -and (Get-HarnessManifestMember -Object $Schema -Name 'minimum' -Value ([ref]$minimumSpec))) {
        if ([decimal]$Value -lt [decimal]$minimumSpec) { $Errors.Add("${Path}: below_minimum") }
    }

    if (Test-HarnessIsObject -Value $Value) {
        $requiredSpec = $null
        if (Get-HarnessManifestMember -Object $Schema -Name 'required' -Value ([ref]$requiredSpec)) {
            foreach ($name in @($requiredSpec)) {
                $unused = $null
                if (-not (Get-HarnessManifestMember -Object $Value -Name ([string]$name) -Value ([ref]$unused))) { $Errors.Add("${Path}.${name}: missing_required") }
            }
        }
        $propertiesSpec = $null
        if (Get-HarnessManifestMember -Object $Schema -Name 'properties' -Value ([ref]$propertiesSpec)) {
            foreach ($name in (Get-HarnessManifestMemberNames -Object $propertiesSpec)) {
                $child = $null
                if (Get-HarnessManifestMember -Object $Value -Name $name -Value ([ref]$child)) {
                    $childSchema = $null
                    [void](Get-HarnessManifestMember -Object $propertiesSpec -Name $name -Value ([ref]$childSchema))
                    Test-HarnessSchemaNode -Value $child -Schema $childSchema -Path "${Path}.${name}" -Errors $Errors
                }
            }
        }
    }
    elseif (Test-HarnessIsArray -Value $Value) {
        $itemsSpec = $null
        if (Get-HarnessManifestMember -Object $Schema -Name 'items' -Value ([ref]$itemsSpec)) {
            $index = 0
            foreach ($item in $Value) {
                Test-HarnessSchemaNode -Value $item -Schema $itemsSpec -Path "${Path}[${index}]" -Errors $Errors
                $index++
            }
        }
    }
}

# The cross-field rules of FR-306. Runs only on a structurally valid manifest.
function Test-HarnessManifestInvariants {
    param($Manifest, $Errors)

    $status = $null; [void](Get-HarnessManifestMember -Object $Manifest -Name 'status' -Value ([ref]$status))
    $exitCode = $null; [void](Get-HarnessManifestMember -Object $Manifest -Name 'exitCode' -Value ([ref]$exitCode))
    $endedAt = $null; [void](Get-HarnessManifestMember -Object $Manifest -Name 'endedAtUtc' -Value ([ref]$endedAt))
    $error_ = $null; [void](Get-HarnessManifestMember -Object $Manifest -Name 'error' -Value ([ref]$error_))
    $stages = $null; [void](Get-HarnessManifestMember -Object $Manifest -Name 'stages' -Value ([ref]$stages))
    $artifacts = $null; [void](Get-HarnessManifestMember -Object $Manifest -Name 'artifacts' -Value ([ref]$artifacts))

    $terminal = (($status -cne 'queued') -and ($status -cne 'running'))
    if ($terminal) {
        if ($null -eq $exitCode -or [decimal]$exitCode -lt 0 -or [decimal]$exitCode -gt 4) { $Errors.Add('$.exitCode: invariant_terminal_exit_code') }
        if ($null -eq $endedAt) { $Errors.Add('$.endedAtUtc: invariant_terminal_ended_at') }
    }
    if ($status -ceq 'succeeded') {
        if ($null -ne $exitCode -and [decimal]$exitCode -ne 0) { $Errors.Add('$.exitCode: invariant_succeeded_exit_code') }
        $index = 0
        foreach ($stage in @($stages)) {
            $stageStatus = $null; [void](Get-HarnessManifestMember -Object $stage -Name 'status' -Value ([ref]$stageStatus))
            if ($stageStatus -ceq 'failed') { $Errors.Add("`$.stages[${index}].status: invariant_succeeded_failed_stage") }
            $index++
        }
    }
    if (($status -ceq 'failed' -or $status -ceq 'needs_input') -and $null -eq $error_) { $Errors.Add('$.error: invariant_error_required') }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $index = 0
    foreach ($stage in @($stages)) {
        $stageId = $null; [void](Get-HarnessManifestMember -Object $stage -Name 'id' -Value ([ref]$stageId))
        $attempt = $null; [void](Get-HarnessManifestMember -Object $stage -Name 'attempt' -Value ([ref]$attempt))
        $key = ([string]$stageId) + [char]0 + ([string][decimal]$attempt)
        if (-not $seen.Add($key)) { $Errors.Add("`$.stages[${index}]: invariant_duplicate_stage") }
        $index++
    }

    $index = 0
    foreach ($artifact in @($artifacts)) {
        $artifactPath = $null; [void](Get-HarnessManifestMember -Object $artifact -Name 'path' -Value ([ref]$artifactPath))
        $bad = $false
        if ($artifactPath -is [string]) {
            if ($artifactPath.Length -eq 0) { $bad = $true }
            elseif ($artifactPath[0] -eq [char]'/' -or $artifactPath[0] -eq [char]'\') { $bad = $true }
            elseif ($artifactPath -cmatch '\A[A-Za-z]:') { $bad = $true }
            elseif (@($artifactPath -split '[\\/]') -ccontains '..') { $bad = $true }
        }
        if ($bad) { $Errors.Add("`$.artifacts[${index}].path: invariant_artifact_path") }
        $index++
    }
}

# Test-HarnessManifest -Manifest <object or JSON text> [-SchemaPath]
# Returns { valid, errors[] }; an error is "<path>: <code>" with a literal path such as
# $.stages[0].status. Codes: missing_required, wrong_type, not_in_enum, pattern_mismatch,
# below_minimum, unsupported_schema_version, invariant_*. Keys, types and enums come from
# the schema file only. A missing required key is reported at the path of the missing key.
function Test-HarnessManifest {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()]$Manifest,
        [string]$SchemaPath = ''
    )

    $errors = New-Object 'System.Collections.Generic.List[string]'
    if ([string]::IsNullOrEmpty($SchemaPath)) { $SchemaPath = Join-Path $PSScriptRoot 'run-manifest.schema.json' }
    $schema = ConvertFrom-Json -InputObject (Read-HarnessTextFile -Path $SchemaPath) -ErrorAction Stop

    $value = $Manifest
    if ($Manifest -is [string]) {
        try { $value = ConvertFrom-Json -InputObject $Manifest -ErrorAction Stop }
        catch { $errors.Add('$: wrong_type'); $value = $null }
    }
    if ($errors.Count -eq 0) {
        Test-HarnessSchemaNode -Value $value -Schema $schema -Path '$' -Errors $errors
        if ($errors.Count -eq 0) { Test-HarnessManifestInvariants -Manifest $value -Errors $errors }
    }
    return [pscustomobject][ordered]@{ valid = ($errors.Count -eq 0); errors = @($errors.ToArray()) }
}

# ---------------------------------------------------------------------------
# Derived status (FR-309)
# ---------------------------------------------------------------------------

# Whether a pid exists and when it started. Exists is false for a pid that is not running;
# StartUtc is $null when the start time cannot be read (another user's process).
function Get-HarnessProcessInfo {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    if ($ProcessId -le 0) { return [pscustomobject]@{ Exists = $false; StartUtc = $null } }
    $process = $null
    try { $process = [System.Diagnostics.Process]::GetProcessById($ProcessId) }
    catch [System.ArgumentException] { return [pscustomobject]@{ Exists = $false; StartUtc = $null } }
    try {
        $startUtc = $process.StartTime.ToUniversalTime()
        if ($process.HasExited) { return [pscustomobject]@{ Exists = $false; StartUtc = $null } }
        return [pscustomobject]@{ Exists = $true; StartUtc = $startUtc }
    }
    catch [System.InvalidOperationException] { return [pscustomobject]@{ Exists = $false; StartUtc = $null } }
    catch { return [pscustomobject]@{ Exists = $true; StartUtc = $null } }
    finally { $process.Dispose() }
}

# The derived status equals the recorded one, except that a recorded 'running' is
# 'abandoned' when the pid does not exist or its start time differs from
# process.processStartUtc by more than 2 s. When the start time cannot be read (or
# the manifest has none) the run stays 'running' and livenessUnverified is true.
# Returns { recordedStatus, status, livenessUnverified }. Reads nothing from disk.
function Get-HarnessRunStatus {
    param([Parameter(Mandatory = $true)]$Manifest)

    $recorded = $null; [void](Get-HarnessManifestMember -Object $Manifest -Name 'status' -Value ([ref]$recorded))
    $recorded = [string]$recorded
    $derived = $recorded
    $unverified = $false

    if ($recorded -ceq 'running') {
        $processData = $null; [void](Get-HarnessManifestMember -Object $Manifest -Name 'process' -Value ([ref]$processData))
        $processId = $null; [void](Get-HarnessManifestMember -Object $processData -Name 'pid' -Value ([ref]$processId))
        $startText = $null; [void](Get-HarnessManifestMember -Object $processData -Name 'processStartUtc' -Value ([ref]$startText))

        $info = Get-HarnessProcessInfo -ProcessId ([int]$processId)
        if (-not $info.Exists) { $derived = 'abandoned' }
        else {
            $recordedStart = [datetime]::MinValue
            $parsed = $false
            if ($startText -is [string]) {
                $styles = [System.Globalization.DateTimeStyles]([System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
                $parsed = [datetime]::TryParse($startText, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$recordedStart)
            }
            elseif ($startText -is [datetime]) { $recordedStart = $startText.ToUniversalTime(); $parsed = $true }

            if ($null -eq $info.StartUtc -or -not $parsed) { $unverified = $true }
            elseif ([math]::Abs(($info.StartUtc - $recordedStart).TotalSeconds) -gt 2) { $derived = 'abandoned' }
        }
    }

    return [pscustomobject][ordered]@{ recordedStatus = $recorded; status = $derived; livenessUnverified = $unverified }
}
