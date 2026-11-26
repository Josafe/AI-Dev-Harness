# Unified CLI library (Phase 3 work package B3: FR-301, FR-302, FR-308, FR-309, FR-318).
#
# Dot-sourced by scripts\harness.ps1 and by the tests. Dot-sourcing defines functions
# and a few script variables; it prints nothing and sends nothing. Windows PowerShell
# 5.1, ASCII only.
#
#   Parser (FR-302)
#     ConvertFrom-HarnessCliArguments -Arguments   $args -> { ok, command, options, message }
#     Test-HarnessCliInvocation -Command -Options  value rules, required options, paths
#   Dispatch
#     Invoke-HarnessCli -Command -Options [-StageScripts] [-Hook] [-Result]
#         the test entry (RN-7). Prints the protocol lines to the success stream and sets
#         -Result.exitCode (results never travel in the pipeline).
#   Handlers (one function per command, see $script:HarnessCliHandlers)
#     stages, config, doctor, validate      B3
#     unsupported stages (exit 4)           B3
#     specify, review, revise, scan, context, status, list   stubs until B4, B5, B8
#
# HOW A COMMAND IS DISPATCHED (interface for B4 and later)
#   Invoke-HarnessCli validates the command and its options, then calls
#       & <handler name> -Command <canonical name> -Options <normalized ordered
#         dictionary> -Context <hashtable>
#   Options holds the canonical option names (TargetPath, Name, Task, TaskFile, Mode,
#   Include, Model, Profile, RunId, Overwrite, LoadCheck, Revision, SpecFile, Last,
#   Agent, Json); a switch is $true; TargetPath, TaskFile and SpecFile are absolute;
#   Mode (default requirements) and Revision (default 0, an [int]) are always set for
#   the commands that take them; Last is an [int].
#   Context: HarnessRoot, StageScripts (runner, validator, reviewer, reviser, scan,
#   context: absolute paths, or the mock paths of -StageScripts), Hook (a script
#   block or $null) and ExitCode, which the handler sets (default 2). A handler writes
#   its lines to the success stream and never calls exit. To plug a command in, B4
#   replaces the stub function Invoke-HarnessCommandSpecify (same name and parameters).
#
# Errors are lines "ERROR: <token>: <text>" (FR-308, FR-309); the text never holds task
# text. Argument errors exit 2 and never create a manifest or a run directory.

. (Join-Path $PSScriptRoot 'config.ps1')
. (Join-Path $PSScriptRoot 'agent-exec.ps1')
. (Join-Path $PSScriptRoot 'manifest.ps1')

$script:HarnessCliLibDirectory = $PSScriptRoot

# ---------------------------------------------------------------------------
# The literal argument table (FR-302)
# ---------------------------------------------------------------------------

# Every option name, canonical spelling; the three switches take no value.
$script:HarnessCliOptionNames = @('TargetPath', 'Name', 'Task', 'TaskFile', 'Mode', 'Include', 'Model', 'Profile', 'RunId', 'Overwrite', 'LoadCheck', 'Revision', 'SpecFile', 'Last', 'Agent', 'Json')
$script:HarnessCliSwitchNames = @('Json', 'Overwrite', 'LoadCheck')

# Command -> Required, OneOf (exactly one of the two), Optional. Order of the table is
# the order of 'harness stages'.
$script:HarnessCliCommands = [ordered]@{
    specify        = @{ Required = @('TargetPath', 'Name'); OneOf = @('Task', 'TaskFile'); Optional = @('Mode', 'Include', 'Model', 'Profile', 'RunId', 'Overwrite', 'LoadCheck') }
    review         = @{ Required = @('TargetPath', 'Name'); OneOf = @('Task', 'TaskFile'); Optional = @('Revision', 'Mode', 'Model', 'Profile', 'RunId', 'Overwrite') }
    revise         = @{ Required = @('TargetPath', 'Name', 'Revision'); OneOf = @('Task', 'TaskFile'); Optional = @('Mode', 'Model', 'Profile', 'RunId', 'Overwrite') }
    scan           = @{ Required = @('TargetPath'); OneOf = @(); Optional = @('RunId') }
    context        = @{ Required = @('TargetPath', 'Include'); OneOf = @(); Optional = @('RunId') }
    validate       = @{ Required = @('SpecFile'); OneOf = @(); Optional = @('Mode') }
    status         = @{ Required = @('RunId'); OneOf = @(); Optional = @('Json') }
    list           = @{ Required = @(); OneOf = @(); Optional = @('Last', 'Json') }
    stages         = @{ Required = @(); OneOf = @(); Optional = @('Json') }
    config         = @{ Required = @(); OneOf = @(); Optional = @('Agent', 'Model', 'Profile', 'Json') }
    doctor         = @{ Required = @(); OneOf = @(); Optional = @('Json', 'LoadCheck') }
    architecture   = @{ Required = @(); OneOf = @(); Optional = @('TargetPath', 'RunId') }
    plan           = @{ Required = @(); OneOf = @(); Optional = @('TargetPath', 'RunId') }
    qa             = @{ Required = @(); OneOf = @(); Optional = @('TargetPath', 'RunId') }
    'code-review'  = @{ Required = @(); OneOf = @(); Optional = @('TargetPath', 'RunId') }
    develop        = @{ Required = @(); OneOf = @(); Optional = @('TargetPath', 'RunId') }
}

$script:HarnessCliModes = @('requirements', 'baseline', 'documentation')

# The five commands without a local agent (FR-308): exit 4, one stage of kind unsupported.
$script:HarnessCliUnsupported = @('architecture', 'plan', 'qa', 'code-review', 'develop')

# The table of 'harness stages' (FR-309): name, supported, agent, reason.
$script:HarnessCliStageTable = @(
    @{ name = 'specify'; supported = $true; agent = 'spec'; reason = $null },
    @{ name = 'review'; supported = $true; agent = 'spec-reviewer'; reason = $null },
    @{ name = 'revise'; supported = $true; agent = 'spec-reviser'; reason = $null },
    @{ name = 'scan'; supported = $true; agent = $null; reason = $null },
    @{ name = 'context'; supported = $true; agent = $null; reason = $null },
    @{ name = 'validate'; supported = $true; agent = $null; reason = $null },
    @{ name = 'architecture'; supported = $false; agent = $null; reason = 'no_local_agent' },
    @{ name = 'plan'; supported = $false; agent = $null; reason = 'no_local_agent' },
    @{ name = 'qa'; supported = $false; agent = $null; reason = 'no_local_agent' },
    @{ name = 'code-review'; supported = $false; agent = $null; reason = 'no_local_agent' },
    @{ name = 'develop'; supported = $false; agent = 'developer'; reason = 'planned_phase_5' }
)

# Command -> handler function. B4, B5 and B8 replace the stubs by defining a function of
# the same name later in the file (or in cli.ps1 itself).
$script:HarnessCliHandlers = @{
    specify        = 'Invoke-HarnessCommandSpecify'
    review         = 'Invoke-HarnessCommandReview'
    revise         = 'Invoke-HarnessCommandRevise'
    scan           = 'Invoke-HarnessCommandScan'
    context        = 'Invoke-HarnessCommandContext'
    validate       = 'Invoke-HarnessCommandValidate'
    status         = 'Invoke-HarnessCommandStatus'
    list           = 'Invoke-HarnessCommandList'
    stages         = 'Invoke-HarnessCommandStages'
    config         = 'Invoke-HarnessCommandConfig'
    doctor         = 'Invoke-HarnessCommandDoctor'
    architecture   = 'Invoke-HarnessCommandUnsupported'
    plan           = 'Invoke-HarnessCommandUnsupported'
    qa             = 'Invoke-HarnessCommandUnsupported'
    'code-review'  = 'Invoke-HarnessCommandUnsupported'
    develop        = 'Invoke-HarnessCommandUnsupported'
}

$script:HarnessCliStageScriptKeys = @('runner', 'validator', 'reviewer', 'reviser', 'scan', 'context')

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

# Text for a message line: one line, printable ASCII, at most 300 characters.
function Format-HarnessCliText {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return '' }
    $builder = New-Object System.Text.StringBuilder
    foreach ($c in $Text.ToCharArray()) {
        if ($c -ge [char]32 -and $c -le [char]126) { [void]$builder.Append($c) }
        elseif ($c -eq [char]10 -or $c -eq [char]13 -or $c -eq [char]9) { [void]$builder.Append(' ') }
        else { [void]$builder.Append('?') }
        if ($builder.Length -ge 300) { break }
    }
    return $builder.ToString()
}

# "ERROR: <token>: <text>" on the success stream (stdout of the process).
function Write-HarnessCliError {
    param([Parameter(Mandatory = $true)][string]$Token, [AllowNull()][string]$Text)

    Write-Output ('ERROR: ' + $Token + ': ' + (Format-HarnessCliText -Text $Text))
}

function ConvertTo-HarnessCliJson {
    param([Parameter(Mandatory = $true)]$Value)

    return (ConvertTo-Json -InputObject $Value -Depth 8 -Compress)
}

# ---------------------------------------------------------------------------
# Paths (FR-302: GetFullPath against the PowerShell location, no trailing separator,
# 8.3 names expanded)
# ---------------------------------------------------------------------------

# Expands the 8.3 (short) components of an absolute path to their long names.
function Expand-HarnessCliShortPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($Path.IndexOf('~') -lt 0) { return $Path }
    $root = [System.IO.Path]::GetPathRoot($Path)
    if ([string]::IsNullOrEmpty($root) -or $Path.Length -le $root.Length) { return $Path }
    $current = $root
    foreach ($part in $Path.Substring($root.Length).Split([char]'\')) {
        if ($part.Length -eq 0) { continue }
        $next = $current.TrimEnd([char]'\') + '\' + $part
        if ($part.IndexOf('~') -ge 0) {
            try {
                $found = @([System.IO.Directory]::GetFileSystemEntries($current, $part))
                if ($found.Count -ge 1) { $next = $found[0] }
            }
            catch { $next = $current.TrimEnd([char]'\') + '\' + $part }
        }
        $current = $next
    }
    return $current
}

# An absolute, normalized path: a relative path is resolved against the PowerShell
# location (not the process directory), trailing separators are removed (not from a
# root), 8.3 names are expanded. Throws on a path .NET refuses.
function Resolve-HarnessCliPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $base = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath
    $full = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($base, $Path))
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd([char]'\', [char]'/') }
    return (Expand-HarnessCliShortPath -Path $full)
}

function Test-HarnessCliReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    return ((([System.IO.File]::GetAttributes($Path)) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

# The harness root: the parent of the folder that holds lib\cli.ps1's folder.
function Get-HarnessCliRoot {
    $scripts = Split-Path -Parent $script:HarnessCliLibDirectory
    return (Resolve-HarnessCliPath -Path (Split-Path -Parent $scripts))
}

# Result { ok, message, path } for a -TargetPath value: it must exist, be a folder, not be
# a reparse point and not equal or contain the harness root (OQ-314).
function Resolve-HarnessCliTarget {
    param([Parameter(Mandatory = $true)][string]$Value, [Parameter(Mandatory = $true)][string]$HarnessRoot)

    $path = $null
    try { $path = Resolve-HarnessCliPath -Path $Value }
    catch { return [pscustomobject]@{ ok = $false; message = '-TargetPath is not a valid path.'; path = $null } }

    if (-not [System.IO.Directory]::Exists($path)) {
        if ([System.IO.File]::Exists($path)) { return [pscustomobject]@{ ok = $false; message = '-TargetPath is a file, not a folder.'; path = $null } }
        return [pscustomobject]@{ ok = $false; message = '-TargetPath does not exist.'; path = $null }
    }
    if (Test-HarnessCliReparsePoint -Path $path) {
        return [pscustomobject]@{ ok = $false; message = '-TargetPath is a reparse point (junction or symbolic link).'; path = $null }
    }
    $rootWithSeparator = $HarnessRoot.TrimEnd([char]'\') + '\'
    $targetWithSeparator = $path.TrimEnd([char]'\') + '\'
    if ($rootWithSeparator.StartsWith($targetWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ ok = $false; message = '-TargetPath is the harness root or a folder that contains it.'; path = $null }
    }
    return [pscustomobject]@{ ok = $true; message = $null; path = $path }
}

# Result { ok, message, path } for a file option (-SpecFile, -TaskFile): it must exist.
function Resolve-HarnessCliFile {
    param([Parameter(Mandatory = $true)][string]$Value, [Parameter(Mandatory = $true)][string]$OptionName)

    $path = $null
    try { $path = Resolve-HarnessCliPath -Path $Value }
    catch { return [pscustomobject]@{ ok = $false; message = "-$OptionName is not a valid path."; path = $null } }
    if (-not [System.IO.File]::Exists($path)) { return [pscustomobject]@{ ok = $false; message = "-$OptionName does not name an existing file."; path = $null } }
    return [pscustomobject]@{ ok = $true; message = $null; path = $path }
}

# ---------------------------------------------------------------------------
# Value rules (FR-302, FR-319, FR-304)
# ---------------------------------------------------------------------------

# FR-319: the name of a specification written by the CLI.
function Test-HarnessCliName {
    param([AllowNull()][AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrEmpty($Name)) { return $false }
    if ($Name -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]*\z') { return $false }
    $lower = $Name.ToLowerInvariant()
    if ($lower.EndsWith('.review', [System.StringComparison]::Ordinal)) { return $false }
    if ($lower -cmatch '\.revised-v[0-9]+\z') { return $false }
    if ($lower -cmatch '\.revised-v[0-9]+\.') { return $false }
    if ($lower.EndsWith('.', [System.StringComparison]::Ordinal)) { return $false }
    $stem = $Name.Split([char]'.')[0].ToUpperInvariant()
    if ($stem -cmatch '\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\z') { return $false }
    return $true
}

# The files `review` and `revise` read (FR-319), in <target>\.ai-harness\specs\.
# review -Revision N: <Name>.md (N = 0) or <Name>.revised-vN.md.
# revise -Revision N: the specification of revision N-1 and its review file.
# Nothing is created; a missing level is a missing file.
function Get-HarnessCliSpecInputs {
    param([Parameter(Mandatory = $true)][string]$Command, [Parameter(Mandatory = $true)][string]$TargetPath, [Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][int]$Revision)

    $directory = Join-Path (Join-Path $TargetPath '.ai-harness') 'specs'
    $stem = $Name
    $read = $Revision
    if ($Command -ceq 'revise') { $read = $Revision - 1 }
    if ($read -gt 0) { $stem = $Name + '.revised-v' + $read }
    $files = @((Join-Path $directory ($stem + '.md')))
    if ($Command -ceq 'revise') { $files += (Join-Path $directory ($stem + '.review.md')) }
    return @($files)
}

# Value-level validation of an options dictionary against the FR-302 table. Result
# { ok, message, command, options }: options is the normalized ordered dictionary
# (see the header). The message never contains a value of -Task.
function Test-HarnessCliInvocation {
    param(
        [AllowNull()][AllowEmptyString()][string]$Command,
        [AllowNull()]$Options,
        [Parameter(Mandatory = $true)][string]$HarnessRoot
    )

    $failure = { param($text) return [pscustomobject]@{ ok = $false; message = $text; command = $null; options = $null } }

    $canonicalCommand = $null
    foreach ($name in $script:HarnessCliCommands.Keys) {
        if ([string]::Equals($name, [string]$Command, [System.StringComparison]::OrdinalIgnoreCase)) { $canonicalCommand = $name }
    }
    if ($null -eq $canonicalCommand) {
        if ([string]::IsNullOrEmpty($Command)) { return (& $failure 'no command given.') }
        return (& $failure ("unknown command '" + (Format-HarnessIdForMessage -Id $Command) + "'."))
    }
    $rule = $script:HarnessCliCommands[$canonicalCommand]
    $allowed = @($rule.Required) + @($rule.OneOf) + @($rule.Optional)

    # Names: canonical spelling, allowed for the command, once.
    $given = [ordered]@{}
    if ($null -ne $Options) {
        if (-not ($Options -is [System.Collections.IDictionary])) { return (& $failure 'the options must be a dictionary.') }
        foreach ($key in @($Options.Keys)) {
            $canonicalName = $null
            foreach ($known in $script:HarnessCliOptionNames) {
                if ([string]::Equals($known, [string]$key, [System.StringComparison]::OrdinalIgnoreCase)) { $canonicalName = $known }
            }
            $shown = Format-HarnessIdForMessage -Id ([string]$key)
            if ($null -eq $canonicalName) { return (& $failure ("unknown option '-" + $shown + "'.")) }
            if ($allowed -cnotcontains $canonicalName) { return (& $failure ("option '-" + $canonicalName + "' is not valid for '" + $canonicalCommand + "'.")) }
            if ($given.Contains($canonicalName)) { return (& $failure ("option '-" + $canonicalName + "' is given twice.")) }
            $value = $Options[$key]
            if ($script:HarnessCliSwitchNames -ccontains $canonicalName) {
                if ($value -is [bool]) {
                    if ($value) { $given[$canonicalName] = $true }
                    continue
                }
                return (& $failure ("option '-" + $canonicalName + "' is a switch and takes no value."))
            }
            $text = [string]$value
            if ([string]::IsNullOrWhiteSpace($text)) { return (& $failure ("option '-" + $canonicalName + "' has an empty value.")) }
            $given[$canonicalName] = $text
        }
    }

    foreach ($required in @($rule.Required)) {
        if (-not $given.Contains($required)) { return (& $failure ("missing required option '-" + $required + "'.")) }
    }
    if (@($rule.OneOf).Count -eq 2) {
        $count = @($rule.OneOf | Where-Object { $given.Contains($_) }).Count
        if ($count -eq 0) { return (& $failure "one of '-Task' or '-TaskFile' is required.") }
        if ($count -eq 2) { return (& $failure "'-Task' and '-TaskFile' cannot be used together.") }
    }
    if ($given.Contains('Model') -and $given.Contains('Profile')) { return (& $failure "'-Model' and '-Profile' cannot be used together.") }

    $normalized = [ordered]@{}
    foreach ($name in $given.Keys) { $normalized[$name] = $given[$name] }

    # Mode: exactly one of the three, lower case.
    if ($allowed -ccontains 'Mode') {
        if ($normalized.Contains('Mode')) {
            if ($script:HarnessCliModes -cnotcontains [string]$normalized['Mode']) { return (& $failure "'-Mode' must be requirements, baseline or documentation.") }
        }
        else { $normalized['Mode'] = 'requirements' }
    }
    if ($normalized.Contains('Revision')) {
        if ([string]$normalized['Revision'] -cnotmatch '\A[0-9]{1,9}\z') { return (& $failure "'-Revision' must be a number (digits only).") }
        $normalized['Revision'] = [int]$normalized['Revision']
    }
    elseif ($allowed -ccontains 'Revision') { $normalized['Revision'] = 0 }
    if ($canonicalCommand -ceq 'revise' -and [int]$normalized['Revision'] -lt 1) { return (& $failure "'-Revision' of 'revise' must be at least 1.") }
    if ($normalized.Contains('Last')) {
        if ([string]$normalized['Last'] -cnotmatch '\A[0-9]{1,9}\z' -or [int]$normalized['Last'] -lt 1) { return (& $failure "'-Last' must be a positive integer.") }
        $normalized['Last'] = [int]$normalized['Last']
    }
    if ($normalized.Contains('Name') -and -not (Test-HarnessCliName -Name ([string]$normalized['Name']))) {
        return (& $failure "'-Name' is not a valid specification name.")
    }
    if ($normalized.Contains('RunId')) {
        $runId = [string]$normalized['RunId']
        $valid = $false
        if ($canonicalCommand -ceq 'status') { $valid = ($runId -cmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,68}\z') }
        else { $valid = (Test-HarnessRunId -Id $runId) }
        if (-not $valid) { return (& $failure ("'-RunId' '" + (Format-HarnessIdForMessage -Id $runId) + "' is not a valid run id.")) }
    }

    if ($normalized.Contains('TargetPath')) {
        $target = Resolve-HarnessCliTarget -Value ([string]$normalized['TargetPath']) -HarnessRoot $HarnessRoot
        if (-not $target.ok) { return (& $failure $target.message) }
        $normalized['TargetPath'] = $target.path
    }
    foreach ($fileOption in @('TaskFile', 'SpecFile')) {
        if ($normalized.Contains($fileOption)) {
            $file = Resolve-HarnessCliFile -Value ([string]$normalized[$fileOption]) -OptionName $fileOption
            if (-not $file.ok) { return (& $failure $file.message) }
            $normalized[$fileOption] = $file.path
        }
    }

    # review and revise read existing files: a missing input is an argument error, before
    # any run exists (FR-319).
    if ($canonicalCommand -ceq 'review' -or $canonicalCommand -ceq 'revise') {
        foreach ($input in @(Get-HarnessCliSpecInputs -Command $canonicalCommand -TargetPath ([string]$normalized['TargetPath']) -Name ([string]$normalized['Name']) -Revision ([int]$normalized['Revision']))) {
            if (-not [System.IO.File]::Exists($input)) { return (& $failure ("the input file '" + [System.IO.Path]::GetFileName($input) + "' does not exist in the target's .ai-harness\specs folder.")) }
        }
    }

    return [pscustomobject]@{ ok = $true; message = $null; command = $canonicalCommand; options = $normalized }
}

# ---------------------------------------------------------------------------
# The $args parser (FR-302). An option is -Name value (the next element, whatever it
# starts with); -Json, -Overwrite, -LoadCheck are switches. Result { ok, command,
# options, message }; options holds the canonical names with string values or $true.
# ---------------------------------------------------------------------------

function ConvertFrom-HarnessCliArguments {
    param([AllowNull()][object[]]$Arguments)

    $items = @($Arguments)
    $failure = { param($text) return [pscustomobject]@{ ok = $false; command = $null; options = $null; message = $text } }

    if ($items.Count -eq 0) { return (& $failure 'no command given.') }
    $commandToken = [string]$items[0]
    $canonicalCommand = $null
    foreach ($name in $script:HarnessCliCommands.Keys) {
        if ([string]::Equals($name, $commandToken, [System.StringComparison]::OrdinalIgnoreCase)) { $canonicalCommand = $name }
    }
    if ($null -eq $canonicalCommand) {
        if ($commandToken.StartsWith('-', [System.StringComparison]::Ordinal) -or $commandToken.Length -eq 0) { return (& $failure 'no command given: the first argument must be a command.') }
        return (& $failure ("unknown command '" + (Format-HarnessIdForMessage -Id $commandToken) + "'."))
    }
    $rule = $script:HarnessCliCommands[$canonicalCommand]
    $allowed = @($rule.Required) + @($rule.OneOf) + @($rule.Optional)

    $options = [ordered]@{}
    $index = 1
    while ($index -lt $items.Count) {
        $token = [string]$items[$index]
        if (-not ($token.StartsWith('-', [System.StringComparison]::Ordinal) -and $token.Length -gt 1)) {
            return (& $failure ("unexpected argument '" + (Format-HarnessIdForMessage -Id $token) + "'."))
        }
        $given = $token.Substring(1)
        $canonicalName = $null
        foreach ($known in $script:HarnessCliOptionNames) {
            if ([string]::Equals($known, $given, [System.StringComparison]::OrdinalIgnoreCase)) { $canonicalName = $known }
        }
        if ($null -eq $canonicalName) { return (& $failure ("unknown option '-" + (Format-HarnessIdForMessage -Id $given) + "'.")) }
        if ($allowed -cnotcontains $canonicalName) { return (& $failure ("option '-" + $canonicalName + "' is not valid for '" + $canonicalCommand + "'.")) }
        if ($options.Contains($canonicalName)) { return (& $failure ("option '-" + $canonicalName + "' is given twice.")) }
        if ($script:HarnessCliSwitchNames -ccontains $canonicalName) {
            $options[$canonicalName] = $true
            $index++
            continue
        }
        if ($index + 1 -ge $items.Count) { return (& $failure ("option '-" + $canonicalName + "' needs a value.")) }
        $options[$canonicalName] = [string]$items[$index + 1]
        $index += 2
    }
    return [pscustomobject]@{ ok = $true; command = $canonicalCommand; options = $options; message = $null }
}

# ---------------------------------------------------------------------------
# Processes: nvidia-smi, ollama ps, git (read-only, bounded)
# ---------------------------------------------------------------------------

# Runs an executable with redirected output and a time limit. Never throws. Result
# { started, timedOut, exitCode, stdout }. Nothing is elevated; the process gets no stdin.
function Invoke-HarnessCliProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = '',
        [int]$TimeoutSec = 5
    )

    $result = [pscustomobject][ordered]@{ started = $false; timedOut = $false; exitCode = $null; stdout = '' }
    $process = $null
    try {
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $FilePath
        $info.Arguments = $Arguments
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.RedirectStandardInput = $true
        $info.CreateNoWindow = $true
        $process = [System.Diagnostics.Process]::Start($info)
        $result.started = $true
        $process.StandardInput.Close()
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            $result.timedOut = $true
            try { $process.Kill() } catch { }
            return $result
        }
        $process.WaitForExit()
        $result.exitCode = [int]$process.ExitCode
        $result.stdout = [string]$outTask.Result
        [void]$errTask.Result
    }
    catch { $result.started = $result.started }
    finally { if ($null -ne $process) { $process.Dispose() } }
    return $result
}

function Get-HarnessCliExecutable {
    param([Parameter(Mandatory = $true)][string]$Name)

    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { return $null }
    return [string]$command.Source
}

# The first line of the nvidia-smi answer as an integer (MiB), else $null. A unit, N/A or
# an empty answer is $null.
function ConvertFrom-HarnessNvidiaSmiOutput {
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $first = ($Text -split "`r?`n")[0].Trim()
    if ($first -cnotmatch '\A[0-9]{1,9}\z') { return $null }
    return [int]$first
}

# Free VRAM in MiB, or $null: nvidia-smi must resolve with Get-Command and answer within 5 s.
function Get-HarnessVramFreeMiB {
    $exe = Get-HarnessCliExecutable -Name 'nvidia-smi'
    if ($null -eq $exe) { return $null }
    $run = Invoke-HarnessCliProcess -FilePath $exe -Arguments '--query-gpu=memory.free --format=csv,noheader,nounits' -TimeoutSec 5
    if (-not $run.started -or $run.timedOut -or $run.exitCode -ne 0) { return $null }
    return (ConvertFrom-HarnessNvidiaSmiOutput -Text $run.stdout)
}

# The lines of 'ollama ps' (read-only), or $null when the program is absent, fails or is slow.
function Get-HarnessOllamaPs {
    $exe = Get-HarnessCliExecutable -Name 'ollama'
    if ($null -eq $exe) { return $null }
    $run = Invoke-HarnessCliProcess -FilePath $exe -Arguments 'ps' -TimeoutSec 5
    if (-not $run.started -or $run.timedOut -or $run.exitCode -ne 0) { return $null }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in ($run.stdout -split "`r?`n")) {
        $clean = Format-HarnessCliText -Text $line.TrimEnd()
        if ($clean.Trim().Length -gt 0) { $lines.Add($clean) }
    }
    return @($lines.ToArray())
}

# { commit, dirty } of the harness checkout, read-only; both $null without git or a repository.
function Get-HarnessCliGitState {
    param([Parameter(Mandatory = $true)][string]$Root)

    $state = [pscustomobject][ordered]@{ commit = $null; dirty = $null }
    $git = Get-HarnessCliExecutable -Name 'git'
    if ($null -eq $git) { return $state }
    $quoted = '"' + $Root + '"'
    $head = Invoke-HarnessCliProcess -FilePath $git -Arguments ("-C $quoted --no-optional-locks rev-parse HEAD") -TimeoutSec 10
    if (-not $head.started -or $head.timedOut -or $head.exitCode -ne 0) { return $state }
    $commit = $head.stdout.Trim()
    if ($commit -cnotmatch '\A[0-9a-f]{40,64}\z') { return $state }
    $state.commit = $commit
    $status = Invoke-HarnessCliProcess -FilePath $git -Arguments ("-C $quoted --no-optional-locks status --porcelain") -TimeoutSec 20
    if ($status.started -and -not $status.timedOut -and $status.exitCode -eq 0) { $state.dirty = ($status.stdout.Trim().Length -gt 0) }
    return $state
}

# ---------------------------------------------------------------------------
# Registry and agent files (read-only)
# ---------------------------------------------------------------------------

# The normalized registry of <root>\.ai\config.json. Throws "registry_invalid: <text>".
function Get-HarnessCliRegistry {
    param([Parameter(Mandatory = $true)][string]$HarnessRoot)

    $configPath = Join-Path (Join-Path $HarnessRoot '.ai') 'config.json'
    if (-not [System.IO.File]::Exists($configPath)) { throw 'registry_invalid: .ai\config.json does not exist.' }
    try { return (Get-HarnessRegistry -ConfigPath $configPath) }
    catch {
        $message = [string]$_.Exception.Message
        if ($message.StartsWith('registry_invalid:', [System.StringComparison]::Ordinal)) { throw $message }
        throw ('registry_invalid: ' + $message)
    }
}

# The text of a "registry_invalid: <text>" message without its token.
function Get-HarnessCliTokenText {
    param([string]$Message, [string]$Token)

    $prefix = $Token + ':'
    if ($Message.StartsWith($prefix, [System.StringComparison]::Ordinal)) { return $Message.Substring($prefix.Length).Trim() }
    return $Message
}

# Names of the files of <root>\.ai\agents\ (without .md), ordinal order.
function Get-HarnessCliAgentNames {
    param([Parameter(Mandatory = $true)][string]$HarnessRoot)

    $directory = Join-Path (Join-Path $HarnessRoot '.ai') 'agents'
    if (-not [System.IO.Directory]::Exists($directory)) { return @() }
    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($file in [System.IO.Directory]::GetFiles($directory, '*.md')) {
        $names.Add([System.IO.Path]::GetFileNameWithoutExtension($file))
    }
    $array = $names.ToArray()
    [System.Array]::Sort($array, [System.StringComparer]::Ordinal)
    return @($array)
}

# ---------------------------------------------------------------------------
# Manifest of a run that has no stage to run (unsupported stages; B4 extends this)
# ---------------------------------------------------------------------------

# The skeleton of a manifest (FR-305) for a run of -Workflow. The caller fills status,
# exitCode, endedAtUtc, error, stages and the rest.
function New-HarnessCliManifest {
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Workflow,
        [Parameter(Mandatory = $true)][string]$HarnessRoot,
        [AllowNull()][string]$TargetPath = $null,
        [string[]]$Warnings = @()
    )

    $now = Get-HarnessUtcTimestamp
    $git = Get-HarnessCliGitState -Root $HarnessRoot
    $schemaVersion = $null
    $registrySha = $null
    $ollamaUrl = $null
    $configPath = Join-Path (Join-Path $HarnessRoot '.ai') 'config.json'
    if ([System.IO.File]::Exists($configPath)) {
        try { $registrySha = Get-HarnessFileSha256 -Path $configPath } catch { $registrySha = $null }
        try {
            $registry = Get-HarnessRegistry -ConfigPath $configPath
            $schemaVersion = [int]$registry.schemaVersion
            $ollamaUrl = [string]$registry.ollama.url
        }
        catch { $schemaVersion = $null; $ollamaUrl = $null }
    }
    $processStart = $null
    try {
        $self = [System.Diagnostics.Process]::GetCurrentProcess()
        $processStart = Get-HarnessUtcTimestamp -At $self.StartTime
        $self.Dispose()
    }
    catch { $processStart = $null }
    $artifactDirectory = $null
    if (-not [string]::IsNullOrEmpty($TargetPath)) { $artifactDirectory = Join-Path (Join-Path $TargetPath '.ai-harness') 'specs' }

    return [ordered]@{
        schemaVersion = 1
        runId         = $RunId
        workflow      = $Workflow
        status        = 'running'
        exitCode      = $null
        createdAtUtc  = $now
        startedAtUtc  = $now
        endedAtUtc    = $null
        warnings      = @($Warnings)
        error         = $null
        harness       = [ordered]@{ root = $HarnessRoot; gitCommit = $git.commit; gitDirty = $git.dirty; registrySchemaVersion = $schemaVersion; registrySha256 = $registrySha; ollamaUrl = $ollamaUrl }
        target        = [ordered]@{ root = $TargetPath; artifactDir = $artifactDirectory }
        process       = [ordered]@{ pid = [int]$PID; processStartUtc = $processStart; background = $false }
        request       = [ordered]@{ name = $null; mode = $null; maxRevisions = $null; taskSha256 = $null; taskFile = $null; include = @(); revision = $null; overrides = [ordered]@{ model = $null; profile = $null } }
        context       = $null
        stages        = @()
        artifacts     = @()
        verification  = @()
    }
}

# ---------------------------------------------------------------------------
# Handlers: stages, config
# ---------------------------------------------------------------------------

function Invoke-HarnessCommandStages {
    param($Command, $Options, $Context)

    $entries = @($script:HarnessCliStageTable | ForEach-Object {
            [ordered]@{ name = $_.name; supported = $_.supported; agent = $_.agent; reason = $_.reason }
        })
    if ($Options.Contains('Json')) {
        Write-Output (ConvertTo-HarnessCliJson -Value ([ordered]@{ stages = $entries }))
    }
    else {
        foreach ($entry in $entries) {
            $agentText = '-'
            if ($null -ne $entry.agent) { $agentText = $entry.agent }
            if ($entry.supported) { Write-Output ('{0,-13} supported    agent: {1}' -f $entry.name, $agentText) }
            else { Write-Output ('{0,-13} unsupported  agent: {1}  reason: {2}' -f $entry.name, $agentText, $entry.reason) }
        }
    }
    $Context.ExitCode = 0
}

function Invoke-HarnessCommandConfig {
    param($Command, $Options, $Context)

    $root = $Context.HarnessRoot
    $registry = $null
    try { $registry = Get-HarnessCliRegistry -HarnessRoot $root }
    catch { Write-HarnessCliError -Token 'registry_invalid' -Text (Get-HarnessCliTokenText -Message $_.Exception.Message -Token 'registry_invalid'); $Context.ExitCode = 2; return }

    $agentNames = @(Get-HarnessCliAgentNames -HarnessRoot $root)
    if ($Options.Contains('Agent')) {
        $wanted = [string]$Options['Agent']
        $match = @($agentNames | Where-Object { [string]::Equals($_, $wanted, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($match.Count -eq 0) { Write-HarnessCliError -Token 'invalid_arguments' -Text ("-Agent '" + (Format-HarnessIdForMessage -Id $wanted) + "' is not a file of .ai\agents."); $Context.ExitCode = 2; return }
        $agentNames = @($match[0])
    }

    $records = New-Object 'System.Collections.Generic.List[object]'
    foreach ($agent in $agentNames) {
        $arguments = @{ Agent = $agent; Registry = $registry }
        if ($Options.Contains('Model')) { $arguments.Model = [string]$Options['Model'] }
        if ($Options.Contains('Profile')) { $arguments.Profile = [string]$Options['Profile'] }
        $execution = $null
        try { $execution = Resolve-HarnessExecution @arguments }
        catch { Write-HarnessCliError -Token 'registry_invalid' -Text (Get-HarnessCliTokenText -Message $_.Exception.Message -Token 'registry_invalid'); $Context.ExitCode = 2; return }
        $records.Add([ordered]@{
                agent                = $agent
                profile              = $execution.profile
                model                = $execution.model
                modelSource          = $execution.modelSource
                parametersFrom       = $execution.parametersFrom
                contextWindow        = $execution.contextWindow
                timeoutSec           = $execution.timeoutSec
                reservedOutputTokens = $execution.reservedOutputTokens
                think                = $execution.think
                warnings             = @($execution.warnings)
            })
    }

    if ($Options.Contains('Json')) {
        Write-Output (ConvertTo-HarnessCliJson -Value ([ordered]@{ agents = @($records.ToArray()); warnings = @($registry.warnings) }))
    }
    else {
        foreach ($record in $records) {
            $warningText = '-'
            if (@($record.warnings).Count -gt 0) { $warningText = (@($record.warnings) -join ',') }
            Write-Output ("agent: {0} | profile: {1} | model: {2} | modelSource: {3} | parametersFrom: {4} | contextWindow: {5} | timeoutSec: {6} | reservedOutputTokens: {7} | think: {8} | warnings: {9}" -f
                $record.agent, $record.profile, $record.model, $record.modelSource, $record.parametersFrom, $record.contextWindow, $record.timeoutSec, $record.reservedOutputTokens, $record.think, $warningText)
        }
        foreach ($warning in @($registry.warnings)) { Write-Output ('registry warning: ' + $warning) }
    }
    $Context.ExitCode = 0
}

# ---------------------------------------------------------------------------
# Handler: validate (exit code passed through: 0, 1, 3; a throw or another code is 2)
# ---------------------------------------------------------------------------

function Invoke-HarnessCommandValidate {
    param($Command, $Options, $Context)

    $validator = [string]$Context.StageScripts['validator']
    $global:LASTEXITCODE = $null
    try { & $validator -SpecFile ([string]$Options['SpecFile']) -Mode ([string]$Options['Mode']) }
    catch {
        Write-HarnessCliError -Token 'stage_failed' -Text 'validate-spec.ps1 ended with an error.'
        $Context.ExitCode = 2
        return
    }
    $code = $global:LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
    if ($code -eq 0 -or $code -eq 1 -or $code -eq 3) { $Context.ExitCode = [int]$code; return }
    Write-HarnessCliError -Token 'stage_failed' -Text ("validate-spec.ps1 ended with exit code " + [string]$code + '.')
    $Context.ExitCode = 2
}

# ---------------------------------------------------------------------------
# Handler: doctor (FR-318). Read-only; the load check is the one exception to "never
# generates" and is off by default.
# ---------------------------------------------------------------------------

# Fixed wording for a failed load check (gate finding 13): the library result has no HTTP
# status and no server text, so the status is null and the message is derived from the
# category and the hint. Returns { category, message, hint, httpStatus }.
function Get-HarnessLoadCheckError {
    param([Parameter(Mandatory = $true)]$LoadResult)

    $category = [string]$LoadResult.category
    $hint = $null
    if ($null -ne $LoadResult.hint) { $hint = [string]$LoadResult.hint }
    $message = "The model load check failed with the category '" + $category + "'."
    if (-not [string]::IsNullOrEmpty($hint)) { $message = $message + ' ' + $hint }
    return [pscustomobject][ordered]@{ category = $category; message = $message; hint = $hint; httpStatus = $null }
}

function Invoke-HarnessCommandDoctor {
    param($Command, $Options, $Context)

    $root = $Context.HarnessRoot
    $asJson = $Options.Contains('Json')
    $loadCheck = $Options.Contains('LoadCheck')

    $registry = $null
    try { $registry = Get-HarnessCliRegistry -HarnessRoot $root }
    catch { Write-HarnessCliError -Token 'registry_invalid' -Text (Get-HarnessCliTokenText -Message $_.Exception.Message -Token 'registry_invalid'); $Context.ExitCode = 2; return }

    $url = ([string]$registry.ollama.url).TrimEnd('/')
    $findings = New-Object 'System.Collections.Generic.List[object]'

    # Version (informational when unavailable).
    $version = $null
    $versionReached = $false
    $versionRequest = @{ Url = "$url/api/version"; Method = 'Get'; Body = $null; TimeoutSec = [int]$registry.ollama.healthTimeoutSec; Purpose = 'version' }
    $versionRecord = $null
    try {
        $returned = @(Invoke-OllamaHttp -Request $versionRequest)
        if ($returned.Count -gt 0) { $versionRecord = $returned[$returned.Count - 1] }
    }
    catch { $versionRecord = $null }
    if ($null -ne $versionRecord -and $null -ne $versionRecord.PSObject.Properties['ok'] -and $versionRecord.ok -eq $true) {
        $versionReached = $true
        $answer = $versionRecord.response
        if ($null -ne $answer -and $null -ne $answer.PSObject.Properties['version'] -and -not [string]::IsNullOrWhiteSpace([string]$answer.version)) {
            $version = Format-HarnessCliText -Text ([string]$answer.version)
        }
    }
    if ($null -eq $version) {
        $findings.Add([ordered]@{ code = 'ollama_version_unavailable'; severity = 'info'; model = $null; message = 'The Ollama version could not be read from /api/version.'; hint = $null })
    }

    # Models: every model of the registry must be installed (one /api/tags request).
    $modelEntries = New-Object 'System.Collections.Generic.List[object]'
    $installedByModel = @{}
    $tagsReached = $false
    foreach ($model in @(Get-HarnessRegistryModels -Registry $registry)) {
        $execution = [pscustomobject]@{ agent = $null; profile = ''; model = $model; modelSource = 'registry'; timeoutSec = $registry.defaults.timeoutSec }
        $check = Test-OllamaModel -Execution $execution -Registry $registry
        if ($null -eq $check.category) { $tagsReached = $true; $installed = $true }
        elseif ($check.category -ceq 'model_not_installed') {
            $tagsReached = $true
            $installed = $false
            $findings.Add([ordered]@{ code = 'model_not_installed'; severity = 'error'; model = $model; message = "The model '$model' is not installed in Ollama."; hint = $check.hint })
        }
        else {
            Write-HarnessCliError -Token 'ollama_unreachable' -Text ("Ollama at $url did not answer /api/tags (" + $check.category + ').')
            $Context.ExitCode = 2
            return
        }
        $installedByModel[$model.ToLowerInvariant()] = $installed
        $modelEntries.Add([ordered]@{ model = $model; installed = $installed; loadChecks = @() })
    }
    $reachable = ($versionReached -or $tagsReached)

    # Load check: one request per distinct (model, effective options) of the three agents.
    if ($loadCheck) {
        $seen = @{}
        foreach ($agent in @('spec', 'spec-reviewer', 'spec-reviser')) {
            $execution = $null
            try { $execution = Resolve-HarnessExecution -Agent $agent -Registry $registry }
            catch { Write-HarnessCliError -Token 'registry_invalid' -Text (Get-HarnessCliTokenText -Message $_.Exception.Message -Token 'registry_invalid'); $Context.ExitCode = 2; return }
            $key = ([string]$execution.model).ToLowerInvariant() + '|' + (ConvertTo-Json -InputObject $execution.options -Compress)
            if ($seen.ContainsKey($key)) { $seen[$key].agents += $agent; continue }
            $seen[$key] = @{ execution = $execution; agents = @($agent); order = $seen.Count }
        }
        foreach ($item in @($seen.Values | Sort-Object { $_.order })) {
            $execution = $item.execution
            $modelKey = ([string]$execution.model).ToLowerInvariant()
            if ($installedByModel.ContainsKey($modelKey) -and -not $installedByModel[$modelKey]) { continue }
            $numCtx = $null
            if ($null -ne $execution.options -and $null -ne $execution.options.PSObject.Properties['num_ctx']) { $numCtx = $execution.options.num_ctx }
            $load = Test-OllamaModelLoad -Execution $execution -Registry $registry
            $entry = [ordered]@{ agents = @($item.agents); numCtx = $numCtx; loaded = [bool]$load.loaded; category = $load.category; hint = $load.hint; durationMs = $load.durationMs }
            foreach ($modelEntry in $modelEntries) {
                if ([string]::Equals([string]$modelEntry.model, [string]$execution.model, [System.StringComparison]::OrdinalIgnoreCase)) { $modelEntry.loadChecks = @($modelEntry.loadChecks) + @($entry) }
            }
            if (-not $load.loaded) {
                $loadError = Get-HarnessLoadCheckError -LoadResult $load
                $findings.Add([ordered]@{ code = $loadError.category; severity = 'error'; model = [string]$execution.model; message = $loadError.message; hint = $loadError.hint })
            }
        }
    }

    $vram = Get-HarnessVramFreeMiB
    $ps = Get-HarnessOllamaPs
    if ($null -ne $ps) { $ps = @($ps) }

    $exitCode = 0
    foreach ($finding in $findings) { if ($finding.severity -ceq 'error') { $exitCode = 1 } }

    if ($asJson) {
        $report = [ordered]@{
            registry     = [ordered]@{ path = (Join-Path (Join-Path $root '.ai') 'config.json'); schemaVersion = [int]$registry.schemaVersion; warnings = @($registry.warnings) }
            ollama       = [ordered]@{ url = $url; reachable = $reachable; version = $version; ps = $ps }
            models       = @($modelEntries.ToArray())
            vramFreeMiB  = $vram
            findings     = @($findings.ToArray())
            exitCode     = $exitCode
        }
        Write-Output (ConvertTo-HarnessCliJson -Value $report)
    }
    else {
        Write-Output ('Registry: schemaVersion ' + [string]$registry.schemaVersion + ', ' + @($registry.warnings).Count + ' warning(s)')
        $versionText = 'version unavailable'
        if ($null -ne $version) { $versionText = 'version ' + $version }
        Write-Output ('Ollama: ' + $url + ', ' + $(if ($reachable) { 'reachable' } else { 'not reached' }) + ', ' + $versionText)
        foreach ($entry in $modelEntries) {
            Write-Output ('Model: ' + $entry.model + ' ' + $(if ($entry.installed) { 'installed' } else { 'MISSING' }))
            foreach ($check in @($entry.loadChecks)) {
                if ($check.loaded) { Write-Output ('  load check (' + (@($check.agents) -join ', ') + ', num_ctx ' + [string]$check.numCtx + '): loaded in ' + [string]$check.durationMs + ' ms') }
                else { Write-Output ('  load check (' + (@($check.agents) -join ', ') + ', num_ctx ' + [string]$check.numCtx + '): FAILED ' + [string]$check.category) }
            }
        }
        if ($null -eq $vram) { Write-Output 'VRAM free: unavailable' } else { Write-Output ('VRAM free: ' + [string]$vram + ' MiB') }
        if ($null -eq $ps) { Write-Output 'ollama ps: unavailable' }
        else {
            Write-Output 'ollama ps:'
            foreach ($line in $ps) { Write-Output ('  ' + $line) }
        }
        foreach ($finding in $findings) { Write-Output ('Finding (' + $finding.severity + '): ' + $finding.code + ': ' + (Format-HarnessCliText -Text $finding.message)) }
        Write-Output ('Result: ' + $(if ($exitCode -eq 0) { 'OK' } else { 'FAIL' }) + ' (exit ' + [string]$exitCode + ')')
    }
    $Context.ExitCode = $exitCode
}

# ---------------------------------------------------------------------------
# Handler: the five unsupported stages (FR-308: exit 4, a manifest, the protocol lines)
# ---------------------------------------------------------------------------

function Invoke-HarnessCommandUnsupported {
    param($Command, $Options, $Context)

    $root = $Context.HarnessRoot
    $runIdArgument = $null
    if ($Options.Contains('RunId')) { $runIdArgument = [string]$Options['RunId'] }
    $targetPath = $null
    if ($Options.Contains('TargetPath')) { $targetPath = [string]$Options['TargetPath'] }

    $claim = $null
    try { $claim = New-HarnessRunClaim -HarnessRoot $root -RunId $runIdArgument }
    catch {
        $message = [string]$_.Exception.Message
        if ($message.StartsWith('invalid_arguments:', [System.StringComparison]::Ordinal)) { Write-HarnessCliError -Token 'invalid_arguments' -Text (Get-HarnessCliTokenText -Message $message -Token 'invalid_arguments') }
        else { Write-HarnessCliError -Token 'internal_error' -Text (Get-HarnessCliTokenText -Message $message -Token 'internal_error') }
        $Context.ExitCode = 2
        return
    }

    Write-Output ('RUN_ID: ' + $claim.RunId)
    $message = "No local agent implements '" + $Command + "'; perform it in Claude Code or manually."
    $manifest = New-HarnessCliManifest -RunId $claim.RunId -Workflow $Command -HarnessRoot $root -TargetPath $targetPath -Warnings @($claim.Warnings)
    $now = Get-HarnessUtcTimestamp
    $manifest.status = 'failed'
    $manifest.exitCode = 4
    $manifest.endedAtUtc = $now
    $manifest.error = [ordered]@{ category = 'unsupported_stage'; message = $message }
    $manifest.stages = @([ordered]@{
            id           = $Command
            kind         = 'unsupported'
            agent        = $null
            attempt      = 1
            status       = 'unsupported'
            reason       = $message
            startedAtUtc = $null
            durationMs   = $null
            exitCode     = $null
            warnings     = @()
            error        = [ordered]@{ category = 'unsupported_stage'; message = $message }
        })

    $check = Test-HarnessManifest -Manifest (ConvertTo-HarnessCliJson -Value $manifest)
    if (-not $check.valid) {
        Write-HarnessCliError -Token 'internal_error' -Text ('the manifest is not valid: ' + (@($check.errors) -join '; '))
        $Context.ExitCode = 2
        return
    }
    try { Write-HarnessManifest -Path $claim.ManifestPath -Manifest $manifest }
    catch {
        Write-HarnessCliError -Token 'internal_error' -Text (Get-HarnessCliTokenText -Message $_.Exception.Message -Token 'internal_error')
        $Context.ExitCode = 2
        return
    }
    Write-HarnessCliError -Token 'unsupported_stage' -Text $message
    Write-Output ('MANIFEST: ' + $claim.ManifestPath)
    $Context.ExitCode = 4
}

# ---------------------------------------------------------------------------
# Stubs: the commands whose logic belongs to later packages (B4 specify; B5 review, revise,
# status, list; B8 scan, context). They accept the validated options and do nothing else.
# ---------------------------------------------------------------------------

function Write-HarnessCliNotImplemented {
    param([string]$Command, $Context)

    Write-HarnessCliError -Token 'internal_error' -Text ("the command '" + $Command + "' is not implemented in this build.")
    $Context.ExitCode = 2
}

function Invoke-HarnessCommandSpecify { param($Command, $Options, $Context) Write-HarnessCliNotImplemented -Command $Command -Context $Context }
function Invoke-HarnessCommandReview { param($Command, $Options, $Context) Write-HarnessCliNotImplemented -Command $Command -Context $Context }
function Invoke-HarnessCommandRevise { param($Command, $Options, $Context) Write-HarnessCliNotImplemented -Command $Command -Context $Context }
function Invoke-HarnessCommandScan { param($Command, $Options, $Context) Write-HarnessCliNotImplemented -Command $Command -Context $Context }
function Invoke-HarnessCommandContext { param($Command, $Options, $Context) Write-HarnessCliNotImplemented -Command $Command -Context $Context }
function Invoke-HarnessCommandStatus { param($Command, $Options, $Context) Write-HarnessCliNotImplemented -Command $Command -Context $Context }
function Invoke-HarnessCommandList { param($Command, $Options, $Context) Write-HarnessCliNotImplemented -Command $Command -Context $Context }

# ---------------------------------------------------------------------------
# The entry point
# ---------------------------------------------------------------------------

# The stage scripts of a run: the real ones of <root>\scripts, each replaced by the
# absolute path of a mock given in -StageScripts (keys: runner, validator, reviewer,
# reviser, scan, context).
function Resolve-HarnessCliStageScripts {
    param([AllowNull()]$StageScripts, [Parameter(Mandatory = $true)][string]$HarnessRoot)

    $scripts = Join-Path $HarnessRoot 'scripts'
    $resolved = @{
        runner    = (Join-Path $scripts 'run-agent.ps1')
        validator = (Join-Path $scripts 'validate-spec.ps1')
        reviewer  = (Join-Path $scripts 'review-spec.ps1')
        reviser   = (Join-Path $scripts 'revise-spec.ps1')
        scan      = (Join-Path $scripts 'scan-repository.ps1')
        context   = (Join-Path $scripts 'build-context.ps1')
    }
    if ($null -ne $StageScripts) {
        if (-not ($StageScripts -is [System.Collections.IDictionary])) { throw 'invalid_arguments: -StageScripts must be a dictionary.' }
        foreach ($key in @($StageScripts.Keys)) {
            $known = $null
            foreach ($candidate in $script:HarnessCliStageScriptKeys) {
                if ([string]::Equals($candidate, [string]$key, [System.StringComparison]::OrdinalIgnoreCase)) { $known = $candidate }
            }
            if ($null -eq $known) { throw ("invalid_arguments: -StageScripts has an unknown key '" + (Format-HarnessIdForMessage -Id ([string]$key)) + "'.") }
            $resolved[$known] = [string]$StageScripts[$key]
        }
    }
    return $resolved
}

# Runs one command: validates it, calls its handler and sets -Result.exitCode (0 to 4).
# Output goes to the success stream; nothing is printed before the validation succeeds
# except the single "ERROR: invalid_arguments:" line of a failure.
function Invoke-HarnessCli {
    param(
        [AllowNull()][AllowEmptyString()][string]$Command = '',
        [AllowNull()]$Options = $null,
        [AllowNull()]$StageScripts = $null,
        [AllowNull()][scriptblock]$Hook = $null,
        [hashtable]$Result = $null
    )

    if ($null -eq $Result) { $Result = @{} }
    $Result.exitCode = 2
    try {
        $root = Get-HarnessCliRoot
        $validated = Test-HarnessCliInvocation -Command $Command -Options $Options -HarnessRoot $root
        if (-not $validated.ok) {
            Write-HarnessCliError -Token 'invalid_arguments' -Text $validated.message
            return
        }
        $scripts = $null
        try { $scripts = Resolve-HarnessCliStageScripts -StageScripts $StageScripts -HarnessRoot $root }
        catch {
            Write-HarnessCliError -Token 'invalid_arguments' -Text (Get-HarnessCliTokenText -Message $_.Exception.Message -Token 'invalid_arguments')
            return
        }
        $context = @{ HarnessRoot = $root; StageScripts = $scripts; Hook = $Hook; ExitCode = 2 }
        $handler = [string]$script:HarnessCliHandlers[$validated.command]
        & $handler -Command $validated.command -Options $validated.options -Context $context
        $Result.exitCode = [int]$context.ExitCode
    }
    catch {
        Write-HarnessCliError -Token 'internal_error' -Text ([string]$_.Exception.Message)
        $Result.exitCode = 2
    }
}
