# Test double: a System.Net.WebResponse subclass and a WebException built from it
# (Phase 2, WP-2B2; RK-205, A-202, AC-207).
#
# Dot-sourcing this file compiles one small C# type with Add-Type (once per
# process) and defines helper functions. It sends no request, opens no socket and
# writes no file. A response holds a status code and a body read from an
# in-memory stream; a WebException built from it reports Status and
# Response.StatusCode like the exception Invoke-RestMethod throws in Windows
# PowerShell 5.1.
#
# Compiling costs about a second per process and needs the .NET Framework C#
# compiler; a second Add-Type of the same type name fails, so the type is
# guarded.

if (-not ('HarnessFakeWebResponse' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Text;

public class HarnessFakeWebResponse : WebResponse
{
    private readonly HttpStatusCode statusCode;
    private readonly byte[] body;

    public HarnessFakeWebResponse(int status, string text)
    {
        this.statusCode = (HttpStatusCode)status;
        this.body = text == null ? new byte[0] : new UTF8Encoding(false).GetBytes(text);
    }

    public HttpStatusCode StatusCode { get { return this.statusCode; } }

    public override long ContentLength
    {
        get { return this.body.Length; }
        set { }
    }

    public override string ContentType
    {
        get { return "application/json"; }
        set { }
    }

    public override Stream GetResponseStream()
    {
        return new MemoryStream(this.body, false);
    }
}
'@
}

# A WebException the way Invoke-RestMethod reports an HTTP error: Status
# ProtocolError and a Response with StatusCode and a readable body.
function New-FakeHttpWebException {
    param(
        [Parameter(Mandatory = $true)][int]$StatusCode,
        [AllowNull()][AllowEmptyString()][string]$Body = $null,
        [string]$Message = "fake HTTP error"
    )

    $response = New-Object HarnessFakeWebResponse -ArgumentList $StatusCode, $Body
    return New-Object System.Net.WebException -ArgumentList $Message, $null, ([System.Net.WebExceptionStatus]::ProtocolError), $response
}

# A WebException without a response, like a timeout, a refused connection or a
# reset: only Status is set.
function New-FakeStatusWebException {
    param(
        [Parameter(Mandatory = $true)][System.Net.WebExceptionStatus]$Status,
        [string]$Message = "fake transport error"
    )

    return New-Object System.Net.WebException -ArgumentList $Message, $Status
}

# Reads the whole body of the response of a WebException, or $null.
function Read-FakeWebExceptionBody {
    param([Parameter(Mandatory = $true)][System.Net.WebException]$Exception)

    if ($null -eq $Exception.Response) { return $null }
    $stream = $Exception.Response.GetResponseStream()
    $reader = New-Object System.IO.StreamReader -ArgumentList $stream, (New-Object System.Text.UTF8Encoding($false))
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}
