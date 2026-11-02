using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using Uten.Legacy.Core;

namespace Uten.Legacy.Tests
{
    internal static class DiagnosticsLogChecks
    {
        internal static int Run()
        {
            int assertions = 0;
            Action<bool, string> check = (condition, message) =>
            { if (!condition) throw new InvalidOperationException("Diagnostics: " + message); assertions++; };
            using (var stream = typeof(Program).Assembly.GetManifestResourceStream("Uten.ClientDiagnosticsFixture.json"))
            using (var reader = new StreamReader(stream))
            {
                var contract = (Dictionary<string, object>)new JavaScriptSerializer().DeserializeObject(reader.ReadToEnd());
                foreach (Dictionary<string, object> sample in (object[])contract["paths"])
                    check(DiagnosticsLog.SafePath((string)sample["input"]) == (string)sample["expected"], "shared diagnostic path fixture");
            }
            string root = Path.Combine(Path.GetTempPath(), "uten-wpf-log-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            File.WriteAllText(Path.Combine(root, "business.txt"), "retained");
            for (int i = 0; i < 20; i++)
            {
                string old = Path.Combine(root, "app-old-" + i + ".log");
                File.WriteAllText(old, "{}\n"); File.SetLastWriteTimeUtc(old, DateTime.UtcNow.AddDays(-30).AddSeconds(i));
            }
            using (var log = new DiagnosticsLog(root, "2.5.43+2543"))
            {
                log.Write("request.begin", method: "POST", path: "/api/goods/123?password=secret");
                for (int i = 0; i < 1000; i++) log.Write("diagnostic.surge", elapsed: i);
                try { throw new InvalidOperationException("password=secret business text"); }
                catch (Exception error) { log.Fatal("managed.test_exception", error); }
            }
            Thread.Sleep(150);
            var files = Directory.GetFiles(root, "*.log");
            string text = String.Join("\n", files.Select(ReadShared));
            check(text.Contains("wpf_legacy") && text.Contains("2.5.43+2543"), "logs retain runtime/version");
            check(text.Contains("managed.test_exception") && text.Contains("InvalidOperationException"), "exception has a durable .log record");
            check(!text.Contains("password") && !text.Contains("secret") && !text.Contains("business text"), "credential/body/exception messages absent");
            check(DiagnosticsLog.SafePath("/api/goods/123?token=secret") == "/api/goods/:id", "same sanitized path contract as Flutter");
            check(File.ReadAllText(Path.Combine(root, "business.txt")) == "retained", "unrelated files survive retention");
            check(files.Length <= 18, "log count bounded");
            check(files.All(x => new FileInfo(x).Length <= 2 * 1024 * 1024), "log size bounded");
            Console.WriteLine("PASS automatic WPF diagnostics assertions=" + assertions);
            return assertions;
        }
        private static string ReadShared(string path)
        {
            using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (var reader = new StreamReader(file, Encoding.UTF8)) return reader.ReadToEnd();
        }
    }
}
