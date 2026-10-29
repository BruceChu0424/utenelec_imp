// Explicit Csc-only inert process fixture. Not compiled into Desktop, Core,
// Updater or the main test runner. Only private Temp control files are used.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Web.Script.Serialization;

internal static class UpdaterProcessFixture
{
    private static int Main()
    {
        try
        {
            string root = Path.GetFullPath(Environment.GetEnvironmentVariable("UTEN_WPF_EXECUTE_ROOT") ?? "");
            if (!Path.GetFileName(root).StartsWith("uten-wpf-execute-", StringComparison.Ordinal)
                || !String.Equals(Path.GetDirectoryName(root).TrimEnd('\\'), Path.GetTempPath().TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                return 31;
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string expected = Path.Combine(root, "profile", "AppData", "Local");
            if (!String.Equals(Path.GetFullPath(local).TrimEnd('\\'), Path.GetFullPath(expected).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                return 32; // No helper is allowed to run if known-folder isolation failed.
            var proof = new Dictionary<string, object>
            {
                { "schemaVersion", 1 }, { "pid", Process.GetCurrentProcess().Id },
                { "startTimeUtcTicks", Process.GetCurrentProcess().StartTime.ToUniversalTime().Ticks },
                { "image", Assembly.GetExecutingAssembly().Location }, { "localApplicationData", local },
                { "architecture", Environment.Is64BitProcess ? "x64" : "x86" },
                { "fileVersion", FileVersionInfo.GetVersionInfo(Assembly.GetExecutingAssembly().Location).FileVersion },
                { "fixtureOnly", true }
            };
            if (Environment.GetEnvironmentVariable("UTEN_WPF_FIXTURE_MODE") == "probe")
            { Publish(root, "knownfolders.json", proof); return 0; }
#if INCOMING
            Publish(root, "restart-proof.json", proof);
            var restart = Stopwatch.StartNew();
            while (!File.Exists(Path.Combine(root, "restart-exit.flag")) && restart.Elapsed < TimeSpan.FromSeconds(10))
                Thread.Sleep(20);
            return 0;
#else
            Publish(root, "parent-ready.json", proof);
            var wait = Stopwatch.StartNew();
            while (wait.Elapsed < TimeSpan.FromSeconds(90))
            {
                string command = Path.Combine(root, "parent-exit.json");
                if (File.Exists(command))
                {
                    var value = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(command));
                    int code = Convert.ToInt32(value["exitCode"]);
                    return code == 0 || code == 17 ? code : 33;
                }
                Thread.Sleep(20);
            }
            return 34;
#endif
        }
        catch { return 35; }
    }
    private static void Publish(string root, string leaf, object value)
    {
        string temporary = Path.Combine(root, ".fixture-" + Guid.NewGuid().ToString("N"));
        File.WriteAllText(temporary, new JavaScriptSerializer().Serialize(value));
        File.Move(temporary, Path.Combine(root, leaf));
    }
}
