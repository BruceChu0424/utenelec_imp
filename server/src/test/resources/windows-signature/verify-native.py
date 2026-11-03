"""Independent osslsigncode crypto regression. Test keys stay in a temporary directory.

Run only with a current, controlled osslsigncode build. It never imports a trust root,
executes a signed fixture, or creates a client distribution package.
"""
import argparse
import base64
import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile
import struct
import zipfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--osslsigncode", required=True)
    parser.add_argument("--vectors", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    output = pathlib.Path(args.output_dir).resolve()
    output.mkdir(parents=True, exist_ok=True)
    outcomes = []
    with tempfile.TemporaryDirectory(prefix="uten-signature-crypto-") as temporary:
        root = pathlib.Path(temporary)

        def run(command, expected=0, name=None):
            result = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=30, check=False)
            if len(result.stdout.encode()) > 65536:
                raise AssertionError("native verifier output exceeded bound")
            if name:
                outcomes.append({"name": name, "exitCode": result.returncode,
                                 "expectedSuccess": expected == 0})
                (output / (name + ".log")).write_text(result.stdout)
            if (result.returncode == 0) != (expected == 0):
                raise AssertionError(f"{name or command[0]}: unexpected exit {result.returncode}: {result.stdout}")
            return result.stdout

        config = """[ca]
default_ca = authority
[authority]
database = index.txt
new_certs_dir = issued
certificate = root.pem
private_key = root.key
serial = serial
crlnumber = crlnumber
default_days = 2
default_crl_days = 1
default_md = sha256
policy = common_name
[common_name]
commonName = supplied
[code_signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
[timestamping]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,timeStamping
"""
        (root / "ca.cnf").write_text(config)
        (root / "issued").mkdir()
        (root / "index.txt").write_text("")
        (root / "serial").write_text("1000\n")
        (root / "crlnumber").write_text("1000\n")
        run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
             "-keyout", "root.key", "-out", "root.pem", "-days", "2", "-subj", "/CN=UTEN TEST ONLY CA",
             "-addext", "basicConstraints=critical,CA:true", "-addext", "keyUsage=critical,keyCertSign,cRLSign"])
        for name, extension in (("signer", "code_signing"), ("tsa", "timestamping")):
            run(["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout", name + ".key",
                 "-out", name + ".csr", "-subj", "/CN=UTEN TEST ONLY " + name])
            run(["openssl", "ca", "-batch", "-notext", "-config", "ca.cnf", "-extensions", extension,
                 "-in", name + ".csr", "-out", name + ".pem"])
            (root / (name + "-chain.pem")).write_bytes((root / (name + ".pem")).read_bytes() + (root / "root.pem").read_bytes())
        run(["openssl", "ca", "-gencrl", "-config", "ca.cnf", "-out", "valid.crl.pem"])
        vectors = json.loads(pathlib.Path(args.vectors).read_text())
        vector = next(item for item in vectors["vectors"] if item["name"] == "x64-unsigned")
        (root / "unsigned.exe").write_bytes(base64.b64decode(vector["peBase64"]))
        certificate = subprocess.check_output(["openssl", "x509", "-in", str(root / "signer.pem"), "-outform", "DER"])
        pin = hashlib.sha256(certificate).hexdigest()
        signer = [args.osslsigncode, "sign", "-certs", "signer-chain.pem", "-key", "signer.key", "-h", "sha256"]
        run(signer + ["-TSA-certs", "tsa-chain.pem", "-TSA-key", "tsa.key", "-in", "unsigned.exe", "-out", "signed.exe"])
        verification = [args.osslsigncode, "verify", "-index", "0", "-CAfile", "root.pem",
                        "-TSA-CAfile", "root.pem", "-CRLfile", "valid.crl.pem", "-TSA-CRLfile", "valid.crl.pem", "-ignore-cdp"]
        pinned = verification + ["-require-leaf-hash", "sha256:" + pin]
        result = run(pinned + ["-in", "signed.exe"], name="valid-embedded-with-trusted-timestamp")
        assert "Timestamp Server Signature verification: ok" in result
        run(pinned + ["-in", "unsigned.exe"], expected=1, name="unsigned-rejected")
        run(verification + ["-require-leaf-hash", "sha256:" + "00" * 32, "-in", "signed.exe"], expected=1, name="wrong-publisher-rejected")
        modified = bytearray((root / "signed.exe").read_bytes())
        modified[0x280] ^= 1
        (root / "tampered.exe").write_bytes(modified)
        run(pinned + ["-in", "tampered.exe"], expected=1, name="mapped-byte-tampering-rejected")
        run(signer + ["-in", "unsigned.exe", "-out", "without-timestamp.exe"])
        result = run(pinned + ["-in", "without-timestamp.exe"], name="native-valid-but-application-rejects-missing-timestamp")
        assert "Timestamp is not available" in result
        (root / "fixture.ps1").write_text("# TEST ONLY. Never executed.\nWrite-Output 'signature fixture'\n", encoding="utf-8-sig")
        run(signer + ["-TSA-certs", "tsa-chain.pem", "-TSA-key", "tsa.key", "-in", "fixture.ps1", "-out", "signed.ps1"])
        run(pinned + ["-in", "signed.ps1"], name="powershell-embedded-signature-verified")
        # A real company-style signature must authenticate the whole non-PE runtime too.
        configuration = b'{"endpoints":["https://company.example/api"]}'
        inventory = {"schemaVersion": 1, "runtimeFamily": "wpf_legacy", "version": "2.5.45", "buildNumber": 2545,
                     "architecture": "x64", "executable": "Uten.Legacy.Desktop.exe",
                     "files": [{"path": "uten.client.json", "size": len(configuration), "sha256": hashlib.sha256(configuration).hexdigest()}]}
        raw = json.dumps(inventory, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
        base = (root / "unsigned.exe").read_bytes()
        footer = struct.pack("<I", len(raw)) + b"UTEN-PAYLOAD-BINDING-V1\0"
        (root / "bound.exe").write_bytes(base + b"\0" * (-(len(base) + len(raw) + len(footer)) % 8) + raw + footer)
        run(signer + ["-TSA-certs", "tsa-chain.pem", "-TSA-key", "tsa.key", "-in", "bound.exe", "-out", "signed-bound.exe"])
        run(pinned + ["-in", "signed-bound.exe"], name="whole-runtime-binding-is-covered-by-real-signature")
        for changed in (False, True):
            archive = output / ("test-only-replaced-runtime.zip" if changed else "test-only-bound-runtime.zip")
            with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as package:
                package.writestr("Uten.Legacy.Desktop.exe", (root / "signed-bound.exe").read_bytes())
                package.writestr("uten.client.json", b'{"endpoints":["https://changed.example/api"]}' if changed else configuration)
        run(["openssl", "ca", "-config", "ca.cnf", "-revoke", "signer.pem"])
        run(["openssl", "ca", "-gencrl", "-config", "ca.cnf", "-out", "revoked.crl.pem"])
        revoked = ["revoked.crl.pem" if item == "valid.crl.pem" else item for item in pinned]
        run(revoked + ["-in", "signed.exe"], expected=1, name="revoked-publisher-rejected")
        run(["openssl", "ca", "-gencrl", "-config", "ca.cnf", "-crl_lastupdate", "20200101000000Z",
             "-crl_nextupdate", "20200102000000Z", "-out", "expired.crl.pem"])
        expired = ["expired.crl.pem" if item == "valid.crl.pem" else item for item in pinned]
        run(expired + ["-in", "signed.exe"], expected=1, name="expired-revocation-list-rejected")
        # Only public material and inert signed fixtures are retained; no private keys survive.
        for source, target in (("signed.exe", "test-only-crypto-fixture.exe"), ("signed.ps1", "test-only-crypto-fixture.ps1"),
                               ("unsigned.exe", "test-only-unsigned.exe"), ("tampered.exe", "test-only-tampered.exe"),
                               ("without-timestamp.exe", "test-only-no-timestamp.exe"),
                               ("root.pem", "test-only-root.pem"), ("valid.crl.pem", "test-only-valid.crl.pem"),
                               ("revoked.crl.pem", "test-only-revoked.crl.pem"), ("expired.crl.pem", "test-only-expired.crl.pem")):
            shutil.copyfile(root / source, output / target)
        (output / "test-only-publisher-sha256.txt").write_text(pin + "\n")
    (output / "results.json").write_text(json.dumps({"outcomes": outcomes, "systemTrustModified": False,
                                                    "privateKeysRetained": False}, indent=2))
    print(json.dumps({"checks": len(outcomes), "allExpectedOutcomes": True}))


if __name__ == "__main__":
    main()
