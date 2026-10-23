import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("dns01_hook", Path(__file__).with_name("dns01_hook.py"))
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)


class DnsHookTest(unittest.TestCase):
    def test_official_rpc_signature_vector(self):
        values = {"AccessKeyId": "testid", "AccountId": "100000", "Action": "DescribeDomains", "Format": "XML",
                  "SignatureMethod": "HMAC-SHA1", "RegionId": "cn-hangzhou",
                  "SignatureNonce": "1d1620f8-0b3e-464c-9967-7b54a867945b", "SignatureVersion": "1.0",
                  "Version": "2016-02-01", "Timestamp": "2016-03-29T03:33:18Z"}
        self.assertEqual(hook.signed_parameters(values, "testsecret", method="GET")["Signature"], "fHjifLgCEFdF3VMsNW5PCLa1Ds8=")

    def test_only_two_exact_names_and_bounded_dns_tokens_are_accepted(self):
        token = "public-fixture-token-for-dns-validation"
        for domain in ("justplayit.cn", "admin.justplayit.cn"):
            self.assertEqual(hook.identifier({"CERTBOT_IDENTIFIER": domain, "CERTBOT_VALIDATION": token}), (domain, token))
        for domain in ("*.justplayit.cn", "evil.example", "www.justplayit.cn", "justplayit.cn;rm"):
            with self.assertRaises(ValueError):
                hook.identifier({"CERTBOT_IDENTIFIER": domain, "CERTBOT_VALIDATION": token})

    def test_cleanup_never_deletes_a_record_that_changed_after_authentication(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(hook, "STATE", Path(temporary)):
                path = hook.state_path("justplayit.cn", "public-fixture-token-for-dns-validation")
                path.write_text(json.dumps({"recordId": "123"}))
                with patch.object(hook, "secure_json", return_value={"recordId": "123"}), patch.object(hook, "records", return_value=[{"RecordId": "123", "DomainName": "justplayit.cn", "RR": "@", "Type": "A", "Value": "192.0.2.1"}]), patch.object(hook, "api") as api:
                    with self.assertRaises(ValueError):
                        hook.cleanup("justplayit.cn", "public-fixture-token-for-dns-validation")
                    api.assert_not_called()

    def test_caa_keeps_a_mx_and_unrelated_txt_records_and_limits_deletions(self):
        uri = "https://acme-v02.api.letsencrypt.org/acme/acct/123456"
        original = [{"RecordId": "a", "Type": "A", "RR": "@", "Value": "192.0.2.1"},
                    {"RecordId": "mx", "Type": "MX", "RR": "@", "Value": "mail.example.test"},
                    {"RecordId": "txt", "Type": "TXT", "RR": "@", "Value": "public-fixture"},
                    {"RecordId": "old", "Type": "CAA", "RR": "@", "Value": '0 issue "other-ca.test"'},
                    {"RecordId": "admin-old", "Type": "CAA", "RR": "admin", "Value": '0 issue "other-ca.test"'}]
        after = original[:3] + [{"RecordId": "new-issuer", "RR": "@", "Type": "CAA", "Value": f'0 issue "letsencrypt.org;validationmethods=dns-01;accounturi={uri}"'},
                                {"RecordId": "new-wildcard", "RR": "@", "Type": "CAA", "Value": '0 issuewild ";"'}]
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(hook, "STATE", Path(temporary) / "challenges"), patch.object(hook, "account_uri", return_value=uri), patch.object(hook, "records", side_effect=[original, after]), patch.object(hook, "api", return_value={} ) as api:
                self.assertEqual(hook.ensure_caa(), uri)
                deleted = {call.kwargs["RecordId"] for call in api.call_args_list if call.args[0] == "DeleteDomainRecord"}
                self.assertEqual(deleted, {"old", "admin-old"})
                added = [call.kwargs for call in api.call_args_list if call.args[0] == "AddDomainRecord"]
                self.assertEqual(len(added), 2)
                self.assertTrue(all(call["DomainName"] == "justplayit.cn" and call["RR"] == "@" and call["Type"] == "CAA" for call in added))
                self.assertEqual(api.call_args_list[0].args[0], "AddDomainRecord")


if __name__ == "__main__":
    unittest.main()
