# Unified CLI entry point (Phase 3 work package B3: FR-301, FR-302).
#
#   harness.ps1 <command> [options]       see lib\cli.ps1 and specs\harness-phase-3-unified-cli.md
#
# This script has no param block, no [CmdletBinding()], no [Parameter()] and no validation
# attribute on purpose: PowerShell must never reject an input first (a localized message and
# exit 1). It parses $args against the literal table of lib\cli.ps1 and calls
# Invoke-HarnessCli. Exit codes: 0 success, 1 workflow failure, 2 error, 3 needs input,
# 4 unsupported stage. The stage scripts and the hook are not options (D-310): tests call
# Invoke-HarnessCli in lib\cli.ps1 directly.

$ErrorActionPreference = 'Stop'
$harnessCliResult = @{ exitCode = 2 }
try {
    . (Join-Path $PSScriptRoot 'lib\cli.ps1')
    $harnessCliParsed = ConvertFrom-HarnessCliArguments -Arguments @($args)
    if ($harnessCliParsed.ok) {
        Invoke-HarnessCli -Command $harnessCliParsed.command -Options $harnessCliParsed.options -Result $harnessCliResult
    }
    else {
        Write-Output ('ERROR: invalid_arguments: ' + $harnessCliParsed.message)
        $harnessCliResult.exitCode = 2
    }
}
catch {
    Write-Output ('ERROR: internal_error: ' + ([string]$_.Exception.Message -replace '[\r\n]+', ' '))
    $harnessCliResult.exitCode = 2
}
exit ([int]$harnessCliResult.exitCode)
