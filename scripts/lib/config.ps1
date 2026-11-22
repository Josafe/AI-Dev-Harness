function Get-HarnessConfig {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    if (-not (Test-Path $ConfigPath -PathType Leaf)) {
        return [pscustomobject]@{}
    }

    try {
        return Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Invalid JSON in config file: $ConfigPath. $($_.Exception.Message)"
    }
}

function Get-ConfigValue {
    param($Object, [string]$Name, $Default)

    if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and
        $null -ne $Object.$Name) {
        return $Object.$Name
    }
    return $Default
}

function Test-HarnessInteger {
    param($Value)
    return ($Value -is [int] -or $Value -is [long])
}

function Test-HarnessNumber {
    param($Value)
    return ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal])
}

function Test-HarnessObject {
    param($Value)
    return ($Value -is [System.Management.Automation.PSCustomObject])
}

function Get-HarnessMember {
    param($Object, [string]$Name)

    if ($null -eq $Object) { return $null }
    $member = $Object.PSObject.Properties[$Name]
    if ($null -eq $member) { return $null }
    return $member
}

# Adds a v1 model as the synthetic profile "legacy:<model>" and returns its name.
# Models are told apart exactly (case included), so the v1 model string survives.
function Add-HarnessLegacyProfile {
    param($Profiles, $ByModel, [string]$Model)

    if ($ByModel.ContainsKey($Model)) { return $ByModel[$Model] }

    $name = "legacy:$Model"
    $n = 1
    while ($Profiles.Contains($name)) {
        $n++
        $name = "legacy:$Model#$n"
    }
    $Profiles[$name] = [pscustomobject]@{ model = $Model }
    $ByModel[$Model] = $name
    return $name
}

# v1 -> raw v2-shaped object. Never validates and never throws: a v1 file is
# accepted whatever its values.
function ConvertFrom-HarnessV1Config {
    param($Config)

    $profiles = [ordered]@{}
    $agents = [ordered]@{}
    $byModel = New-Object 'System.Collections.Generic.Dictionary[string,string]'

    $agentModels = Get-ConfigValue $Config "agentModels" $null
    if (Test-HarnessObject $agentModels) {
        foreach ($entry in $agentModels.PSObject.Properties) {
            $profileName = Add-HarnessLegacyProfile -Profiles $profiles -ByModel $byModel -Model ([string]$entry.Value)
            $agents[$entry.Name] = [pscustomobject]@{ profile = $profileName }
        }
    }

    $defaults = [ordered]@{}
    $defaultModel = Get-ConfigValue $Config "defaultModel" $null
    if ($defaultModel) {
        $defaults["profile"] = Add-HarnessLegacyProfile -Profiles $profiles -ByModel $byModel -Model ([string]$defaultModel)
    }
    foreach ($pair in @(@("options", "options"), @("timeoutSec", "timeoutSec"), @("stripThinking", "stripThinking"))) {
        $value = Get-ConfigValue $Config $pair[0] $null
        if ($null -ne $value) { $defaults[$pair[1]] = $value }
    }

    $ollama = [ordered]@{}
    $url = Get-ConfigValue $Config "ollamaUrl" $null
    if ($null -ne $url) { $ollama["url"] = $url }

    return [pscustomobject]@{
        schemaVersion = 2
        ollama        = [pscustomobject]$ollama
        defaults      = [pscustomobject]$defaults
        profiles      = [pscustomobject]$profiles
        agents        = [pscustomobject]$agents
    }
}

function Add-HarnessUnknownKeys {
    param($Object, [string[]]$Known, [string]$Path, $Warnings)

    if (-not (Test-HarnessObject $Object)) { return }
    foreach ($member in $Object.PSObject.Properties) {
        if ($Known -notcontains $member.Name) {
            $where = $member.Name
            if ($Path) { $where = "$Path.$($member.Name)" }
            $Warnings.Add("unknown_key:$where")
        }
    }
}

# Validates a v2 object. Throws "registry_invalid: <rule> (<name>)..." on the
# first violated rule (FR-103) and adds warning codes to $Warnings.
function Assert-HarnessRegistryV2 {
    param($Config, $Warnings)

    $schema = $Config.schemaVersion
    if (-not (Test-HarnessInteger $schema) -or $schema -ne 2) {
        throw "registry_invalid: schemaVersion (schemaVersion=$schema, expected 2)"
    }

    foreach ($section in @("ollama", "defaults", "profiles", "agents")) {
        $value = Get-ConfigValue $Config $section $null
        if ($null -ne $value -and -not (Test-HarnessObject $value)) {
            throw "registry_invalid: structure ($section must be an object)"
        }
    }

    $ollama = Get-ConfigValue $Config "ollama" $null
    $defaults = Get-ConfigValue $Config "defaults" $null
    $profiles = Get-ConfigValue $Config "profiles" $null
    $agents = Get-ConfigValue $Config "agents" $null

    $defaultOptions = Get-ConfigValue $defaults "options" $null
    if ($null -ne $defaultOptions -and -not (Test-HarnessObject $defaultOptions)) {
        throw "registry_invalid: structure (defaults.options must be an object)"
    }

    $ratio = Get-ConfigValue $defaults "safetyMarginRatio" 0.10
    if (-not (Test-HarnessNumber $ratio) -or $ratio -lt 0) {
        throw "registry_invalid: safetyMarginRatio (defaults.safetyMarginRatio must be a number >= 0)"
    }

    $healthTimeout = Get-ConfigValue $ollama "healthTimeoutSec" $null
    if ($null -ne $healthTimeout -and
        (-not (Test-HarnessInteger $healthTimeout) -or $healthTimeout -lt 1 -or $healthTimeout -gt 600)) {
        throw "registry_invalid: ollama.healthTimeoutSec (ollama.healthTimeoutSec must be an integer from 1 to 600)"
    }

    $ollamaUrl = Get-ConfigValue $ollama "url" $null
    if ($null -ne $ollamaUrl -and ($ollamaUrl -isnot [string] -or [string]::IsNullOrWhiteSpace($ollamaUrl))) {
        throw "registry_invalid: ollama.url (ollama.url must be a non-blank string)"
    }

    # Phase 2 engine fields (FR-217). All optional; the defaults are applied in
    # ConvertTo-HarnessRegistry.
    $maxAttempts = Get-ConfigValue $ollama "maxAttempts" $null
    if ($null -ne $maxAttempts -and
        (-not (Test-HarnessInteger $maxAttempts) -or $maxAttempts -lt 1 -or $maxAttempts -gt 5)) {
        throw "registry_invalid: ollama.maxAttempts (ollama.maxAttempts must be an integer from 1 to 5)"
    }

    $retryBackoff = Get-ConfigValue $ollama "retryBackoffSec" $null
    if ($null -ne $retryBackoff -and
        (-not (Test-HarnessInteger $retryBackoff) -or $retryBackoff -lt 0 -or $retryBackoff -gt 60)) {
        throw "registry_invalid: ollama.retryBackoffSec (ollama.retryBackoffSec must be an integer from 0 to 60)"
    }

    $warmup = Get-ConfigValue $ollama "warmup" $null
    if ($null -ne $warmup -and $warmup -isnot [bool]) {
        throw "registry_invalid: ollama.warmup (ollama.warmup must be true or false)"
    }

    $charsPerToken = Get-ConfigValue $defaults "charsPerToken" $null
    if ($null -ne $charsPerToken -and
        (-not (Test-HarnessNumber $charsPerToken) -or [decimal]$charsPerToken -le 0 -or [decimal]$charsPerToken -gt 10)) {
        throw "registry_invalid: defaults.charsPerToken (defaults.charsPerToken must be a number greater than 0 and at most 10)"
    }

    $budgetMode = Get-ConfigValue $defaults "budgetMode" $null
    if ($null -ne $budgetMode -and
        -not (($budgetMode -is [string]) -and (($budgetMode -ceq "enforce") -or ($budgetMode -ceq "warn")))) {
        throw "registry_invalid: defaults.budgetMode (defaults.budgetMode must be `"enforce`" or `"warn`")"
    }

    $defaultTimeout = Get-ConfigValue $defaults "timeoutSec" $null
    if ($null -ne $defaultTimeout -and
        (-not (Test-HarnessInteger $defaultTimeout) -or $defaultTimeout -lt 30 -or $defaultTimeout -gt 14400)) {
        throw "registry_invalid: timeoutSec (defaults.timeoutSec must be an integer from 30 to 14400)"
    }

    if ($profiles) {
        foreach ($entry in $profiles.PSObject.Properties) {
            $name = $entry.Name
            $p = $entry.Value
            $where = "profiles.$name"

            if (-not (Test-HarnessObject $p)) {
                throw "registry_invalid: structure ($where must be an object)"
            }

            $model = Get-ConfigValue $p "model" $null
            if ($model -isnot [string] -or [string]::IsNullOrWhiteSpace($model)) {
                throw "registry_invalid: profile_model ($where.model must be a non-blank string)"
            }

            $timeout = Get-ConfigValue $p "timeoutSec" $null
            if ($null -ne $timeout -and
                (-not (Test-HarnessInteger $timeout) -or $timeout -lt 30 -or $timeout -gt 14400)) {
                throw "registry_invalid: timeoutSec ($where.timeoutSec must be an integer from 30 to 14400)"
            }

            $window = Get-ConfigValue $p "contextWindow" $null
            if ($null -ne $window -and (-not (Test-HarnessInteger $window) -or $window -le 0)) {
                throw "registry_invalid: contextWindow ($where.contextWindow must be a positive integer)"
            }

            $reserved = Get-ConfigValue $p "reservedOutputTokens" $null
            if ($null -ne $reserved -and (-not (Test-HarnessInteger $reserved) -or $reserved -le 0)) {
                throw "registry_invalid: reservedOutputTokens ($where.reservedOutputTokens must be a positive integer)"
            }

            if ($null -ne $window -and $null -ne $reserved) {
                $margin = [math]::Ceiling([decimal]$ratio * [decimal]$window)
                if ([decimal]$window -le ([decimal]$reserved + $margin)) {
                    throw "registry_invalid: context_margin ($where.contextWindow must be greater than reservedOutputTokens plus the safety margin)"
                }
            }

            $profileOptions = Get-ConfigValue $p "options" $null
            if ($null -ne $profileOptions -and -not (Test-HarnessObject $profileOptions)) {
                throw "registry_invalid: structure ($where.options must be an object)"
            }

            if ($null -ne $window) {
                foreach ($source in @(@("defaults.options", $defaultOptions), @("$where.options", $profileOptions))) {
                    $numCtx = Get-HarnessMember $source[1] "num_ctx"
                    if ($null -ne $numCtx -and $null -ne $numCtx.Value -and
                        (-not (Test-HarnessNumber $numCtx.Value) -or [decimal]$numCtx.Value -ne [decimal]$window)) {
                        throw "registry_invalid: num_ctx ($($source[0]).num_ctx must equal $where.contextWindow)"
                    }
                }
            }

            $think = Get-ConfigValue $p "think" "default"
            if (-not (($think -is [bool]) -or (($think -is [string]) -and ($think -ceq "default")))) {
                throw "registry_invalid: think ($where.think must be true, false or `"default`")"
            }

            Add-HarnessUnknownKeys -Object $p -Known @("model", "contextWindow", "timeoutSec", "reservedOutputTokens", "think", "options") -Path $where -Warnings $Warnings
        }
    }

    $defaultProfile = Get-ConfigValue $defaults "profile" $null
    if ($null -ne $defaultProfile) {
        if ($defaultProfile -isnot [string] -or $null -eq (Get-HarnessMember $profiles $defaultProfile)) {
            throw "registry_invalid: defaults_profile (defaults.profile '$defaultProfile' is not a profile)"
        }
    }

    if ($agents) {
        foreach ($entry in $agents.PSObject.Properties) {
            $where = "agents.$($entry.Name)"
            if (-not (Test-HarnessObject $entry.Value)) {
                throw "registry_invalid: structure ($where must be an object)"
            }
            $agentProfile = Get-ConfigValue $entry.Value "profile" $null
            if ($agentProfile -isnot [string] -or $null -eq (Get-HarnessMember $profiles $agentProfile)) {
                throw "registry_invalid: agent_profile ($where.profile '$agentProfile' is not a profile)"
            }
            Add-HarnessUnknownKeys -Object $entry.Value -Known @("profile") -Path $where -Warnings $Warnings
        }
    }

    $url = Get-ConfigValue $ollama "url" $null
    if ($null -ne $url) {
        $uri = $null
        $loopback = $false
        if ([System.Uri]::TryCreate([string]$url, [System.UriKind]::Absolute, [ref]$uri)) {
            $address = $null
            if ($uri.DnsSafeHost -ieq "localhost") { $loopback = $true }
            elseif ([System.Net.IPAddress]::TryParse($uri.DnsSafeHost, [ref]$address)) {
                $loopback = ($address.Equals([System.Net.IPAddress]::Loopback) -or $address.Equals([System.Net.IPAddress]::IPv6Loopback))
            }
        }
        if (-not $loopback) { $Warnings.Add("non_loopback_ollama_url") }
    }

    Add-HarnessUnknownKeys -Object $Config -Known @("schemaVersion", "ollama", "defaults", "profiles", "agents") -Path "" -Warnings $Warnings
    Add-HarnessUnknownKeys -Object $ollama -Known @("url", "healthTimeoutSec", "maxAttempts", "retryBackoffSec", "warmup") -Path "ollama" -Warnings $Warnings
    Add-HarnessUnknownKeys -Object $defaults -Known @("profile", "options", "timeoutSec", "safetyMarginRatio", "stripThinking", "charsPerToken", "budgetMode") -Path "defaults" -Warnings $Warnings
}

# Config object (v1 or v2, as returned by Get-HarnessConfig; $null counts as an
# empty v1 file) -> normalized v2 registry with every default filled in.
function ConvertTo-HarnessRegistry {
    param($Config)

    # An already normalized registry is returned as it is.
    if ($null -ne $Config -and $Config.PSObject.TypeNames -contains "Harness.Registry") { return $Config }

    $warnings = New-Object 'System.Collections.Generic.List[string]'

    if ($null -ne (Get-HarnessMember $Config "schemaVersion")) {
        Assert-HarnessRegistryV2 -Config $Config -Warnings $warnings
        $raw = $Config
    }
    else {
        $raw = ConvertFrom-HarnessV1Config -Config $Config
    }

    $ollama = Get-ConfigValue $raw "ollama" $null
    $defaults = Get-ConfigValue $raw "defaults" $null

    $profiles = [ordered]@{}
    $rawProfiles = Get-ConfigValue $raw "profiles" $null
    if ($rawProfiles) {
        foreach ($entry in $rawProfiles.PSObject.Properties) {
            $p = $entry.Value
            $profileOptions = Get-ConfigValue $p "options" $null
            if (-not (Test-HarnessObject $profileOptions)) { $profileOptions = [pscustomobject]@{} }
            $profiles[$entry.Name] = [pscustomobject]@{
                model                = $p.model
                contextWindow        = Get-ConfigValue $p "contextWindow" $null
                timeoutSec           = Get-ConfigValue $p "timeoutSec" $null
                reservedOutputTokens = Get-ConfigValue $p "reservedOutputTokens" $null
                think                = Get-ConfigValue $p "think" "default"
                options              = $profileOptions
            }
        }
    }

    $agents = [ordered]@{}
    $rawAgents = Get-ConfigValue $raw "agents" $null
    if ($rawAgents) {
        foreach ($entry in $rawAgents.PSObject.Properties) {
            $agents[$entry.Name] = [pscustomobject]@{ profile = $entry.Value.profile }
        }
    }

    $defaultOptions = Get-ConfigValue $defaults "options" $null
    if (-not (Test-HarnessObject $defaultOptions)) { $defaultOptions = [pscustomobject]@{} }

    $registry = [pscustomobject]@{
        schemaVersion = 2
        ollama        = [pscustomobject]@{
            url              = Get-ConfigValue $ollama "url" "http://localhost:11434"
            healthTimeoutSec = Get-ConfigValue $ollama "healthTimeoutSec" 15
            maxAttempts      = Get-ConfigValue $ollama "maxAttempts" 2
            retryBackoffSec  = Get-ConfigValue $ollama "retryBackoffSec" 5
            warmup           = Get-ConfigValue $ollama "warmup" $false
        }
        defaults      = [pscustomobject]@{
            profile           = Get-ConfigValue $defaults "profile" $null
            options           = $defaultOptions
            timeoutSec        = Get-ConfigValue $defaults "timeoutSec" 600
            safetyMarginRatio = Get-ConfigValue $defaults "safetyMarginRatio" 0.10
            stripThinking     = Get-ConfigValue $defaults "stripThinking" $true
            charsPerToken     = Get-ConfigValue $defaults "charsPerToken" 3.5
            budgetMode        = Get-ConfigValue $defaults "budgetMode" "warn"
        }
        profiles      = [pscustomobject]$profiles
        agents        = [pscustomobject]$agents
        warnings      = $warnings.ToArray()
    }
    $registry.PSObject.TypeNames.Insert(0, "Harness.Registry")
    return $registry
}

# Reads the configuration file (v1 or v2) and returns the normalized v2 registry.
function Get-HarnessRegistry {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    return ConvertTo-HarnessRegistry -Config (Get-HarnessConfig -ConfigPath $ConfigPath)
}

# Distinct profile models, in profile order (case-insensitive). Callers wrap the
# call in @() so that zero or one model still gives an array.
function Get-HarnessRegistryModels {
    param([Parameter(Mandatory = $true)]$Registry)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    $models = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $Registry.profiles.PSObject.Properties) {
        $model = [string]$entry.Value.model
        if (-not [string]::IsNullOrWhiteSpace($model) -and $seen.Add($model)) { $models.Add($model) }
    }
    return $models.ToArray()
}

# defaults.options, then the profile's options, then num_ctx = contextWindow.
function Get-HarnessEffectiveOptions {
    param($Registry, $Profile)

    $merged = [ordered]@{}
    $sources = @($Registry.defaults.options)
    if ($null -ne $Profile) { $sources += $Profile.options }
    foreach ($source in $sources) {
        if (-not (Test-HarnessObject $source)) { continue }
        foreach ($entry in $source.PSObject.Properties) { $merged[$entry.Name] = $entry.Value }
    }
    if ($null -ne $Profile -and $null -ne $Profile.contextWindow) { $merged["num_ctx"] = $Profile.contextWindow }
    return [pscustomobject]$merged
}

# Resolves the model and its parameters (XR-02, FR-104). Sends nothing.
function Resolve-HarnessExecution {
    param(
        [Parameter(Mandatory = $true)][string]$Agent,
        [Parameter(Mandatory = $true)]$Registry,
        [string]$Model,
        [string]$Profile
    )

    $modelBound = $PSBoundParameters.ContainsKey('Model')
    $profileBound = $PSBoundParameters.ContainsKey('Profile')

    if ($modelBound -and $profileBound) {
        throw "invalid_arguments: -Model and -Profile cannot be used together."
    }

    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $profileName = ""
    $parametersFrom = ""
    $source = ""
    $resolvedModel = $null

    $override = $null
    if ($modelBound) {
        $override = @{ Model = $Model; Source = "explicit-model" }
    }
    elseif (-not $profileBound -and -not [string]::IsNullOrWhiteSpace($env:AI_HARNESS_MODEL)) {
        $override = @{ Model = $env:AI_HARNESS_MODEL; Source = "env" }
    }

    $agentEntry = Get-HarnessMember $Registry.agents $Agent
    $agentProfile = ""
    if ($agentEntry) { $agentProfile = [string]$agentEntry.Value.profile }
    $defaultProfile = [string]$Registry.defaults.profile

    if ($profileBound) {
        if ($null -eq (Get-HarnessMember $Registry.profiles $Profile)) {
            throw "registry_invalid: unknown_profile (-Profile '$Profile' is not a profile)"
        }
        $profileName = (Get-HarnessMember $Registry.profiles $Profile).Name
        $parametersFrom = $profileName
        $source = "explicit-profile"
    }
    elseif ($null -ne $override) {
        $resolvedModel = $override.Model
        $source = $override.Source

        $sameModel = @()
        if (-not [string]::IsNullOrWhiteSpace($resolvedModel)) {
            $sameModel = @($Registry.profiles.PSObject.Properties | Where-Object { [string]$_.Value.model -ieq $resolvedModel })
        }

        if ($sameModel.Count -eq 1) {
            $profileName = $sameModel[0].Name
            $parametersFrom = $profileName
        }
        else {
            if ($sameModel.Count -eq 0) { $warnings.Add("unregistered_model_override") }
            foreach ($candidate in @($agentProfile, $defaultProfile)) {
                if ($candidate -and $null -ne (Get-HarnessMember $Registry.profiles $candidate)) {
                    $parametersFrom = (Get-HarnessMember $Registry.profiles $candidate).Name
                    break
                }
            }
        }
    }
    elseif ($agentProfile) {
        if ($null -eq (Get-HarnessMember $Registry.profiles $agentProfile)) {
            throw "registry_invalid: agent_profile (agents.$Agent.profile '$agentProfile' is not a profile)"
        }
        $profileName = (Get-HarnessMember $Registry.profiles $agentProfile).Name
        $parametersFrom = $profileName
        $source = "agent"
    }
    elseif ($defaultProfile) {
        if ($null -eq (Get-HarnessMember $Registry.profiles $defaultProfile)) {
            throw "registry_invalid: defaults_profile (defaults.profile '$defaultProfile' is not a profile)"
        }
        $profileName = (Get-HarnessMember $Registry.profiles $defaultProfile).Name
        $parametersFrom = $profileName
        $source = "default"
    }
    else {
        throw "No model configured. Use -Model, set AI_HARNESS_MODEL, or define defaultModel in .ai\config.json."
    }

    $parameters = $null
    if ($parametersFrom) { $parameters = $Registry.profiles.$parametersFrom }
    if ($null -eq $override) { $resolvedModel = [string]$parameters.model }

    $timeoutSec = $Registry.defaults.timeoutSec
    if ($null -ne $parameters -and $null -ne $parameters.timeoutSec) { $timeoutSec = $parameters.timeoutSec }

    $think = "default"
    if ($null -ne $parameters) { $think = $parameters.think }

    return [pscustomobject][ordered]@{
        agent                = $Agent
        profile              = $profileName
        model                = $resolvedModel
        modelSource          = $source
        parametersFrom       = $parametersFrom
        contextWindow        = $(if ($null -ne $parameters) { $parameters.contextWindow } else { $null })
        timeoutSec           = $timeoutSec
        reservedOutputTokens = $(if ($null -ne $parameters) { $parameters.reservedOutputTokens } else { $null })
        options              = (Get-HarnessEffectiveOptions -Registry $Registry -Profile $parameters)
        think                = $think
        warnings             = $warnings.ToArray()
    }
}

# Compatibility wrapper: same parameters and behavior as before the registry.
# -Config is the object returned by Get-HarnessConfig (v1 or v2).
function Resolve-HarnessModel {
    param(
        [Parameter(Mandatory = $true)][string]$Agent,
        [bool]$ModelWasProvided,
        [string]$ExplicitModel,
        $Config
    )

    # An explicit model is returned unchanged, even when blank: callers validate it.
    if ($ModelWasProvided) { return $ExplicitModel }

    $registry = ConvertTo-HarnessRegistry -Config $Config
    return [string](Resolve-HarnessExecution -Agent $Agent -Registry $registry).model
}
function Invoke-HarnessGenerate {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$System,
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)]$Config,
        [string]$TelemetryAgent,
        [string]$TelemetryRoot,
        $Execution
    )

    # -Config is a configuration object (v1 or v2) or a normalized registry.
    # -Execution is the record of Resolve-HarnessExecution; without it the
    # registry defaults apply, as before the registry. No think member is sent.
    $registry      = ConvertTo-HarnessRegistry -Config $Config
    $ollamaUrl     = ([string]$registry.ollama.url).TrimEnd('/')
    $timeoutSec    = [int]$registry.defaults.timeoutSec
    $stripThinking = [bool]$registry.defaults.stripThinking
    $options       = Get-HarnessEffectiveOptions -Registry $registry -Profile $null
    if ($null -ne $Execution) {
        $timeoutSec = [int]$Execution.timeoutSec
        $options    = $Execution.options
    }

    $payload = @{ model = $Model; system = $System; prompt = $Prompt; stream = $false }
    if (@($options.PSObject.Properties).Count -gt 0) { $payload.options = $options }

    $json  = $payload | ConvertTo-Json -Depth 10
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)

    # Telemetry only when both parameters are given (FR-011): exactly one record
    # per request actually sent, written before an error is rethrown. Calls
    # without them behave as before. Needs lib\telemetry.ps1 dot-sourced.
    $writeTelemetry = (-not [string]::IsNullOrWhiteSpace($TelemetryAgent)) -and
        (-not [string]::IsNullOrWhiteSpace($TelemetryRoot))
    $startedAt = [datetime]::UtcNow

    try {
        $response = Invoke-RestMethod `
            -Uri "$ollamaUrl/api/generate" `
            -Method Post `
            -ContentType "application/json; charset=utf-8" `
            -Body $bytes `
            -TimeoutSec $timeoutSec
    }
    catch {
        $requestError = $_.Exception.Message

        if ($writeTelemetry) {
            Write-HarnessModelTelemetry -Root $TelemetryRoot -Agent $TelemetryAgent -Model $Model `
                -StartedAt $startedAt -Status "error" -ErrorMessage $requestError
        }

        throw "Ollama request failed: $requestError"
    }

    if ($writeTelemetry) {
        Write-HarnessModelTelemetry -Root $TelemetryRoot -Agent $TelemetryAgent -Model $Model `
            -StartedAt $startedAt -Status "success" -Response $response
    }

    $text = "$($response.response)"
    if ($stripThinking) {
        $text = [regex]::Replace($text, '(?s)<think>.*?</think>\s*', '')
    }
    return $text.Trim()
}

# Same check as run-agent.ps1 (FR-010): Ollama is reachable and the model is
# installed (exact name, case-insensitive). Prints the problem and returns it;
# returns nothing when the model is available. Sends no generation request.
function Test-HarnessModelAvailable {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)]$Config
    )

    $registry         = ConvertTo-HarnessRegistry -Config $Config
    $ollamaUrl        = ([string]$registry.ollama.url).TrimEnd('/')
    $healthTimeoutSec = [int]$registry.ollama.healthTimeoutSec

    try {
        $ollamaTags = Invoke-RestMethod -Uri "$ollamaUrl/api/tags" -Method Get -TimeoutSec $healthTimeoutSec
    }
    catch {
        $problem = "Ollama is not reachable at $ollamaUrl. Make sure Ollama is running."
        Write-Host $problem -ForegroundColor Red
        return $problem
    }

    $availableModels = @($ollamaTags.models | ForEach-Object { $_.name })

    if ($availableModels -notcontains $Model) {
        Write-Host "Model not found: $Model" -ForegroundColor Red
        Write-Host "Available models:" -ForegroundColor Yellow
        foreach ($m in $availableModels) { Write-Host "  - $m" }
        return "The requested Ollama model is not installed. Try: ollama pull $Model"
    }
}