import copy
import unittest
import company_test_release as publication
from test_release_gate import FixtureApi, REPOSITORY, SHA
from release_gate import GateError


class CompanyTestingPublicationTests(unittest.TestCase):
    def setUp(self):
        self.environment = {"GITHUB_SHA": SHA, "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main"}

    def test_only_exact_explicit_manual_main_source_is_authorized(self):
        publication.bind_manual_source(SHA, SHA, publication.CONFIRMATION, self.environment)
        for field, value in (("GITHUB_SHA", "c" * 40), ("GITHUB_EVENT_NAME", "push"), ("GITHUB_REF", "refs/tags/v2.5.48")):
            with self.subTest(field=field), self.assertRaises(GateError):
                publication.bind_manual_source(SHA, SHA, publication.CONFIRMATION, {**self.environment, field: value})
        for expected, confirmation in (("c" * 40, publication.CONFIRMATION), (SHA, "yes")):
            with self.assertRaises(GateError):
                publication.bind_manual_source(SHA, expected, confirmation, self.environment)

    def test_failed_ci_is_recorded_truthfully_and_never_certified_green(self):
        api = FixtureApi()
        api.details[1000] = copy.deepcopy(api.current(1000))
        api.details[1000]["conclusion"] = "failure"
        evidence = publication.collect(api, REPOSITORY, SHA)
        self.assertFalse(evidence["ciCertifiedGreen"])
        self.assertEqual("failure", evidence["workflows"][0]["conclusion"])
        self.assertEqual(SHA, evidence["sourceCommit"])

    def test_workflow_or_run_identity_still_fails_closed(self):
        api = FixtureApi()
        api.details[1000] = copy.deepcopy(api.current(1000))
        api.details[1000]["head_sha"] = "c" * 40
        with self.assertRaises(GateError):
            publication.collect(api, REPOSITORY, SHA)


if __name__ == "__main__":
    unittest.main()
