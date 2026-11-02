using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace Uten.Legacy.Core.Tests
{
    public static class UserErrorMessageChecks
    {
        public static void Run()
        {
            var assembly = typeof(ApiException).Assembly;
            using (var stream = assembly.GetManifestResourceStream("Uten.Legacy.Core.UserErrorMessageFixture.json"))
            {
                Require(stream != null, "shared display contract must be embedded");
                using (var reader = new StreamReader(stream, Encoding.UTF8))
                {
                    var fixture = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(reader.ReadToEnd());
                    Require(Convert.ToInt32(fixture["schemaVersion"]) == 1, "shared display schema");
                    int count = 0;
                    foreach (Dictionary<string, object> item in (IEnumerable)fixture["cases"])
                    {
                        string code = (string)item["code"], message = (string)item["message"], expected = (string)item["expected"];
                        int? status = item["status"] == null ? (int?)null : Convert.ToInt32(item["status"]);
                        foreach (bool unknown in new[] { false, true })
                        {
                            var error = new ApiException(code, message, status, unknown, !unknown);
                            Require(error.UserMessage == expected, "shared user copy: " + code);
                            Require(error.Message == expected, "generic exception display uses the same public copy: " + code);
                            Require(error.Code == code && error.StatusCode == status, "wire identity is unchanged: " + code);
                            Require(error.IsSubmissionUnknown == unknown && error.HasResponseCode == !unknown,
                                "display copy cannot change delivery classification: " + code);
                        }
                        count++;
                    }
                    Require(count > 0, "shared display cases must not be empty");
                    Console.WriteLine("PASS shared user error display cases=" + count + "; wire/outcome fields unchanged");
                }
            }
        }

        private static void Require(bool condition, string name)
        {
            if (!condition) throw new InvalidOperationException("User error display contract failed: " + name);
        }
    }
}
