# Run locally from the extracted company trust ZIP. Windows PowerShell 5.1+.
# The SHA-256 pin below was independently verified on the company server.
# It is the SHA-256 of the X.509 DER certificate, not the downloaded PEM file.
# No administrator access, hosts-file changes, or downloaded script execution.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-UtenCertificateSha256 {
    param([Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($Certificate.RawData))).Replace('-', '')
    } finally {
        $sha256.Dispose()
    }
}

function ConvertTo-UtenRootCertificate {
    param([Parameter(Mandatory = $true)][byte[]] $Bytes)
    if ($Bytes.Length -eq 0 -or $Bytes.Length -gt 65536) {
        throw 'The root certificate download is empty or too large.'
    }
    $text = [System.Text.Encoding]::ASCII.GetString($Bytes)
    if ($text.Contains('-----BEGIN')) {
        $match = [regex]::Match($text, '\A\s*-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+)\s*-----END CERTIFICATE-----\s*\z')
        if (-not $match.Success) {
            throw 'Expected exactly one public PEM certificate.'
        }
        $Bytes = [System.Convert]::FromBase64String($match.Groups[1].Value)
    }
    return [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($Bytes)
}

function Assert-UtenRootCertificate {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
        [Parameter(Mandatory = $true)][string] $ExpectedSha256
    )
    $fingerprint = Get-UtenCertificateSha256 -Certificate $Certificate
    if ($ExpectedSha256 -notmatch '\A[0-9A-Fa-f]{64}\z' -or $fingerprint -cne $ExpectedSha256.ToUpperInvariant()) {
        throw 'Certificate SHA-256 does not match the independently verified company root. Nothing was installed.'
    }
    $now = [DateTime]::UtcNow
    if ($Certificate.NotBefore.ToUniversalTime() -gt $now -or $Certificate.NotAfter.ToUniversalTime() -le $now) {
        throw 'The pinned company root is not currently valid. Nothing was installed.'
    }
    $constraints = @($Certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' })
    if ($constraints.Count -ne 1 -or -not ([System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($constraints[0], $constraints[0].Critical)).CertificateAuthority) {
        throw 'The pinned certificate is not a certificate authority. Nothing was installed.'
    }
    if ($Certificate.Subject -ne $Certificate.Issuer -or $Certificate.HasPrivateKey) {
        throw 'Expected a public company root certificate. Nothing was installed.'
    }
}

function Get-UtenPublicRootBytes {
    # The fixed public HTTP bootstrap has no credentials. The independent DER
    # fingerprint is checked BEFORE any trust-store write; redirects are refused.
    $request = [System.Net.HttpWebRequest]::Create('http://192.168.1.13/ca/uten-imp-root-ca.crt')
    $request.AllowAutoRedirect = $false
    $request.Timeout = 15000
    $request.ReadWriteTimeout = 15000
    $response = $null
    $stream = $null
    $memory = [System.IO.MemoryStream]::new()
    try {
        $response = $request.GetResponse()
        if ([int]$response.StatusCode -ne 200) {
            throw 'The root download did not return HTTP 200.'
        }
        $stream = $response.GetResponseStream()
        $buffer = [byte[]]::new(4096)
        while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($memory.Length + $count -gt 65536) {
                throw 'The root certificate download is too large.'
            }
            $memory.Write($buffer, 0, $count)
        }
        return ,$memory.ToArray()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        $memory.Dispose()
    }
}

function Install-UtenUserTrust {
    $expectedSha256 = 'E7945DE9BD75A272E04EF77F9A14538AB42C97A63A71B67FE66C12A123406994'
    $bundledRoot = Join-Path -Path $PSScriptRoot -ChildPath 'uten-imp-root-ca.crt'
    if (Test-Path -LiteralPath $bundledRoot -PathType Leaf) {
        Write-Host '[1/3] Checking the public company root included in this ZIP...'
        if ((Get-Item -LiteralPath $bundledRoot).Length -gt 65536) {
            throw 'The bundled root certificate is too large.'
        }
        $bytes = [System.IO.File]::ReadAllBytes($bundledRoot)
    } else {
        Write-Host '[1/3] Downloading the public company root certificate...'
        $bytes = Get-UtenPublicRootBytes
    }
    $certificate = ConvertTo-UtenRootCertificate -Bytes $bytes
    try {
        Assert-UtenRootCertificate -Certificate $certificate -ExpectedSha256 $expectedSha256
        Write-Host ('Verified company root: ' + $certificate.Subject)
        Write-Host ('SHA-256: ' + $expectedSha256)
        Write-Host '[2/3] Installing trust for the current Windows user...'
        Write-Host 'If Windows asks to confirm this company root, check the fingerprint above.'
        $store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
            [System.Security.Cryptography.X509Certificates.StoreName]::Root,
            [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
        try {
            $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            $present = @($store.Certificates | Where-Object { (Get-UtenCertificateSha256 -Certificate $_) -ceq $expectedSha256 })
            if ($present.Count -eq 0) {
                $store.Add($certificate)
            }
            $installed = @($store.Certificates | Where-Object { (Get-UtenCertificateSha256 -Certificate $_) -ceq $expectedSha256 })
            if ($installed.Count -eq 0) {
                throw 'Windows did not install the company root. Please retry and accept its trust prompt.'
            }
        } finally {
            $store.Close()
        }
        Write-Host '[3/3] Done. Fully close and reopen Edge or Chrome.'
        Write-Host 'ERP address: https://192.168.1.13'
        Write-Host 'Each Windows user runs this once; repeat runs are safe.'
    } finally {
        $certificate.Dispose()
    }
}

# Dot-sourcing loads only the validation helpers for tests; it never downloads
# a certificate or opens a certificate store.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Install-UtenUserTrust
        exit 0
    } catch {
        Write-Host ('[ERROR] ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host 'Keep HTTPS enabled. Contact the company administrator if this continues.'
        exit 1
    }
}
