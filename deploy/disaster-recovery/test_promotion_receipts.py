import base64
import copy
import hashlib
import json
import unittest

import control_plane as cp
import promotion_receipts as pr
import test_control_plane as fixtures


@unittest.skipUnless(pr.CRYPTO_READY, "pinned Ed25519 verifier required; run Linux promotion fixture")
class PromotionReceiptTest(unittest.TestCase):
    setUp = fixtures.ControlPlaneTest.setUp
    enroll = fixtures.ControlPlaneTest.enroll
    ready = fixtures.ControlPlaneTest.ready
    refused = fixtures.ControlPlaneTest.refused
    revision = fixtures.ControlPlaneTest.revision

    def commission(self):
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        self.ready()
        self.keys = {purpose: Ed25519PrivateKey.generate() for purpose in pr.PURPOSES}
        self.config["promotion"] = {"commissioned": True, "currentPrimaryId": "company-primary", "minimumEpoch": 7,
            "signers": {purpose.lower(): {"publicKey": key.public_key().public_bytes_raw().hex(),
                         "purpose": purpose, "sourceIds": ["company-primary"], "targetIds": ["cloud-standby"]}
                        for purpose, key in self.keys.items()}}
        self.config["agents"]["standby"] = {"tokenSha256": cp.digest("standby-secret"),
                                           "targetIds": ["cloud-standby"], "canDrill": False, "canPromote": True}
        self.control = cp.ControlPlane(self.control.database, self.config, lambda: self.now[0], master_key=b"M" * 32)
        self.control.put_target(self.user, "cloud-standby", {"label": "Test standby", "agentId": "standby",
                                "kind": "BUSINESS", "expectedRevision": self.revision()})
        self.control.snapshot("standby-secret", {"agentId": "standby", "sequence": 1, "observedAt": cp.utc(self.now[0]),
                              "health": "HEALTHY", "recoveryPoints": []})
        self.operation = self.control.promotions.prepare(self.user, {"requestId": str(__import__("uuid").uuid4()),
            "targetId": "cloud-standby", "recoveryPointId": "set-1", "expectedRevision": self.revision(), "expectedEpoch": 7})

    def sign(self, receipt):
        receipt["signature"] = base64.b64encode(self.keys[receipt["purpose"]].sign(pr.canonical(receipt))).decode()
        return receipt

    def receipt(self, purpose, lease=""):
        return self.sign({"version": 1, "receiptId": str(__import__("uuid").uuid4()), "purpose": purpose,
            "signerId": purpose.lower(), "operationId": self.operation["id"], "sourceId": "company-primary",
            "targetId": "cloud-standby", "recoveryPointId": "set-1", "manifestSha256": "a" * 64,
            "epoch": 8, "issuedAt": cp.utc(self.now[0]), "expiresAt": cp.utc(self.now[0] + 120),
            "checks": dict.fromkeys(pr.CHECKS[purpose], True),
            "databaseSystemIdentifier": "123456789" if purpose != "FENCE" else "",
            "restoredLsn": "0/ABC" if purpose != "FENCE" else "", "leaseSha256": lease})

    def authorize(self, fence=None, restore=None):
        return self.control.promotions.authorize(self.user, {"operationId": self.operation["id"],
            "expectedRevision": self.revision(), "expectedEpoch": 7,
            "fenceReceipt": fence or self.receipt("FENCE"), "restoreReceipt": restore or self.receipt("RESTORE")})

    def test_real_ed25519_flow_reserves_epoch_and_requires_activation_signature(self):
        self.commission()
        self.assertEqual("PREPARING", self.operation["state"])
        self.assertEqual("QUEUED", self.authorize()["state"])
        state = self.control.state(self.user)
        self.assertEqual(8, state["authorityEpoch"])
        self.assertEqual("FENCED", state["authorityMode"])
        claim = self.control.claim("standby-secret", {"agentId": "standby"})
        self.assertEqual("PROMOTE", claim["job"]["kind"])
        completion = {"leaseToken": claim["leaseToken"], "success": True,
                      "activationReceipt": self.receipt("ACTIVATION", cp.digest(claim["leaseToken"]))}
        self.assertEqual("SUCCEEDED", self.control.complete("standby-secret", self.operation["id"], completion)["state"])
        final = self.control.state(self.user)
        self.assertEqual("cloud-standby", final["businessLocation"])
        self.assertEqual(8, final["authorityEpoch"])

    def test_validly_signed_wrong_binding_or_self_supplied_key_never_fences_authority(self):
        self.commission()
        for field, value in [("targetId", "other-host"), ("sourceId", "other-primary"),
                             ("manifestSha256", "f" * 64), ("epoch", 99), ("operationId", "wrong-operation"),
                             ("publicKey", "self-supplied-key")]:
            with self.subTest(field=field):
                fence = self.receipt("FENCE")
                fence[field] = value
                self.sign(fence)
                self.refused("SIGNED_RECEIPT_INVALID", lambda: self.authorize(fence=fence))
        state = self.control.state(self.user)
        self.assertEqual(7, state["authorityEpoch"])
        self.assertEqual("ACTIVE", state["authorityMode"])
        with self.control.connect() as db:
            self.assertEqual(0, db.execute("SELECT count(*) FROM receipt_ledger").fetchone()[0])

    def test_archive_token_and_unsigned_booleans_cannot_authorize_promotion(self):
        self.commission()
        self.refused("UNAUTHORIZED", lambda: self.control.dispatch("POST", "/v1/promotions", {
            "fenced": True, "restoreVerified": True}, "backup-secret", "", "peer"))
        self.refused("SIGNED_RECEIPT_INVALID", lambda: self.authorize(fence={"fenced": True}))

    def test_expired_fencing_is_rejected_at_claim_and_never_reopens_old_primary(self):
        self.commission()
        self.authorize()
        self.now[0] += 121
        self.refused("SIGNED_RECEIPT_INVALID", lambda: self.control.claim("standby-secret", {"agentId": "standby"}))
        state = self.control.state(self.user)
        self.assertEqual("FENCED", state["authorityMode"])
        self.assertEqual(8, state["authorityEpoch"])

    def test_activation_is_bound_to_lease_and_restored_database_identity(self):
        self.commission()
        self.authorize()
        claim = self.control.claim("standby-secret", {"agentId": "standby"})
        wrong = self.receipt("ACTIVATION", "e" * 64)
        self.refused("SIGNED_RECEIPT_INVALID", lambda: self.control.complete("standby-secret", self.operation["id"], {
            "leaseToken": claim["leaseToken"], "success": True, "activationReceipt": wrong}))
        changed = self.receipt("ACTIVATION", cp.digest(claim["leaseToken"]))
        changed["databaseSystemIdentifier"] = "999999"
        self.sign(changed)
        self.refused("RESTORED_DATABASE_IDENTITY_CHANGED", lambda: self.control.complete("standby-secret", self.operation["id"], {
            "leaseToken": claim["leaseToken"], "success": True, "activationReceipt": changed}))

    def test_failure_never_decrements_reserved_epoch_or_unfences_old_primary(self):
        self.commission()
        self.authorize()
        claim = self.control.claim("standby-secret", {"agentId": "standby"})
        result = self.control.complete("standby-secret", self.operation["id"], {"leaseToken": claim["leaseToken"], "success": False})
        self.assertEqual("FAILED", result["state"])
        state = self.control.state(self.user)
        self.assertEqual(8, state["authorityEpoch"])
        self.assertEqual("FENCED", state["authorityMode"])

    def assert_restored_control_below_new_floor_is_blocked(self, running):
        self.commission()
        fence = self.receipt("FENCE")
        self.authorize(fence=fence)
        claim = self.control.claim("standby-secret", {"agentId": "standby"}) if running else None
        self.config["promotion"]["minimumEpoch"] = 9
        self.control = cp.ControlPlane(self.control.database, self.config, lambda: self.now[0], master_key=b"M" * 32)
        state = self.control.state(self.user)
        self.assertEqual("UNKNOWN", state["authorityMode"])
        self.assertEqual("UNKNOWN", state["jobs"][0]["state"])
        self.assertIn("AUTHORITY_EPOCH_BELOW_FLOOR_OR_UNKNOWN", state["promotionReasons"])
        self.assertEqual({"job": None}, self.control.claim("standby-secret", {"agentId": "standby"}))
        if claim:
            self.refused("LEASE_INVALID", lambda: self.control.complete("standby-secret", self.operation["id"], {
                "leaseToken": claim["leaseToken"], "success": True,
                "activationReceipt": self.receipt("ACTIVATION", cp.digest(claim["leaseToken"]))}))

    def test_restored_old_queued_job_cannot_bypass_new_minimum_epoch(self):
        self.assert_restored_control_below_new_floor_is_blocked(False)

    def test_restored_old_running_job_cannot_complete_below_new_minimum_epoch(self):
        self.assert_restored_control_below_new_floor_is_blocked(True)

    def test_unknown_activation_is_resolved_only_by_fresh_signed_observation_without_replay(self):
        self.commission()
        self.authorize()
        claim = self.control.claim("standby-secret", {"agentId": "standby"})
        self.now[0] += 121
        self.control.state(self.user)
        result = self.control.promotions.reconcile(self.user, self.operation["id"], {
            "expectedRevision": self.revision(), "fenceReceipt": self.receipt("FENCE"),
            "activationReceipt": self.receipt("ACTIVATION", cp.digest(claim["leaseToken"]))})
        self.assertEqual("SUCCEEDED", result["state"])
        self.assertTrue(result["evidence"]["reconciled"])
        self.assertEqual({"job": None}, self.control.claim("standby-secret", {"agentId": "standby"}))


if __name__ == "__main__":
    unittest.main()
