<#
.SYNOPSIS
    Offline, in-process tests for Get-AgentErrorCategory of scripts\lib\agent-exec.ps1
    and for the test doubles tests\mocks\fake-web-response.ps1 and
    tests\mocks\fake-transport.ps1
    (Phase 2, WP-2B2; FR-211, FR-204, NFR-202, AC-207, RK-205, A-201, A-202).

.DESCRIPTION
    - No network, no Ollama, no child process, no sleeping, no file written by the
      suite itself: the libraries and mocks are dot-sourced and called with literal
      values. (Add-Type compiles the fake WebResponse once; the compiler writes only
      under TEMP.)
    - Every expected category is a literal worked out by hand from the FR-211 table
      (the table is repeated in the comment above each group), never computed from
      the code under test.
    - Assertions never read localized text (NFR-202): categories, flags, numbers,
      exception type names, and the harness's own fixed wording of its hints (only
      that they are present, single-line and distinct).
    - Guards: a stub named Invoke-OllamaHttp records any call as a violation (none is
      expected, the classifier is pure) and a static scan finds no HTTP route in
      agent-exec.ps1 other than a single Invoke-RestMethod inside Invoke-OllamaHttp.
#>
param()

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$engineLibrary = Join-Path $PSScriptRoot "lib\agent-exec.ps1"
$mockWebResponse = Join-Path $root "tests\mocks\fake-web-response.ps1"
$mockTransport = Join-Path $root "tests\mocks\fake-transport.ps1"

foreach ($path in @($engineLibrary, $mockWebResponse, $mockTransport)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required path not found: $path" }
}

. $engineLibrary
. $mockWebResponse
. $mockTransport

# Guard: the default transport must never be reached by this suite. Defined after
# the library so it wins over a real Invoke-OllamaHttp that a later package adds.
$script:transportViolations = 0
function Invoke-OllamaHttp {
    param($Request)
    $script:transportViolations++
    throw "violation: Invoke-OllamaHttp was called by an offline in-process suite"
}

$script:passed = 0
$script:failed = 0

function Test-Case {
    param([string]$Name, [scriptblock]$Body)

    try {
        & $Body
        $script:passed++
        Write-Host "[PASS] $Name" -ForegroundColor Green
    }
    catch {
        $script:failed++
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-Equal {
    param([string]$What, $Expected, $Actual)

    if (-not ("$Expected" -ceq "$Actual")) {
        throw "$What : expected '$Expected', got '$Actual'"
    }
}

function Assert-True {
    param([string]$What, $Condition)

    if (-not $Condition) { throw "$What : condition is false" }
}

function Assert-Throws {
    param([string]$What, [scriptblock]$Action, [string]$Prefix = "")

    $message = $null
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }

    if ($null -eq $message) { throw "$What : nothing was thrown" }
    if ($Prefix -and -not $message.StartsWith($Prefix, [System.StringComparison]::Ordinal)) {
        throw "$What : expected a message starting with '$Prefix', got '$message'"
    }
}

# A transport failure record the way FR-204 describes it.
function New-Failure {
    param([string]$Type = "", $WebStatus = $null, $Body = $null, [string]$Message = "")

    return [pscustomobject][ordered]@{ exceptionType = $Type; webStatus = $WebStatus; body = $Body; message = $Message }
}

# Classifies and returns the category only.
function Get-Category {
    param($Failure = $null, $HttpStatus = $null)

    return (Get-AgentErrorCategory -Failure $Failure -HttpStatus $HttpStatus).category
}

# The eleven categories of FR-211 and whether the retry rule repeats them (FR-211, FR-212).
$allCategories = @("http_5xx", "http_4xx", "timeout", "transport_unreachable", "transport_reset", "transport_other",
    "context_budget_exceeded", "thinking_budget_exhausted", "empty_response", "format_invalid", "model_not_installed")
$retryableCategories = @("http_5xx", "transport_reset")

# The whole of System.Net.WebExceptionStatus (.NET Framework 4.x), with the category
# FR-211 gives each member when no HTTP status is present, worked out by hand:
#   Timeout -> timeout
#   ConnectFailure, NameResolutionFailure, ProxyNameResolutionFailure -> transport_unreachable
#   ConnectionClosed, ReceiveFailure, SendFailure, KeepAliveFailure, PipelineFailure -> transport_reset
#   every other member -> transport_other
$webStatusExpected = [ordered]@{
    Success                        = "transport_other"
    NameResolutionFailure          = "transport_unreachable"
    ConnectFailure                 = "transport_unreachable"
    ReceiveFailure                 = "transport_reset"
    SendFailure                    = "transport_reset"
    PipelineFailure                = "transport_reset"
    RequestCanceled                = "transport_other"
    ProtocolError                  = "transport_other"
    ConnectionClosed               = "transport_reset"
    TrustFailure                   = "transport_other"
    SecureChannelFailure           = "transport_other"
    ServerProtocolViolation        = "transport_other"
    KeepAliveFailure               = "transport_reset"
    Pending                        = "transport_other"
    Timeout                        = "timeout"
    ProxyNameResolutionFailure     = "transport_unreachable"
    UnknownError                   = "transport_other"
    MessageLengthLimitExceeded     = "transport_other"
    CacheEntryNotFound             = "transport_other"
    RequestProhibitedByCachePolicy = "transport_other"
    RequestProhibitedByProxy       = "transport_other"
}

try {
    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "   AGENT ERROR CATEGORIES (OFFLINE)" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan

    # -----------------------------------------------------------------------
    # RK-205 / A-202: the fake WebResponse compiles and behaves like a real one
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== RK-205 fake WebResponse ===" -ForegroundColor Cyan

    Test-Case "RK-205 the fake WebResponse type compiled and dot-sourcing the mock twice is harmless" {
        Assert-True "type exists" ('HarnessFakeWebResponse' -as [type])
        . $mockWebResponse
        Assert-True "still a WebResponse" ([System.Net.WebResponse].IsAssignableFrom([HarnessFakeWebResponse]))
    }

    Test-Case "RK-205 a WebException from the fake reports Status ProtocolError, Response.StatusCode and a body read from the stream" {
        $e = New-FakeHttpWebException -StatusCode 503 -Body '{"error":"gpu init failed"}'
        Assert-Equal "type" "System.Net.WebException" $e.GetType().FullName
        Assert-Equal "Status" "ProtocolError" $e.Status.ToString()
        Assert-Equal "StatusCode" 503 ([int]$e.Response.StatusCode)
        Assert-Equal "body" '{"error":"gpu init failed"}' (Read-FakeWebExceptionBody $e)
        Assert-Equal "second read of the stream" '{"error":"gpu init failed"}' (Read-FakeWebExceptionBody $e)
    }

    Test-Case "RK-205 a null or empty body reads as an empty string; a multi-byte body survives (UTF-8)" {
        Assert-Equal "null body" 0 ((Read-FakeWebExceptionBody (New-FakeHttpWebException -StatusCode 400 -Body $null)).Length)
        Assert-Equal "empty body" 0 ((Read-FakeWebExceptionBody (New-FakeHttpWebException -StatusCode 400 -Body "")).Length)
        $text = "a" + [char]0x00E9 + [char]0x4E2D + [char]::ConvertFromUtf32(0x1F600)
        Assert-Equal "multi-byte" $text (Read-FakeWebExceptionBody (New-FakeHttpWebException -StatusCode 500 -Body $text))
    }

    Test-Case "RK-205 a status-only fake WebException has Status and no Response" {
        $e = New-FakeStatusWebException -Status Timeout
        Assert-Equal "Status" "Timeout" $e.Status.ToString()
        Assert-True "no response" ($null -eq $e.Response)
        Assert-True "no body" ($null -eq (Read-FakeWebExceptionBody $e))
    }

    Test-Case "RK-205 thrown from a function named Invoke-RestMethod the exception keeps its type, Status, StatusCode and body (ErrorDetails is null, so the stream is the path)" {
        $caught = & {
            function Invoke-RestMethod { param([string]$Uri) throw (New-FakeHttpWebException -StatusCode 500 -Body '{"error":"boom"}') }
            try { Invoke-RestMethod -Uri "http://127.0.0.1:9/api/generate"; $null }
            catch { [pscustomobject]@{ Exception = $_.Exception; ErrorDetailsNull = ($null -eq $_.ErrorDetails) } }
        }
        Assert-True "something was caught" ($null -ne $caught)
        Assert-Equal "type" "System.Net.WebException" $caught.Exception.GetType().FullName
        Assert-Equal "Status" "ProtocolError" $caught.Exception.Status.ToString()
        Assert-Equal "StatusCode" 500 ([int]$caught.Exception.Response.StatusCode)
        Assert-Equal "body" '{"error":"boom"}' (Read-FakeWebExceptionBody $caught.Exception)
        Assert-True "ErrorDetails is null for a thrown fake" $caught.ErrorDetailsNull
    }

    Test-Case "RK-205 a failure record built from a fake HTTP exception (the A-201 mapping) classifies by StatusCode and takes its detail from the body" {
        $e = New-FakeHttpWebException -StatusCode 503 -Body '{"error":"gpu init failed"}'
        $failure = New-Failure -Type $e.GetType().FullName -WebStatus $e.Status.ToString() -Body (Read-FakeWebExceptionBody $e)
        $result = Get-AgentErrorCategory -Failure $failure -HttpStatus ([int]$e.Response.StatusCode)
        Assert-Equal "category" "http_5xx" $result.category
        Assert-Equal "retryable" $true $result.retryable
        Assert-Equal "detail" "gpu init failed" $result.detail
    }

    # -----------------------------------------------------------------------
    # AC-207 table over every row of FR-211
    #   1. HTTP status 500..599 -> http_5xx (retryable)
    #   2. HTTP status 400..499 -> http_4xx
    #   3. any other HTTP status -> transport_other
    #   4. webStatus Timeout, or type System.TimeoutException -> timeout
    #   5. webStatus ConnectFailure | NameResolutionFailure | ProxyNameResolutionFailure -> transport_unreachable
    #   6. webStatus ConnectionClosed | ReceiveFailure | SendFailure | KeepAliveFailure | PipelineFailure,
    #      type System.IO.IOException | System.Net.Sockets.SocketException -> transport_reset (retryable)
    #   7. anything else -> transport_other
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== AC-207 classification table ===" -ForegroundColor Cyan

    Test-Case "AC-207 HTTP status boundaries: 399 other, 400 and 499 4xx, 500 and 599 5xx, 600 other (also 0, 100, 200, 301, -1)" {
        $expected = [ordered]@{
            "-1" = "transport_other"; "0" = "transport_other"; "100" = "transport_other"; "200" = "transport_other"
            "301" = "transport_other"; "399" = "transport_other"; "400" = "http_4xx"; "401" = "http_4xx"; "404" = "http_4xx"
            "429" = "http_4xx"; "499" = "http_4xx"; "500" = "http_5xx"; "501" = "http_5xx"; "503" = "http_5xx"
            "599" = "http_5xx"; "600" = "transport_other"; "999" = "transport_other"
        }
        foreach ($status in $expected.Keys) {
            Assert-Equal "status $status" $expected[$status] (Get-Category -Failure (New-Failure -Type "System.Net.WebException" -WebStatus "ProtocolError") -HttpStatus ([int]$status))
        }
    }

    Test-Case "AC-207 an HTTP status alone (no failure record) is classified, and a status given as text is read as a number" {
        Assert-Equal "500, no failure" "http_5xx" (Get-Category -HttpStatus 500)
        Assert-Equal "404, no failure" "http_4xx" (Get-Category -HttpStatus 404)
        Assert-Equal "'503' text" "http_5xx" (Get-Category -HttpStatus "503")
        Assert-Equal "'abc' text" "transport_other" (Get-Category -HttpStatus "abc")
        Assert-Equal "blank text means no status" "transport_other" (Get-Category -HttpStatus "")
        Assert-Equal "unparsable status is still an HTTP status: it beats a webStatus" "transport_other" (Get-Category -Failure (New-Failure -Type "System.Net.WebException" -WebStatus "Timeout") -HttpStatus "abc")
    }

    Test-Case "AC-207 every WebExceptionStatus member maps as the table says (all 21 members, no status present)" {
        $members = @([System.Enum]::GetNames([System.Net.WebExceptionStatus]))
        foreach ($member in $members) {
            Assert-True "the hand-written table has $member" ($webStatusExpected.Contains($member))
        }
        Assert-Equal "member count" $webStatusExpected.Count $members.Count
        foreach ($member in $webStatusExpected.Keys) {
            Assert-Equal "webStatus $member" $webStatusExpected[$member] (Get-Category -Failure (New-Failure -Type "System.Net.WebException" -WebStatus $member))
        }
    }

    Test-Case "AC-207 exception types: TimeoutException is timeout; IOException and SocketException are transport_reset; others are transport_other" {
        Assert-Equal "TimeoutException" "timeout" (Get-Category -Failure (New-Failure -Type "System.TimeoutException"))
        Assert-Equal "IOException" "transport_reset" (Get-Category -Failure (New-Failure -Type "System.IO.IOException"))
        Assert-Equal "SocketException" "transport_reset" (Get-Category -Failure (New-Failure -Type "System.Net.Sockets.SocketException"))
        foreach ($type in @("System.Management.Automation.RuntimeException", "System.InvalidOperationException", "System.Net.WebException",
                "System.IO.FileNotFoundException", "Contoso.UnknownException", "System.IO.IOExceptionX", "system.io.ioexception", "")) {
            Assert-Equal "type '$type'" "transport_other" (Get-Category -Failure (New-Failure -Type $type))
        }
    }

    Test-Case "AC-207 the real .NET exception types have the full names the table uses" {
        Assert-Equal "TimeoutException" "System.TimeoutException" ([System.TimeoutException]).FullName
        Assert-Equal "IOException" "System.IO.IOException" ([System.IO.IOException]).FullName
        Assert-Equal "SocketException" "System.Net.Sockets.SocketException" ([System.Net.Sockets.SocketException]).FullName
        $socket = New-Object System.Net.Sockets.SocketException
        Assert-Equal "an instance classifies as reset" "transport_reset" (Get-Category -Failure (New-Failure -Type $socket.GetType().FullName))
        $io = New-Object System.IO.IOException
        Assert-Equal "an IOException instance classifies as reset" "transport_reset" (Get-Category -Failure (New-Failure -Type $io.GetType().FullName))
        $timeout = New-Object System.TimeoutException
        Assert-Equal "a TimeoutException instance classifies as timeout" "timeout" (Get-Category -Failure (New-Failure -Type $timeout.GetType().FullName))
    }

    Test-Case "AC-207 fake WebExceptions built with the mock classify by Status (no response) and by StatusCode (response)" {
        foreach ($member in $webStatusExpected.Keys) {
            if ($member -ceq "ProtocolError" -or $member -ceq "Success" -or $member -ceq "Pending") { continue }
            $e = New-FakeStatusWebException -Status ([System.Net.WebExceptionStatus]$member)
            $failure = New-Failure -Type $e.GetType().FullName -WebStatus $e.Status.ToString()
            Assert-Equal "fake $member" $webStatusExpected[$member] (Get-Category -Failure $failure)
        }
        foreach ($code in 400, 499, 500, 599) {
            $e = New-FakeHttpWebException -StatusCode $code -Body '{"error":"x"}'
            $failure = New-Failure -Type $e.GetType().FullName -WebStatus $e.Status.ToString()
            $expected = if ($code -ge 500) { "http_5xx" } else { "http_4xx" }
            Assert-Equal "fake HTTP $code" $expected (Get-Category -Failure $failure -HttpStatus ([int]$e.Response.StatusCode))
        }
    }

    Test-Case "AC-207 row order: an HTTP status beats a webStatus, and an earlier row beats a later one" {
        # 4xx/5xx with a transport-looking webStatus: the status wins.
        Assert-Equal "500 + Timeout" "http_5xx" (Get-Category -Failure (New-Failure -Type "System.Net.WebException" -WebStatus "Timeout") -HttpStatus 500)
        Assert-Equal "404 + ConnectFailure" "http_4xx" (Get-Category -Failure (New-Failure -Type "System.Net.WebException" -WebStatus "ConnectFailure") -HttpStatus 404)
        Assert-Equal "502 + ConnectionClosed" "http_5xx" (Get-Category -Failure (New-Failure -Type "System.Net.WebException" -WebStatus "ConnectionClosed") -HttpStatus 502)
        Assert-Equal "302 + Timeout (any other status)" "transport_other" (Get-Category -Failure (New-Failure -Type "System.Net.WebException" -WebStatus "Timeout") -HttpStatus 302)
        # timeout row (4) before unreachable (5) before reset (6).
        Assert-Equal "ConnectFailure + TimeoutException" "timeout" (Get-Category -Failure (New-Failure -Type "System.TimeoutException" -WebStatus "ConnectFailure"))
        Assert-Equal "Timeout + IOException" "timeout" (Get-Category -Failure (New-Failure -Type "System.IO.IOException" -WebStatus "Timeout"))
        Assert-Equal "ConnectFailure + IOException" "transport_unreachable" (Get-Category -Failure (New-Failure -Type "System.IO.IOException" -WebStatus "ConnectFailure"))
        Assert-Equal "unrelated webStatus + IOException" "transport_reset" (Get-Category -Failure (New-Failure -Type "System.IO.IOException" -WebStatus "ProtocolError"))
    }

    Test-Case "AC-207 names are exact: a differently cased webStatus does not match" {
        Assert-Equal "timeout lower case" "transport_other" (Get-Category -Failure (New-Failure -Type "System.Net.WebException" -WebStatus "timeout"))
        Assert-Equal "CONNECTFAILURE" "transport_other" (Get-Category -Failure (New-Failure -Type "System.Net.WebException" -WebStatus "CONNECTFAILURE"))
    }

    Test-Case "AC-207 no failure and no status, or a failure with missing members, is transport_other" {
        Assert-Equal "nothing" "transport_other" (Get-Category)
        Assert-Equal "empty object" "transport_other" (Get-Category -Failure ([pscustomobject]@{}))
        Assert-Equal "only a body" "transport_other" (Get-Category -Failure ([pscustomobject]@{ body = "x" }))
        Assert-Equal "only a webStatus" "timeout" (Get-Category -Failure ([pscustomobject]@{ webStatus = "Timeout" }))
        Assert-Equal "only a type" "transport_reset" (Get-Category -Failure ([pscustomobject]@{ exceptionType = "System.IO.IOException" }))
    }

    Test-Case "AC-207 misleading text never decides: bodies and messages that say timed out, 500, refused or reset" {
        # a body that says "timed out" with status 500 is a 5xx
        Assert-Equal "body 'timed out' + 500" "http_5xx" (Get-Category -Failure (New-Failure -Type "System.Net.WebException" -WebStatus "ProtocolError" -Body "timed out") -HttpStatus 500)
        # a ConnectFailure whose body contains 500 is unreachable
        Assert-Equal "ConnectFailure + body 500" "transport_unreachable" (Get-Category -Failure (New-Failure -Type "System.Net.WebException" -WebStatus "ConnectFailure" -Body '{"error":"HTTP 500 Internal Server Error"}'))
        # messages never count, in any language
        foreach ($message in @("HTTP 500", "The operation has timed out", "Se agoto el tiempo de espera", "connection refused", "No es posible conectar con el servidor remoto", "reset by peer")) {
            Assert-Equal "message '$message' on a plain type" "transport_other" (Get-Category -Failure (New-Failure -Type "System.InvalidOperationException" -Message $message))
            Assert-Equal "message '$message' on Timeout" "timeout" (Get-Category -Failure (New-Failure -Type "System.Net.WebException" -WebStatus "Timeout" -Message $message))
            Assert-Equal "message '$message' on 404" "http_4xx" (Get-Category -Failure (New-Failure -Type "System.Net.WebException" -WebStatus "ProtocolError" -Message $message) -HttpStatus 404)
        }
        # a JSON error body that names another category changes nothing
        Assert-Equal "body error 'timeout' on 400" "http_4xx" (Get-Category -Failure (New-Failure -Type "System.Net.WebException" -WebStatus "ProtocolError" -Body '{"error":"timeout"}') -HttpStatus 400)
    }

    Test-Case "AC-207 the result of every table row is stable across UI and format cultures (es-ES, en-US, tr-TR)" {
        $thread = [System.Threading.Thread]::CurrentThread
        $savedUi = $thread.CurrentUICulture
        $savedCulture = $thread.CurrentCulture
        try {
            foreach ($name in @("es-ES", "en-US", "tr-TR")) {
                $culture = [System.Globalization.CultureInfo]::GetCultureInfo($name)
                $thread.CurrentUICulture = $culture
                $thread.CurrentCulture = $culture
                foreach ($member in $webStatusExpected.Keys) {
                    Assert-Equal "$name $member" $webStatusExpected[$member] (Get-Category -Failure (New-Failure -Type "System.Net.WebException" -WebStatus $member))
                }
                Assert-Equal "$name 399" "transport_other" (Get-Category -HttpStatus 399)
                Assert-Equal "$name 400" "http_4xx" (Get-Category -HttpStatus 400)
                Assert-Equal "$name 599" "http_5xx" (Get-Category -HttpStatus 599)
                Assert-Equal "$name IOException" "transport_reset" (Get-Category -Failure (New-Failure -Type "System.IO.IOException"))
            }
        }
        finally {
            $thread.CurrentUICulture = $savedUi
            $thread.CurrentCulture = $savedCulture
        }
    }

    # -----------------------------------------------------------------------
    # FR-211/FR-212 the retryable set: http_5xx and transport_reset only
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== retryable set ===" -ForegroundColor Cyan

    Test-Case "FR-211 retryable is true for http_5xx and transport_reset only (all 11 categories by name)" {
        foreach ($category in $allCategories) {
            $expected = ($retryableCategories -ccontains $category)
            $result = Get-AgentErrorCategory -Category $category
            Assert-Equal "category echoed ($category)" $category $result.category
            Assert-Equal "retryable of $category" $expected $result.retryable
        }
    }

    Test-Case "FR-211 the retryable flag of a classified failure follows its category (timeout and unreachable are not retried)" {
        $cases = @(
            @{ F = (New-Failure -Type "System.Net.WebException" -WebStatus "ProtocolError"); S = 500; Retry = $true },
            @{ F = (New-Failure -Type "System.Net.WebException" -WebStatus "ProtocolError"); S = 599; Retry = $true },
            @{ F = (New-Failure -Type "System.Net.WebException" -WebStatus "ProtocolError"); S = 400; Retry = $false },
            @{ F = (New-Failure -Type "System.Net.WebException" -WebStatus "Timeout"); S = $null; Retry = $false },
            @{ F = (New-Failure -Type "System.TimeoutException"); S = $null; Retry = $false },
            @{ F = (New-Failure -Type "System.Net.WebException" -WebStatus "ConnectFailure"); S = $null; Retry = $false },
            @{ F = (New-Failure -Type "System.Net.WebException" -WebStatus "NameResolutionFailure"); S = $null; Retry = $false },
            @{ F = (New-Failure -Type "System.Net.WebException" -WebStatus "ConnectionClosed"); S = $null; Retry = $true },
            @{ F = (New-Failure -Type "System.Net.WebException" -WebStatus "ReceiveFailure"); S = $null; Retry = $true },
            @{ F = (New-Failure -Type "System.Net.WebException" -WebStatus "SendFailure"); S = $null; Retry = $true },
            @{ F = (New-Failure -Type "System.Net.WebException" -WebStatus "KeepAliveFailure"); S = $null; Retry = $true },
            @{ F = (New-Failure -Type "System.Net.WebException" -WebStatus "PipelineFailure"); S = $null; Retry = $true },
            @{ F = (New-Failure -Type "System.IO.IOException"); S = $null; Retry = $true },
            @{ F = (New-Failure -Type "System.Net.Sockets.SocketException"); S = $null; Retry = $true },
            @{ F = (New-Failure -Type "Contoso.Unknown"); S = $null; Retry = $false },
            @{ F = (New-Failure -Type "System.Net.WebException" -WebStatus "ProtocolError"); S = 302; Retry = $false }
        )
        $index = 0
        foreach ($case in $cases) {
            $index++
            $result = Get-AgentErrorCategory -Failure $case.F -HttpStatus $case.S
            Assert-Equal "case $index ($($result.category)) retryable" $case.Retry $result.retryable
        }
    }

    Test-Case "FR-211 an unknown category name is a programmer error (invalid_arguments)" {
        Assert-Throws "unknown name" { Get-AgentErrorCategory -Category "no_such_category" } "invalid_arguments:"
        Assert-Throws "wrong case" { Get-AgentErrorCategory -Category "HTTP_5XX" } "invalid_arguments:"
        Assert-Throws "empty name" { Get-AgentErrorCategory -Category "" } "invalid_arguments:"
    }

    # -----------------------------------------------------------------------
    # Hints and detail
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== hints and detail ===" -ForegroundColor Cyan

    Test-Case "FR-211 every category has a fixed, non-empty, single-line, ASCII hint, and the hints differ" {
        $seen = @{}
        foreach ($category in $allCategories) {
            $hint = [string](Get-AgentErrorCategory -Category $category).hint
            Assert-True "$category has a hint" ($hint.Trim().Length -gt 0)
            Assert-True "$category hint is one line" ($hint.IndexOf("`r") -lt 0 -and $hint.IndexOf("`n") -lt 0)
            Assert-True "$category hint is ASCII" ($hint -cmatch '^[\x20-\x7E]+$')
            Assert-True "$category hint is not a duplicate" (-not $seen.ContainsKey($hint))
            $seen[$hint] = $true
            Assert-Equal "the hint is the same on a second call" $hint ([string](Get-AgentErrorCategory -Category $category).hint)
        }
        Assert-Equal "categories checked" 11 $seen.Count
    }

    Test-Case "FR-211 the hints of http_5xx and transport_reset mention restarting the Ollama server (the spec's example)" {
        foreach ($category in @("http_5xx", "transport_reset")) {
            $hint = [string](Get-AgentErrorCategory -Category $category).hint
            Assert-True "$category mentions restarting" ($hint.IndexOf("restart", [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
            Assert-True "$category mentions Ollama" ($hint.IndexOf("Ollama", [System.StringComparison]::Ordinal) -ge 0)
        }
    }

    Test-Case "FR-211 a classified failure carries the hint of its category" {
        foreach ($case in @(@{ S = 500; C = "http_5xx" }, @{ S = 400; C = "http_4xx" }, @{ S = 302; C = "transport_other" })) {
            $result = Get-AgentErrorCategory -Failure (New-Failure -Type "System.Net.WebException" -WebStatus "ProtocolError") -HttpStatus $case.S
            Assert-Equal "category" $case.C $result.category
            Assert-Equal "hint of $($case.C)" ([string](Get-AgentErrorCategory -Category $case.C).hint) $result.hint
        }
        $timeout = Get-AgentErrorCategory -Failure (New-Failure -Type "System.Net.WebException" -WebStatus "Timeout")
        Assert-Equal "timeout hint" ([string](Get-AgentErrorCategory -Category "timeout").hint) $timeout.hint
    }

    Test-Case "FR-211 detail: the string of Ollama's JSON error member, else the exception type and webStatus" {
        $webException = "System.Net.WebException"
        Assert-Equal "JSON error" "model 'x' not found" (Get-AgentErrorCategory -Failure (New-Failure -Type $webException -WebStatus "ProtocolError" -Body '{"error":"model ''x'' not found"}') -HttpStatus 404).detail
        Assert-Equal "JSON error with other members" "boom" (Get-AgentErrorCategory -Failure (New-Failure -Type $webException -WebStatus "ProtocolError" -Body '{"code":1,"error":"boom","x":[1]}') -HttpStatus 500).detail
        Assert-Equal "multi-byte JSON error" ("caf" + [char]0x00E9) (Get-AgentErrorCategory -Failure (New-Failure -Type $webException -WebStatus "ProtocolError" -Body ('{"error":"caf' + [char]0x00E9 + '"}')) -HttpStatus 500).detail
        # fallbacks: not JSON, JSON without a usable error, no body
        Assert-Equal "not JSON" "System.Net.WebException ProtocolError" (Get-AgentErrorCategory -Failure (New-Failure -Type $webException -WebStatus "ProtocolError" -Body "timed out") -HttpStatus 500).detail
        Assert-Equal "JSON without error" "System.Net.WebException ProtocolError" (Get-AgentErrorCategory -Failure (New-Failure -Type $webException -WebStatus "ProtocolError" -Body '{"message":"x"}') -HttpStatus 500).detail
        Assert-Equal "error is an object" "System.Net.WebException ProtocolError" (Get-AgentErrorCategory -Failure (New-Failure -Type $webException -WebStatus "ProtocolError" -Body '{"error":{"a":1}}') -HttpStatus 500).detail
        Assert-Equal "error is a number" "System.Net.WebException ProtocolError" (Get-AgentErrorCategory -Failure (New-Failure -Type $webException -WebStatus "ProtocolError" -Body '{"error":500}') -HttpStatus 500).detail
        Assert-Equal "error is empty" "System.Net.WebException ProtocolError" (Get-AgentErrorCategory -Failure (New-Failure -Type $webException -WebStatus "ProtocolError" -Body '{"error":""}') -HttpStatus 500).detail
        Assert-Equal "body is a bare number" "System.Net.WebException ProtocolError" (Get-AgentErrorCategory -Failure (New-Failure -Type $webException -WebStatus "ProtocolError" -Body "500") -HttpStatus 500).detail
        Assert-Equal "no body" "System.Net.WebException Timeout" (Get-AgentErrorCategory -Failure (New-Failure -Type $webException -WebStatus "Timeout")).detail
        Assert-Equal "type only" "System.IO.IOException" (Get-AgentErrorCategory -Failure (New-Failure -Type "System.IO.IOException")).detail
        Assert-Equal "webStatus only" "ConnectFailure" (Get-AgentErrorCategory -Failure ([pscustomobject]@{ webStatus = "ConnectFailure" })).detail
        Assert-Equal "nothing known" "unknown" (Get-AgentErrorCategory).detail
        Assert-Equal "category by name has an empty detail" "" (Get-AgentErrorCategory -Category "empty_response").detail
    }

    Test-Case "FR-211 detail is cut at 500 characters (499, 500 unchanged; 501 and 5000 cut to the first 500)" {
        $webException = "System.Net.WebException"
        foreach ($length in 1, 499, 500) {
            $text = "e" * $length
            $detail = (Get-AgentErrorCategory -Failure (New-Failure -Type $webException -WebStatus "ProtocolError" -Body ('{"error":"' + $text + '"}')) -HttpStatus 500).detail
            Assert-Equal "length $length" $length $detail.Length
        }
        $long = ("0123456789" * 50) + "XYZ"
        $detail = (Get-AgentErrorCategory -Failure (New-Failure -Type $webException -WebStatus "ProtocolError" -Body ('{"error":"' + $long + '"}')) -HttpStatus 500).detail
        Assert-Equal "length of 503 cut" 500 $detail.Length
        Assert-Equal "the first 500 are kept" ("0123456789" * 50) $detail
        $huge = "h" * 5000
        Assert-Equal "length of 5000 cut" 500 (Get-AgentErrorCategory -Failure (New-Failure -Type $webException -WebStatus "ProtocolError" -Body ('{"error":"' + $huge + '"}')) -HttpStatus 500).detail.Length
    }

    Test-Case "FR-211 detail never changes the category: the same failure with different bodies gives the same category" {
        $bodies = @($null, "", "timed out", '{"error":"timeout"}', '{"error":"HTTP 500"}', '{"error":"connection refused"}', "<html>502</html>", '{"error":')
        foreach ($body in $bodies) {
            Assert-Equal "500 body '$body'" "http_5xx" (Get-Category -Failure (New-Failure -Type "System.Net.WebException" -WebStatus "ProtocolError" -Body $body) -HttpStatus 500)
            Assert-Equal "ConnectFailure body '$body'" "transport_unreachable" (Get-Category -Failure (New-Failure -Type "System.Net.WebException" -WebStatus "ConnectFailure" -Body $body))
        }
    }

    Test-Case "FR-211 the classifier is pure: it does not change its input and returns equal results for equal input" {
        $failure = New-Failure -Type "System.Net.WebException" -WebStatus "ProtocolError" -Body '{"error":"boom"}' -Message "kept"
        $before = $failure | ConvertTo-Json -Compress
        $first = Get-AgentErrorCategory -Failure $failure -HttpStatus 500
        $second = Get-AgentErrorCategory -Failure $failure -HttpStatus 500
        Assert-Equal "input unchanged" $before ($failure | ConvertTo-Json -Compress)
        Assert-Equal "results equal" ($first | ConvertTo-Json -Compress) ($second | ConvertTo-Json -Compress)
        Assert-Equal "result members" "category,retryable,hint,detail" ((@($first.PSObject.Properties | ForEach-Object { $_.Name })) -join ",")
    }

    # -----------------------------------------------------------------------
    # FR-204 / M-5: the fake transport
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== fake transport (FR-204) ===" -ForegroundColor Cyan

    function Invoke-FakeRequest {
        param($Fake, [string]$Purpose = "generate", $Json = $null)
        $body = $null
        if ($null -ne $Json) { $body = [System.Text.Encoding]::UTF8.GetBytes($Json) }
        return & $Fake.Transport -Request @{ Url = "http://127.0.0.1:9/api/$Purpose"; Method = "Post"; Body = $body; TimeoutSec = 7; Purpose = $Purpose }
    }

    Test-Case "FR-204 the steps are returned in order and every request is recorded (url, method, purpose, timeout, decoded body)" {
        $fake = New-FakeTransport -Steps @(
            (New-FakeFailureRecord -WebStatus "Timeout"),
            (New-FakeOkRecord -Response (New-FakeGenerateResponse -Text "hello"))
        )
        $first = Invoke-FakeRequest $fake "generate" '{"model":"m1","stream":false}'
        $second = Invoke-FakeRequest $fake "generate" '{"model":"m2","stream":false}'
        Assert-Equal "first ok" $false $first.ok
        Assert-Equal "second ok" $true $second.ok
        Assert-Equal "second text" "hello" $second.response.response
        Assert-Equal "calls" 2 $fake.Count()
        Assert-Equal "generate calls" 2 $fake.Count("generate")
        Assert-Equal "tags calls" 0 $fake.Count("tags")
        Assert-Equal "call 1 url" "http://127.0.0.1:9/api/generate" $fake.Calls[0].Url
        Assert-Equal "call 1 method" "Post" $fake.Calls[0].Method
        Assert-Equal "call 1 timeout" 7 $fake.Calls[0].TimeoutSec
        Assert-Equal "call 1 model" "m1" $fake.Calls[0].Body.model
        Assert-Equal "call 2 model" "m2" $fake.Calls[1].Body.model
        Assert-Equal "call 2 raw text" '{"model":"m2","stream":false}' $fake.Calls[1].BodyText
        Assert-Equal "steps used" "0,1" (($fake.Calls | ForEach-Object { $_.Step }) -join ",")
    }

    Test-Case "FR-204 a request without a body (tags) is recorded with a null body" {
        $fake = New-FakeTransport -Steps @((New-FakeOkRecord -Response (New-FakeTagsResponse -Models @("a:1b", "b:2b"))))
        $result = Invoke-FakeRequest $fake "tags"
        Assert-Equal "models" "a:1b,b:2b" (($result.response.models | ForEach-Object { $_.name }) -join ",")
        Assert-True "body text null" ($null -eq $fake.Calls[0].BodyText)
        Assert-True "body null" ($null -eq $fake.Calls[0].Body)
        Assert-Equal "tags calls" 1 $fake.Count("tags")
    }

    Test-Case "FR-204 an exception step is thrown, a script block step receives the request, and a running-out transport throws and is recorded as unexpected" {
        $fake = New-FakeTransport -Steps @(
            [System.TimeoutException]::new("sentinel"),
            { param($Request) New-FakeOkRecord -Response ([pscustomobject]@{ seen = $Request.Purpose }) }
        )
        $thrown = $null
        try { Invoke-FakeRequest $fake "generate" '{}' | Out-Null } catch { $thrown = $_.Exception }
        Assert-True "something thrown" ($null -ne $thrown)
        Assert-Equal "thrown type" "System.TimeoutException" $thrown.GetType().FullName
        $second = Invoke-FakeRequest $fake "warmup" '{}'
        Assert-Equal "script block saw the purpose" "warmup" $second.response.seen
        Assert-Throws "no step left" { Invoke-FakeRequest $fake "generate" '{}' }
        Assert-Equal "recorded calls" 3 $fake.Count()
        Assert-Equal "steps used" "0,1,-1" (($fake.Calls | ForEach-Object { $_.Step }) -join ",")
    }

    Test-Case "FR-204 -RepeatLast repeats the last step; without it the steps run out" {
        $repeating = New-FakeTransport -Steps @((New-FakeFailureRecord -HttpStatus 500)) -RepeatLast
        foreach ($i in 1..4) { Assert-Equal "repeat $i" $false (Invoke-FakeRequest $repeating "generate" '{}').ok }
        Assert-Equal "calls" 4 $repeating.Count()
        Assert-Equal "steps used" "0,0,0,0" (($repeating.Calls | ForEach-Object { $_.Step }) -join ",")
        $single = New-FakeTransport -Steps @((New-FakeFailureRecord -HttpStatus 500))
        Invoke-FakeRequest $single "generate" '{}' | Out-Null
        Assert-Throws "second request of a single step" { Invoke-FakeRequest $single "generate" '{}' }
        $none = New-FakeTransport -RepeatLast
        Assert-Throws "no steps at all" { Invoke-FakeRequest $none "generate" '{}' }
    }

    Test-Case "FR-204 two fakes keep separate state" {
        $a = New-FakeTransport -Steps @((New-FakeOkRecord -Response "a"))
        $b = New-FakeTransport -Steps @((New-FakeOkRecord -Response "b"))
        Assert-Equal "a" "a" (Invoke-FakeRequest $a "generate" '{}').response
        Assert-Equal "b" "b" (Invoke-FakeRequest $b "generate" '{}').response
        Assert-Equal "a calls" 1 $a.Count()
        Assert-Equal "b calls" 1 $b.Count()
    }

    Test-Case "FR-204 the record shapes: ok has response and httpStatus, a failure has exceptionType, webStatus, body and a display-only message" {
        $ok = New-FakeOkRecord -Response "r"
        Assert-Equal "ok members" "ok,response,httpStatus,failure" ((@($ok.PSObject.Properties | ForEach-Object { $_.Name })) -join ",")
        Assert-Equal "ok flag" $true $ok.ok
        Assert-Equal "ok status" 200 $ok.httpStatus
        Assert-True "ok has no failure" ($null -eq $ok.failure)
        $fail = New-FakeFailureRecord -ExceptionType "System.IO.IOException" -WebStatus "ConnectionClosed" -HttpStatus 502 -Body "b"
        Assert-Equal "fail flag" $false $fail.ok
        Assert-Equal "fail status" 502 $fail.httpStatus
        Assert-True "fail has no response" ($null -eq $fail.response)
        Assert-Equal "failure members" "exceptionType,webStatus,body,message" ((@($fail.failure.PSObject.Properties | ForEach-Object { $_.Name })) -join ",")
        # a record from the fake feeds the classifier directly
        $result = Get-AgentErrorCategory -Failure $fail.failure -HttpStatus $fail.httpStatus
        Assert-Equal "classified" "http_5xx" $result.category
        $generate = New-FakeGenerateResponse -Text "t" -Thinking "abc" -DoneReason "length" -PromptEvalCount 11 -EvalCount 6
        Assert-Equal "generate text" "t" $generate.response
        Assert-Equal "generate thinking" "abc" $generate.thinking
        Assert-Equal "generate done_reason" "length" $generate.done_reason
        Assert-Equal "generate prompt_eval_count" 11 $generate.prompt_eval_count
        Assert-Equal "generate eval_count" 6 $generate.eval_count
        Assert-True "no thinking member by default" ($null -eq (New-FakeGenerateResponse).PSObject.Properties["thinking"])
    }

    # -----------------------------------------------------------------------
    # NFR-202 / NFR-203 / NFR-204 static scans and guards
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== static scans and guards ===" -ForegroundColor Cyan

    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($engineLibrary, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "agent-exec.ps1 has parse errors" }
    $functionAsts = @{}
    foreach ($function in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $functionAsts[$function.Name] = $function
    }

    Test-Case "AC-207 static: no .Message is read in Get-AgentErrorCategory, Invoke-OllamaHttp or Invoke-AgentModel (those that exist; message text is never a decision input)" {
        Assert-True "Get-AgentErrorCategory is defined" ($functionAsts.ContainsKey("Get-AgentErrorCategory"))
        $scanned = 0
        foreach ($name in @("Get-AgentErrorCategory", "Invoke-OllamaHttp", "Invoke-AgentModel")) {
            if (-not $functionAsts.ContainsKey($name)) { continue }
            $scanned++
            $reads = @($functionAsts[$name].FindAll({ param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and [string]$n.Member.Extent.Text -ceq "Message" }, $true))
            Assert-Equal "$name .Message reads" 0 $reads.Count
            $strings = @($functionAsts[$name].FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -ceq "Message" }, $true))
            Assert-Equal "$name 'Message' property lookups" 0 $strings.Count
        }
        Assert-True "at least the classifier was scanned" ($scanned -ge 1)
    }

    Test-Case "NFR-202 static: Get-AgentErrorCategory never matches on text (no -match, -like, -contains of the body or message, no .Contains/.IndexOf on them)" {
        $function = $functionAsts["Get-AgentErrorCategory"]
        $operators = @($function.FindAll({ param($n) $n -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true))
        foreach ($operator in $operators) {
            $kind = [string]$operator.Operator
            if (@("Imatch", "Cmatch", "Ilike", "Clike", "Inotmatch", "Cnotmatch", "Inotlike", "Cnotlike") -contains $kind) { throw "text operator $kind in: $($operator.Extent.Text)" }
        }
        $calls = @($function.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))
        foreach ($call in $calls) {
            $member = [string]$call.Member.Extent.Text
            if (@("Contains", "IndexOf", "StartsWith", "EndsWith", "Match", "IsMatch") -contains $member -and $call.Expression.Extent.Text -notmatch 'hints') {
                throw "text search $member on $($call.Expression.Extent.Text)"
            }
        }
        $text = $function.Extent.Text
        Assert-True "reads exceptionType" ($text.Contains("exceptionType"))
        Assert-True "reads webStatus" ($text.Contains("webStatus"))
    }

    Test-Case "NFR-203 static: Get-AgentErrorCategory calls no sleep, network, file, process or output command and reads no state" {
        $forbidden = @("Start-Sleep", "sleep", "Invoke-RestMethod", "Invoke-WebRequest", "Invoke-Expression", "iex", "Start-Process", "Stop-Process",
            "Get-Content", "Set-Content", "Add-Content", "Out-File", "Write-Host", "Write-Output", "Write-Warning", "Write-Error", "Get-Date", "New-Item")
        $function = $functionAsts["Get-AgentErrorCategory"]
        foreach ($command in $function.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $commandName = [string]$command.GetCommandName()
            if ($forbidden -contains $commandName) { throw "Get-AgentErrorCategory calls $commandName" }
        }
        foreach ($literal in @("[datetime]", "[System.Threading", "Env:", "`$env:", "`$script:", "`$global:")) {
            if ($function.Extent.Text.IndexOf($literal, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "Get-AgentErrorCategory uses $literal" }
        }
    }

    Test-Case "NFR-203 static: agent-exec.ps1 holds no HTTP route except one Invoke-RestMethod inside Invoke-OllamaHttp" {
        $text = [System.IO.File]::ReadAllText($engineLibrary)
        foreach ($literal in @("Microsoft.PowerShell.Utility\Invoke-RestMethod", "Invoke-WebRequest", "System.Net.WebClient", "Net.WebClient", "HttpWebRequest",
                "HttpClient", "System.Net.WebRequest", "TcpClient", "Start-BitsTransfer")) {
            Assert-True "no $literal" ($text.IndexOf($literal, [System.StringComparison]::OrdinalIgnoreCase) -lt 0)
        }
        $aliases = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                Where-Object { @("irm", "iwr", "curl", "wget") -contains [string]$_.GetCommandName() })
        Assert-Equal "alias commands" 0 $aliases.Count
        $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -ieq "Invoke-RestMethod" }, $true))
        Assert-True "at most one Invoke-RestMethod call" ($calls.Count -le 1)
        foreach ($call in $calls) {
            $inside = $false
            $parent = $call.Parent
            while ($null -ne $parent) {
                if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $parent.Name -ceq "Invoke-OllamaHttp") { $inside = $true }
                $parent = $parent.Parent
            }
            Assert-True "the Invoke-RestMethod call is inside Invoke-OllamaHttp" $inside
        }
    }

    Test-Case "NFR-204 static: the new files use no -AsHashtable, no ternary or null-coalescing operator" {
        foreach ($path in @($engineLibrary, $mockWebResponse, $mockTransport, $PSCommandPath)) {
            $text = [System.IO.File]::ReadAllText($path)
            $sourceAst = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
            Assert-Equal "$([System.IO.Path]::GetFileName($path)) parse errors" 0 $errors.Count
            foreach ($command in $sourceAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                if ([string]$command.GetCommandName() -ieq "ConvertFrom-Json") {
                    foreach ($element in $command.CommandElements) {
                        if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -ieq "AsHashtable") { throw "-AsHashtable in $path" }
                    }
                }
            }
            foreach ($token in $tokens) {
                if ($token.Kind -eq [System.Management.Automation.Language.TokenKind]::QuestionMark -or
                    $token.Kind -eq [System.Management.Automation.Language.TokenKind]::QuestionQuestion) { throw "ternary or null-coalescing token in $path" }
            }
        }
    }

    Test-Case "NFR-203 guard: the default transport was never called by this suite" {
        Assert-Equal "violations" 0 $script:transportViolations
    }
}
finally {
    Remove-Item Function:\Invoke-OllamaHttp -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "              TEST SUMMARY" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host "Passed: $script:passed"
Write-Host "Failed: $script:failed"

if ($script:failed -eq 0 -and $script:passed -gt 0) {
    Write-Host "STATUS: PASS" -ForegroundColor Green
    exit 0
}

Write-Host "STATUS: FAIL" -ForegroundColor Red
exit 1
