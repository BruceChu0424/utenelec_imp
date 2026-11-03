"""Windows release signing and independent Authenticode trust gate.

No security settings or certificate stores are changed. Signing is optional
until explicitly required/configured; signing keys remain in the Windows key store.
Both producers and validators call this module on the actual finished bytes.
"""
from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

PIN_ENV = "UTEN_WINDOWS_PUBLISHER_SHA256"
KEY_ENV = "UTEN_WINDOWS_SIGNING_THUMBPRINT"
TIMESTAMP_ENV = "UTEN_WINDOWS_TIMESTAMP_URL"
TOOL_ENV = "UTEN_WINDOWS_SIGNTOOL_PATH"
REQUIRE_ENV = "UTEN_WINDOWS_SIGNATURE_REQUIRE"
MAX_SIGNABLE_FILES = 128
VERIFY_SECONDS = 120
SIGN_SECONDS = 600
COMPANY_NAMES = {"uten_imp.exe", "flutter_windows.dll", "client_updater.ps1",
                 "uten.legacy.desktop.exe", "uten.legacy.core.dll", "uten.legacy.updater.exe"}
VENDOR_NAMES = {"bouncycastle.cryptography.dll", "ucrtbase.dll"}


def signature_required() -> bool:
    value = os.environ.get(REQUIRE_ENV, "false").strip().lower()
    if value not in {"", "0", "false", "no", "1", "true", "yes"}:
        raise ValueError(f"{REQUIRE_ENV} must be a boolean")
    return value in {"1", "true", "yes"}


def signing_enabled() -> bool:
    # A tool path alone is not a configured publisher. Partial publisher/key/TSA
    # configuration is intentional signing setup and must fail rather than downgrade.
    return signature_required() or any(os.environ.get(key, "").strip()
                                       for key in (PIN_ENV, KEY_ENV, TIMESTAMP_ENV))


def _optional_evidence(files: list[tuple[str, Path]] | None = None, *, deadline: float | None = None) -> dict:
    if files is not None and not 1 <= len(files) <= MAX_SIGNABLE_FILES:
        raise ValueError("Windows signature evidence requires 1..128 files")
    deadline = deadline if deadline is not None else time.monotonic() + VERIFY_SECONDS
    return {"policy": "authenticode-optional-v1", "required": False,
            "verified": False, "verificationSkipped": True,
            "status": "not-verified-not-required", "reason": "publisher-not-configured",
            "files": [{"path": relative, "sha256": _digest(path, deadline=deadline)} for relative, path in files or ()]}


def publisher_pins() -> set[str]:
    value = os.environ.get(PIN_ENV, "")
    pins = {part.strip().lower() for part in value.split(",") if part.strip()}
    if not 1 <= len(pins) <= 4 or any(not re.fullmatch(r"[0-9a-f]{64}", pin) for pin in pins):
        raise ValueError(f"Trusted Windows company publisher is not configured: set {PIN_ENV} to 1..4 reviewed leaf-certificate SHA-256 pins; system protection must remain enabled")
    return pins


def timestamp_url() -> str:
    value = os.environ.get(TIMESTAMP_ENV, "")
    try:
        parsed = urlsplit(value)
        if (parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password
                or parsed.query or parsed.fragment or any(ord(character) < 32 for character in value)):
            raise ValueError()
        parsed.port
    except ValueError as error:
        # The original URL may contain a token; never echo it in a diagnostic.
        raise ValueError(f"{TIMESTAMP_ENV} must be a public HTTP(S) timestamp URL without credentials, query or fragment") from error
    return value


def _digest(path: Path, *, deadline: float | None = None) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(65536), b""):
            _remaining(deadline)
            digest.update(chunk)
    return digest.hexdigest()


def signing_tool() -> Path:
    configured = os.environ.get(TOOL_ENV)
    if configured:
        path = Path(configured)
        if not path.is_absolute():
            raise ValueError(f"{TOOL_ENV} must name an audited absolute SignTool.exe path")
        candidates = [path]
    else:
        kits = Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "Windows Kits/10/bin"
        candidates = sorted(kits.glob("*/x64/signtool.exe"), reverse=True) if kits.is_dir() else []
    for path in candidates:
        if path.name.casefold() == "signtool.exe" and path.is_file() and not path.is_symlink():
            return path.resolve(strict=True)
    raise ValueError(f"Approved Windows SDK SignTool.exe is unavailable; set {TOOL_ENV}; formal release is blocked")


def python_executable() -> str:
    # Some embedded Python hosts report their runtime *directory* as
    # sys.executable. Inno must launch an actual interpreter executable.
    candidates = [sys.executable, shutil.which("python.exe"), shutil.which("python")]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return str(Path(candidate).resolve(strict=True))
    raise ValueError("An existing Python interpreter executable is required for the Inno signing callback")


def inno_signing_argument() -> str:
    # Inno's /S parser uses $q, rather than nested literal command-line quotes.
    # Escape literal dollars in filesystem paths before Inno substitution.
    interpreter = python_executable().replace("$", "$$")
    script = str(Path(__file__).resolve()).replace("$", "$$")
    return f'/Suten=$q{interpreter}$q $q{script}$q --sign-file $f'


def _remaining(deadline: float | None, maximum: int = 30) -> float:
    remaining = maximum if deadline is None else min(maximum, deadline - time.monotonic())
    if remaining <= 0:
        raise ValueError("Windows signing/verification exceeded its whole-package deadline")
    return remaining


def _signtool(arguments: list[str], *, deadline: float | None = None) -> None:
    try:
        result = subprocess.run([str(signing_tool()), *arguments], capture_output=True, text=True,
                                encoding="utf-8", errors="replace", timeout=_remaining(deadline), check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ValueError("Windows Authenticode operation timed out or is unavailable; formal release is blocked") from error
    # SignTool uses 2 for warnings. A warning (including missing timestamp) is
    # never promoted to a successful release receipt.
    if result.returncode != 0:
        raise ValueError("Windows Authenticode policy/signature/timestamp verification failed: "
                         + (result.stdout + result.stderr).strip()[-900:])


def _wintrust(path: Path) -> int:
    """Authenticode policy, online chain revocation, no interactive UI."""
    if os.name != "nt":
        raise ValueError("Windows Authenticode verification requires Windows; no unsigned fallback is permitted")

    class FileInfo(ctypes.Structure):
        _fields_ = [("size", wintypes.DWORD), ("path", wintypes.LPCWSTR),
                    ("file", wintypes.HANDLE), ("subject", ctypes.c_void_p)]

    class TrustData(ctypes.Structure):
        _fields_ = [("size", wintypes.DWORD), ("callback", ctypes.c_void_p),
                    ("sip", ctypes.c_void_p), ("ui", wintypes.DWORD),
                    ("revocation", wintypes.DWORD), ("choice", wintypes.DWORD),
                    ("file", ctypes.c_void_p), ("stateAction", wintypes.DWORD),
                    ("state", wintypes.HANDLE), ("url", wintypes.LPCWSTR),
                    ("flags", wintypes.DWORD), ("context", wintypes.DWORD),
                    ("settings", ctypes.c_void_p)]

    import uuid
    action = (ctypes.c_ubyte * 16).from_buffer_copy(uuid.UUID("00aac56b-cd44-11d0-8cc2-00c04fc295ee").bytes_le)
    info = FileInfo(ctypes.sizeof(FileInfo), str(path), None, None)
    data = TrustData(ctypes.sizeof(TrustData), None, None, 2, 1, 1,
                     ctypes.cast(ctypes.pointer(info), ctypes.c_void_p), 1,
                     None, None, 0x80 | 0x2000, 0, None)
    function = ctypes.WinDLL("wintrust", use_last_error=True).WinVerifyTrust
    function.argtypes = [wintypes.HWND, ctypes.c_void_p, ctypes.c_void_p]
    function.restype = wintypes.LONG
    try:
        return function(None, ctypes.byref(action), ctypes.byref(data)) & 0xffffffff
    finally:
        data.stateAction = 2
        function(None, ctypes.byref(action), ctypes.byref(data))


_POWERSHELL = r"""$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$request = [Console]::In.ReadToEnd() | ConvertFrom-Json
function HasCodeSigning($certificate) {
  return ('1.3.6.1.5.5.7.3.3' -in @($certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' } | ForEach-Object { $_.EnhancedKeyUsages } | ForEach-Object { $_.Value }))
}
function CertificateHash($certificate) {
  $algorithm = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($algorithm.ComputeHash($certificate.RawData))).Replace('-','').ToLowerInvariant() } finally { $algorithm.Dispose() }
}
if ($request.ready) {
  $thumbprint = $env:UTEN_WINDOWS_SIGNING_THUMBPRINT
  if ($thumbprint -notmatch '^[0-9a-fA-F]{40}$') { throw 'Company signing key is not configured in the Windows certificate store' }
  $certificates = @(Get-ChildItem Cert:\CurrentUser\My,Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $thumbprint -and $_.HasPrivateKey })
  if ($certificates.Count -ne 1) { throw 'Expected exactly one accessible company signing certificate with its private key' }
  $certificate = $certificates[0]
  if ($certificate.NotBefore -gt (Get-Date) -or $certificate.NotAfter -lt (Get-Date)) { throw 'Company signing certificate is outside its validity period' }
  if (-not (HasCodeSigning $certificate)) { throw 'Certificate does not authorize code signing' }
  if ((CertificateHash $certificate) -notin @($request.pins)) { throw 'Selected signing certificate does not match the approved company publisher pins' }
  $timestamp = $env:UTEN_WINDOWS_TIMESTAMP_URL
  if ([string]::IsNullOrWhiteSpace($timestamp)) { throw 'An approved timestamp service URL is required' }
  $uri = [Uri]$timestamp
  if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('http','https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'Timestamp service URL is invalid' }
  $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
  try {
    $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::Online
    $chain.ChainPolicy.ApplicationPolicy.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.3'))
    if (-not $chain.Build($certificate)) { throw 'Selected signing certificate fails code-signing trust chain/revocation validation' }
  } finally { $chain.Dispose() }
  [pscustomobject]@{ready=$true;privateKeyPresent=$true;privateKeyOperationValidated=$false;signerSha256=(CertificateHash $certificate);notAfter=$certificate.NotAfter.ToUniversalTime().ToString('o');timestampService=$timestamp;store=($certificate.PSParentPath -replace '^.*Certificate::','')} | ConvertTo-Json -Compress
  return
}
$result = @($request.files | ForEach-Object {
  $signature = Get-AuthenticodeSignature -LiteralPath $_
  $signer = $signature.SignerCertificate
  $signerHash = $null
  if ($signer) {
    $signerHash = CertificateHash $signer
  }
  [pscustomobject]@{path=$_;status=[string]$signature.Status;signatureType=[string]$signature.SignatureType;
    signerSha256=$signerHash;timestamped=($null -ne $signature.TimeStamperCertificate);
    codeSigning=($signer -and (HasCodeSigning $signer))}
})
ConvertTo-Json -InputObject $result -Compress -Depth 5
"""


def _provider(request: dict, *, deadline: float | None = None):
    if os.name != "nt":
        raise ValueError("Windows Authenticode operation requires Windows")
    executable = Path(os.environ.get("SystemRoot", "C:/Windows")) / "System32/WindowsPowerShell/v1.0/powershell.exe"
    try:
        # Do not inherit PowerShell 7/user module search paths into Windows
        # PowerShell 5.1 or autoload a user-supplied security module.
        environment = {**os.environ, "PSModulePath": str(executable.parent / "Modules")}
        result = subprocess.run([str(executable), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", _POWERSHELL],
            input=json.dumps(request),
            capture_output=True, text=True, encoding="utf-8", errors="strict", check=False, timeout=_remaining(deadline), env=environment)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ValueError("Windows signing/trust provider is unavailable; formal release is blocked") from error
    if result.returncode:
        raise ValueError("Windows signing/trust provider rejected the operation: " + result.stderr.strip()[:700])
    try:
        records = json.loads(result.stdout.lstrip("\ufeff"))
    except (TypeError, ValueError) as error:
        raise ValueError("Windows signing provider returned invalid verification evidence") from error
    return records


def _metadata(paths: list[Path], *, deadline: float | None = None) -> list[dict]:
    request = {"files": [str(path) for path in paths]}
    records = _provider(request, deadline=deadline)
    if not isinstance(records, list) or len(records) != len(paths):
        raise ValueError("Windows signing provider omitted verification evidence")
    return records


def check_configuration(*, deadline: float | None = None) -> dict:
    """Read-only key-presence/identity/chain check, before an AOT build.

    HasPrivateKey is not proof that hardware-token/PIN/ACL signing will succeed;
    only a subsequent real signature operation establishes key usability.
    """
    if not signing_enabled():
        return {**_optional_evidence(), "ready": False, "signingEnabled": False,
                "privateKeyPresent": False, "privateKeyOperationValidated": False}
    tool = signing_tool()
    timestamp_url()
    result = _provider({"ready": True, "pins": sorted(publisher_pins())}, deadline=deadline)
    if not isinstance(result, dict) or result.get("ready") is not True:
        raise ValueError("Windows code-signing configuration is not ready")
    return {**result, "signingEnabled": True, "required": signature_required(),
            "signTool": str(tool), "timestampDigest": "SHA256", "fileDigest": "SHA256"}


def verify_files(files: list[tuple[str, Path]], *, company_files: set[str] | None = None, deadline: float | None = None) -> dict:
    deadline = deadline if deadline is not None else time.monotonic() + VERIFY_SECONDS
    if not signing_enabled():
        return _optional_evidence(files, deadline=deadline)
    pins = publisher_pins()
    if not 1 <= len(files) <= MAX_SIGNABLE_FILES:
        raise ValueError("Windows signature verification requires 1..128 executable/script files")
    paths = [path.resolve(strict=True) for _, path in files]
    before = [_digest(path, deadline=deadline) for path in paths]
    records = _metadata(paths, deadline=deadline)
    # SignTool processes the bounded file list in one process. No catalog is
    # allowed to masquerade as an embedded publisher signature below.
    _signtool(["verify", "/pa", "/all", "/tw", "/q", *(str(path) for path in paths)], deadline=deadline)
    evidence = []
    for index, ((relative, _), path, record) in enumerate(zip(files, paths, records)):
        company = relative.casefold() in {name.casefold() for name in company_files} if company_files is not None else Path(relative).name.casefold() in COMPANY_NAMES
        if record.get("path") != str(path) or record.get("status") != "Valid" or record.get("signatureType") != "Authenticode" or record.get("codeSigning") is not True:
            raise ValueError(f"Authenticode signature is missing or untrusted: {relative}")
        # /pa selects Authenticode policy; /all checks every nested signature;
        # /tw rejects missing timestamps via its nonzero warning exit status.
        # The child process bounds network chain/revocation retrieval time.
        if company and (record.get("signerSha256") not in pins or record.get("timestamped") is not True):
            raise ValueError(f"Company publisher pin or trusted timestamp is missing: {relative}")
        if _digest(path, deadline=deadline) != before[index]:
            raise ValueError(f"Windows file changed during signature verification: {relative}")
        evidence.append({"path": relative, "sha256": before[index], "signerSha256": record["signerSha256"],
                         "companyPublisher": company, "timestamped": record["timestamped"]})
    _remaining(deadline)
    return {"policy": "authenticode-company-pinned-v1", "required": signature_required(),
            "verified": True, "files": evidence}


def is_signable(path: Path) -> bool:
    if path.suffix.casefold() in {".exe", ".dll", ".ps1"}:
        return True
    with path.open("rb") as stream:
        return stream.read(2) == b"MZ"


def runtime_files(root: Path) -> list[tuple[str, Path]]:
    result = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or path.is_junction():
            raise ValueError("Signature input cannot contain filesystem links")
        if path.is_file() and is_signable(path):
            result.append((path.relative_to(root).as_posix(), path))
            if len(result) > MAX_SIGNABLE_FILES:
                raise ValueError("Windows package exceeds 128 signable files")
    return result


def sign_files(files: list[tuple[str, Path]], *, company_files: set[str] | None = None) -> dict:
    """Sign reviewed *staging* bytes, preserving valid third-party signatures."""
    if not signing_enabled():
        return _optional_evidence(files)
    pins = publisher_pins()
    deadline = time.monotonic() + SIGN_SECONDS
    if not 1 <= len(files) <= MAX_SIGNABLE_FILES:
        raise ValueError("Windows signing requires 1..128 executable/script files")
    records = _metadata([path.resolve(strict=True) for _, path in files], deadline=deadline)
    pending = []
    for (relative, path), record in zip(files, records):
        company = relative.casefold() in {name.casefold() for name in company_files} if company_files is not None else Path(relative).name.casefold() in COMPANY_NAMES
        if (record.get("status") == "Valid" and record.get("signatureType") == "Authenticode"
                and record.get("codeSigning") is True and (not company or record.get("signerSha256") in pins and record.get("timestamped") is True)):
            continue
        # Never convert a broken/revoked/modified existing publisher signature
        # into apparently legitimate company code by signing over its evidence.
        if record.get("status") != "NotSigned":
            raise ValueError(f"Existing Windows publisher signature is invalid or not approved; refusing to replace it: {relative}")
        name = Path(relative).name.casefold()
        if name in VENDOR_NAMES or re.match(r"^(?:msvcp|msvcr|vcruntime|concrt|vcomp|mfc|mfcm)[0-9]", name):
            raise ValueError(f"Vendor runtime must retain its reviewed trusted signature; company re-signing is forbidden: {relative}")
        pending.append(path.resolve(strict=True))
    if pending:
        ready = check_configuration(deadline=deadline)
        selector = ["/sha1", os.environ[KEY_ENV], "/s", "My"]
        if ready["store"].startswith("LocalMachine"):
            selector.append("/sm")
        for path in pending:
            _signtool(["sign", "/fd", "SHA256", "/tr", ready["timestampService"], "/td", "SHA256", *selector, str(path)], deadline=deadline)
    return verify_files(files, company_files=company_files,
                        deadline=min(deadline, time.monotonic() + VERIFY_SECONDS))


def verify_archive(archive, *, deadline: float | None = None) -> dict:
    """Call only after the owning package validator has checked paths/bounds."""
    deadline = deadline if deadline is not None else time.monotonic() + VERIFY_SECONDS
    with tempfile.TemporaryDirectory(prefix="uten-authenticode-") as directory:
        root = Path(directory)
        files = []
        for index, entry in enumerate(archive.infolist()):
            if Path(entry.filename).suffix.casefold() not in {".exe", ".dll", ".ps1"}:
                with archive.open(entry) as probe:
                    if probe.read(2) != b"MZ":
                        continue
            if len(files) >= MAX_SIGNABLE_FILES:
                raise ValueError("Windows package exceeds 128 signable files")
            path = root / (str(index) + Path(entry.filename).suffix)
            with archive.open(entry) as source, path.open("xb") as target:
                received = 0
                for chunk in iter(lambda: source.read(65536), b""):
                    _remaining(deadline)
                    received += len(chunk)
                    if received > entry.file_size:
                        raise ValueError("Signature input expanded beyond its validated archive size")
                    target.write(chunk)
                if received != entry.file_size:
                    raise ValueError("Signature input archive is truncated")
            files.append((entry.filename, path))
        return verify_files(files, deadline=deadline)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--bundle", type=Path)
    group.add_argument("--check-config", action="store_true", help="read-only company key/publisher/chain/timestamp readiness check")
    group.add_argument("--sign-file", type=Path, help="Inno Setup's reviewed Setup/uninstaller signing callback")
    parser.add_argument("--sign-staging", action="store_true", help="sign reviewed staging files; never point at an installed client")
    arguments = parser.parse_args()
    try:
        if arguments.check_config:
            result = check_configuration()
        elif arguments.sign_file:
            path = arguments.sign_file.resolve(strict=True)
            result = sign_files([(path.name, path)], company_files={path.name})
        else:
            files = runtime_files(arguments.bundle.resolve(strict=True))
            result = sign_files(files) if arguments.sign_staging else verify_files(files)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
