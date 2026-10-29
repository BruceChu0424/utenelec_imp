using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;

namespace Uten.Legacy.Desktop.Features.Downloads
{
    /// <summary>The shared, strict published-package contract for download and update callers.</summary>
    public sealed class ClientPackageDescriptor
    {
        public const string FlutterRuntime = "flutter";
        public const string LegacyRuntime = "wpf_legacy";
        public const long MaximumPackageBytes = 536870912;

        private ClientPackageDescriptor() { }
        public string Id { get; private set; }
        public string RuntimeFamily { get; private set; }
        public string Architecture { get; private set; }
        public string Version { get; private set; }
        public int BuildNumber { get; private set; }
        public string Sha256 { get; private set; }
        public long SizeBytes { get; private set; }
        public string FileName { get; private set; }
        public string PackageKind { get; private set; }
        public string InstallMode { get; private set; }
        public string ReleaseNotes { get; private set; }
        public string State { get { return "PUBLISHED"; } }

        public static ClientPackageDescriptor Parse(Dictionary<string, object> value)
        {
            if (value == null || Text(value, "state") != "PUBLISHED" || Text(value, "platform") != "windows")
                throw new FormatException("软件包尚未发布或平台不符。");
            string family = Text(value, "runtimeFamily") ?? FlutterRuntime;
            string architecture = Text(value, "architecture");
            if ((family != FlutterRuntime && family != LegacyRuntime)
                || (architecture != "x86" && architecture != "x64" && !(family == FlutterRuntime && architecture == "arm64")))
                throw new FormatException("未知的软件运行时或架构。");
            string kind = Text(value, "packageKind") ?? "update";
            string mode = Text(value, "installMode");
            string prefix = family == LegacyRuntime ? "windows_wpf_" : "windows_";
            if ((kind != "installer" && kind != "update") || mode != prefix + (kind == "installer" ? "setup" : "archive"))
                throw new FormatException("软件包类型与运行时不一致。");
            string id = Text(value, "id"), sha = Text(value, "sha256"), version = Text(value, "version");
            Guid identifier;
            if (!Guid.TryParseExact(id, "D", out identifier) || sha == null || !Regex.IsMatch(sha, "\\A[0-9a-fA-F]{64}\\z")
                || version == null || !Regex.IsMatch(version, "\\A(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)\\z"))
                throw new FormatException("软件包标识、摘要或版本无效。");
            foreach (string part in version.Split('.'))
            {
                ushort number;
                if (!UInt16.TryParse(part, NumberStyles.None, CultureInfo.InvariantCulture, out number))
                    throw new FormatException("软件包版本超出 Windows 版本资源范围。");
            }
            long size = Integer(value, "sizeBytes"), build = Integer(value, "buildNumber");
            if (size <= 0 || size > MaximumPackageBytes || build <= 0 || build > 65535)
                throw new FormatException("软件包大小或构建号无效。");
            string filename = Text(value, "fileName");
            string extension = kind == "installer" ? ".exe" : ".zip";
            if (filename == null) filename = "UTEN-" + family + "-" + version + "-" + architecture + extension;
            if (filename.Length > 180 || filename.Length == 0 || !filename.EndsWith(extension, StringComparison.OrdinalIgnoreCase)
                || filename.EndsWith(" ", StringComparison.Ordinal) || filename.EndsWith(".", StringComparison.Ordinal)
                || filename.IndexOfAny(new[] { '<', '>', ':', '"', '/', '\\', '|', '?', '*' }) >= 0
                || filename.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
                throw new FormatException("软件包文件名无效。");
            string stem = filename.Split('.')[0].ToUpperInvariant();
            if (Regex.IsMatch(stem, "\\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\\z"))
                throw new FormatException("软件包文件名不能是系统保留名称。");
            return new ClientPackageDescriptor { Id = identifier.ToString("D"), RuntimeFamily = family,
                Architecture = architecture, Version = version, BuildNumber = (int)build, Sha256 = sha.ToLowerInvariant(),
                SizeBytes = size, FileName = filename, PackageKind = kind, InstallMode = mode,
                ReleaseNotes = Text(value, "releaseNotes", true) ?? "" };
        }

        public bool IsInstallerFor(string runtimeFamily, string architecture)
        {
            return PackageKind == "installer" && RuntimeFamily == runtimeFamily && Architecture == architecture;
        }
        public bool IsUpdateFor(string runtimeFamily, string architecture, long currentBuild)
        {
            return PackageKind == "update" && RuntimeFamily == runtimeFamily && Architecture == architecture && BuildNumber > currentBuild;
        }
        private static string Text(Dictionary<string, object> value, string name, bool multiline = false)
        {
            object raw;
            if (!value.TryGetValue(name, out raw) || raw == null) return null;
            var text = raw as string;
            if (text == null || text.Length > (multiline ? 10000 : 2048)) throw new FormatException("软件包文字字段无效。");
            foreach (char character in text)
                if (Char.IsControl(character) && !(multiline && (character == '\r' || character == '\n' || character == '\t')))
                    throw new FormatException("软件包文字字段含控制字符。");
            return text;
        }
        private static long Integer(Dictionary<string, object> value, string name)
        {
            object raw;
            if (!value.TryGetValue(name, out raw) || !(raw is int || raw is long)) throw new FormatException("软件包整数参数无效。");
            return Convert.ToInt64(raw, CultureInfo.InvariantCulture);
        }
    }
}
