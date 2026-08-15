import hashlib
import importlib.util
import json
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "website_release.py"
SPEC = importlib.util.spec_from_file_location("website_release", MODULE_PATH)
website_release = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(website_release)


class Arguments:
    pass


@unittest.skipUnless(shutil.which("ssh-keygen"), "OpenSSH is required")
class WebsiteReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uten-website-release-")
        self.root = Path(self.temporary.name)
        self.release = self.root / "release"
        for relative in [
            ".next",
            "prisma-runtime/prisma/migrations/20260812000000_initial_production_baseline",
            "prisma-runtime/node_modules/prisma/build",
        ]:
            (self.release / relative).mkdir(parents=True, exist_ok=True)
        (self.release / "server.js").write_text("console.log('fixture')\n")
        (self.release / "prisma-runtime/node_modules/prisma/build/index.js").write_text("// fixture\n")
        (self.release / "prisma-runtime/prisma/schema.prisma").write_text(
            'datasource db { provider = "sqlite" url = env("DATABASE_URL") }\n'
        )
        (self.release / "prisma-runtime/prisma/migrations/migration_lock.toml").write_text('provider = "sqlite"\n')
        (self.release / "prisma-runtime/prisma/migrations/20260812000000_initial_production_baseline/migration.sql").write_text(
            'CREATE TABLE "Fixture" ("id" TEXT PRIMARY KEY);\n'
        )
        schema_entries = [{
            "name": "Fixture",
            "sql": 'CREATE TABLE "Fixture" ("id" TEXT PRIMARY KEY)',
            "tableName": "Fixture",
            "type": "table",
        }]
        self.database_schema = self.release / "prisma-runtime/prisma/sqlite-schema-contract.json"
        self.database_schema.write_bytes(website_release.canonical_json({
            "entries": schema_entries,
            "format": website_release.DATABASE_SCHEMA_FORMAT,
            "objectCount": 1,
            "sha256": hashlib.sha256(website_release.canonical_json(schema_entries)).hexdigest(),
        }))
        self.publication = self.root / "publication"
        self.publication.mkdir()
        self.version = "1.2.3"
        self.commit = "a" * 40
        self.artifact = self.publication / f"uten-website-{self.version}-{self.commit[:12]}.tar.gz"
        with tarfile.open(self.artifact, "w:gz") as archive:
            for path in sorted(self.release.rglob("*")):
                archive.add(path, arcname=path.relative_to(self.release).as_posix(), recursive=False)
        (self.publication / "website-sbom.cdx.json").write_text(json.dumps({
            "bomFormat": "CycloneDX",
            "specVersion": "1.6",
            "version": 1,
            "components": [{"type": "library", "name": "fixture", "version": "1"}],
        }))
        args = Arguments()
        args.artifact = self.artifact
        args.sbom = self.publication / "website-sbom.cdx.json"
        args.schema = self.release / "prisma-runtime/prisma/schema.prisma"
        args.migrations = self.release / "prisma-runtime/prisma/migrations"
        args.database_schema = self.database_schema
        args.version = self.version
        args.commit = self.commit
        args.source_ref = f"refs/tags/website-v{self.version}"
        args.output = self.publication / "manifest.json"
        website_release.command_manifest(args)

        self.key = self.root / "signing_key"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(self.key)], check=True)
        public = (self.key.with_suffix(".pub")).read_text().strip()
        self.signers = self.root / "allowed_signers"
        self.signers.write_text(f"{website_release.SIGNER_IDENTITY} {public}\n")
        manifest = json.loads((self.publication / "manifest.json").read_text())
        manifest["signingKeyId"] = website_release.allowed_signer_fingerprint(self.signers)
        (self.publication / "manifest.json").write_bytes(website_release.canonical_json(manifest))
        self.sign(self.publication / "manifest.json", self.publication / "manifest.sig")
        digest = hashlib.sha256((self.publication / "manifest.json").read_bytes()).hexdigest()
        channel = {
            "artifactObjectKey": manifest["artifact"]["objectKey"],
            "manifestObjectKey": f"website/releases/{self.version}/manifest.json",
            "manifestSha256": digest,
            "product": website_release.PRODUCT,
            "schemaVersion": website_release.SCHEMA_VERSION,
            "version": self.version,
        }
        (self.publication / "channel.json").write_bytes(website_release.canonical_json(channel))
        self.sign(self.publication / "channel.json", self.publication / "channel.sig")
        artifact_digest = website_release.sha256_file(self.artifact)
        (self.publication / f"{self.artifact.name}.sha256").write_text(
            f"{artifact_digest}  {self.artifact.name}\n"
        )

    def tearDown(self):
        self.temporary.cleanup()

    def sign(self, source: Path, destination: Path):
        subprocess.run([
            "ssh-keygen", "-Y", "sign", "-f", str(self.key),
            "-n", website_release.SIGNATURE_NAMESPACE, str(source),
        ], check=True, stdout=subprocess.DEVNULL)
        source.with_name(source.name + ".sig").replace(destination)

    def test_signed_publication_verifies_and_extracts_without_links(self):
        manifest = website_release.verify_publication(self.publication, self.signers)
        self.assertEqual(manifest["version"], self.version)
        destination = self.root / "extracted"
        website_release.safe_extract(self.artifact, destination)
        self.assertTrue((destination / "server.js").is_file())
        self.assertFalse(any(path.is_symlink() for path in destination.rglob("*")))

    def test_installed_release_is_bound_to_signed_artifact_and_rejects_tampering(self):
        destination = self.root / f"{self.version}-{self.commit[:12]}"
        args = Arguments()
        args.publication = self.publication
        args.allowed_signers = self.signers
        args.expected_version = self.version
        args.destination = destination
        website_release.command_extract(args)
        cache = self.root / "cache"
        cache.mkdir()
        (destination / ".next").mkdir(exist_ok=True)
        (destination / ".next" / "cache").symlink_to(cache, target_is_directory=True)
        manifest = website_release.verify_installed_release(
            destination, self.signers, expected_cache=cache
        )
        self.assertEqual(manifest["version"], self.version)
        wrong_identity = self.root / "wrong-release-name"
        destination.rename(wrong_identity)
        with self.assertRaisesRegex(website_release.ReleaseError, "directory identity"):
            website_release.verify_installed_release(
                wrong_identity, self.signers, expected_cache=cache
            )
        wrong_identity.rename(destination)
        (destination / "server.js").write_text("tampered\n")
        with self.assertRaisesRegex(website_release.ReleaseError, "installed release"):
            website_release.verify_installed_release(
                destination, self.signers, expected_cache=cache
            )

    def test_tampering_is_rejected(self):
        with self.artifact.open("ab") as handle:
            handle.write(b"tamper")
        with self.assertRaisesRegex(website_release.ReleaseError, "artifact bytes"):
            website_release.verify_publication(self.publication, self.signers)

    def test_archive_path_traversal_is_rejected(self):
        malicious = self.root / "malicious.tar.gz"
        payload = self.root / "payload"
        payload.write_text("bad")
        with tarfile.open(malicious, "w:gz") as archive:
            archive.add(payload, arcname="../escape")
        with self.assertRaisesRegex(website_release.ReleaseError, "unsafe artifact member"):
            website_release.validate_tar(malicious)


if __name__ == "__main__":
    unittest.main()
