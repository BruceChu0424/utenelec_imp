using System;
using System.Collections.Generic;
using System.Web.Script.Serialization;

namespace Uten.Legacy.Desktop.Features.Downloads
{
    /// <summary>Offline contract fixtures; the desktop project includes *Checks only in Debug.</summary>
    public static class DownloadsContractChecks
    {
        public static int Run()
        {
            int assertions = 0;
            Action<bool, string> check = (condition, message) =>
            {
                if (!condition) throw new InvalidOperationException("Downloads contract: " + message);
                assertions++;
            };
            check(SoftwareDownloadsContract.CatalogPath("x86") == "/client-updates/downloads?platform=windows&architecture=x86&allRuntimeFamilies=true",
                "catalog uses approved API with explicit architecture and all families");
            Reject(() => SoftwareDownloadsContract.CatalogPath("universal"), check, "unsupported architecture rejected");
            var flutterValue = Value("flutter", "x64", "installer");
            flutterValue.Remove("runtimeFamily");
            ClientPackageDescriptor old = ClientPackageDescriptor.Parse(flutterValue);
            check(old.RuntimeFamily == ClientPackageDescriptor.FlutterRuntime, "missing family defaults to Flutter");
            flutterValue["runtimeFamily"] = null;
            check(ClientPackageDescriptor.Parse(flutterValue).RuntimeFamily == ClientPackageDescriptor.FlutterRuntime, "null family defaults to Flutter");
            var legacy = ClientPackageDescriptor.Parse(Value("wpf_legacy", "x64", "installer"));
            check(legacy.IsInstallerFor("wpf_legacy", "x64"), "legacy installer exact target");
            check(!legacy.IsInstallerFor("flutter", "x64") && !legacy.IsInstallerFor("wpf_legacy", "x86"), "no family or architecture fallback");
            var update = ClientPackageDescriptor.Parse(Value("wpf_legacy", "x64", "update"));
            check(update.IsUpdateFor("wpf_legacy", "x64", 44), "higher-build WPF archive is an update");
            check(!update.IsUpdateFor("wpf_legacy", "x64", 45) && !update.IsUpdateFor("wpf_legacy", "x64", 46), "same or older builds cannot update");
            check(!update.IsUpdateFor("flutter", "x64", 44) && !update.IsUpdateFor("wpf_legacy", "x86", 44), "update target remains exact");
            check(!legacy.IsUpdateFor("wpf_legacy", "x64", 1) && !update.IsInstallerFor("wpf_legacy", "x64"), "setup and archive are distinct");
            var missingKind = Value("flutter", "x64", "update");
            missingKind.Remove("packageKind");
            check(ClientPackageDescriptor.Parse(missingKind).PackageKind == "update", "legacy absent kind remains update");
            var wrongs = new List<Dictionary<string, object>>();
            var missingState = Value("wpf_legacy", "x64", "installer"); missingState.Remove("state"); wrongs.Add(missingState);
            foreach (string state in new[] { "DRAFT", "WITHDRAWN", "published" })
            { var item = Value("wpf_legacy", "x64", "installer"); item["state"] = state; wrongs.Add(item); }
            wrongs.Add(Value("unreviewed", "x64", "installer"));
            wrongs.Add(Value("wpf_legacy", "arm64", "installer"));
            wrongs.Add(Value("wpf_legacy", "AnyCPU", "installer"));
            foreach (var pair in new[] {
                new KeyValuePair<string, object>("installMode", "windows_setup"),
                new KeyValuePair<string, object>("sha256", "bad"),
                new KeyValuePair<string, object>("sizeBytes", 0),
                new KeyValuePair<string, object>("sizeBytes", ClientPackageDescriptor.MaximumPackageBytes + 1),
                new KeyValuePair<string, object>("sizeBytes", 123.5),
                new KeyValuePair<string, object>("buildNumber", 65536),
                new KeyValuePair<string, object>("id", "not-a-uuid"),
                new KeyValuePair<string, object>("fileName", "../credentials.exe"),
                new KeyValuePair<string, object>("fileName", "setup.zip"),
                new KeyValuePair<string, object>("fileName", "CON.exe") })
            { var item = Value("wpf_legacy", "x64", "installer"); item[pair.Key] = pair.Value; wrongs.Add(item); }
            foreach (var item in wrongs) Reject(() => ClientPackageDescriptor.Parse(item), check, "invalid/unpublished metadata rejected");
            var values = new List<Dictionary<string, object>> {
                Value("flutter", "x64", "installer"), Value("wpf_legacy", "x64", "installer"),
                Value("wpf_legacy", "x86", "installer"), Value("wpf_legacy", "x64", "update") };
            values.AddRange(wrongs);
            var catalog = SoftwareDownloadsContract.ParseCatalog(new JavaScriptSerializer().Serialize(values));
            check(catalog.Count == 3, "only valid published installers enter download catalog");
            check(SoftwareDownloadsContract.SelectInstaller(catalog, "wpf_legacy", "x64").RuntimeFamily == "wpf_legacy", "catalog selects compatibility family");
            check(SoftwareDownloadsContract.SelectInstaller(catalog, "wpf_legacy", "x86").Architecture == "x86", "catalog selects exact x86");
            check(SoftwareDownloadsContract.SelectInstaller(new[] { legacy }, "wpf_legacy", "x86") == null, "missing x86 does not offer x64");
            return assertions;
        }

        private static Dictionary<string, object> Value(string family, string architecture, string kind)
        {
            return new Dictionary<string, object> { ["id"] = "8ab749a6-c355-491a-985c-a37b061b4ee1", ["state"] = "PUBLISHED", ["platform"] = "windows",
                ["runtimeFamily"] = family, ["architecture"] = architecture, ["version"] = "1.2.3", ["buildNumber"] = 45,
                ["sha256"] = new string('a', 64), ["sizeBytes"] = 123, ["packageKind"] = kind,
                ["installMode"] = (family == "flutter" ? "windows_" : "windows_wpf_") + (kind == "installer" ? "setup" : "archive"),
                ["fileName"] = "UTEN-" + architecture + (kind == "installer" ? "-setup.exe" : "-update.zip"), ["releaseNotes"] = "Offline fixture" };
        }
        private static void Reject(Action action, Action<bool, string> check, string message)
        {
            bool rejected = false;
            try { action(); }
            catch (FormatException) { rejected = true; }
            catch (ArgumentException) { rejected = true; }
            check(rejected, message);
        }
    }
}
