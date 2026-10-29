using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;

namespace Uten.Legacy.Updater
{
    public sealed class UpdateFile
    {
        public string Name { get; internal set; }
        public long Size { get; internal set; }
        public string Sha256 { get; internal set; }
    }
    public sealed class UpdatePlan
    {
        public string AppRoot { get; internal set; }
        public string JobRoot { get; internal set; }
        public string PackagePath { get; internal set; }
        public string Sha256 { get; internal set; }
        public long SizeBytes { get; internal set; }
        public string Version { get; internal set; }
        public int BuildNumber { get; internal set; }
        public string Architecture { get; internal set; }
        public int ParentPid { get; internal set; }
        public long ParentStartTimeUtcTicks { get; internal set; }
        internal string CurrentVersion;
        internal int CurrentBuild;
        internal readonly Dictionary<string, UpdateFile> OriginalFiles = new Dictionary<string, UpdateFile>(StringComparer.Ordinal);
    }
    public sealed class PreparedUpdate
    {
        public string StageRoot { get; internal set; }
        public IReadOnlyList<UpdateFile> Files { get; internal set; }
    }
    /// <summary>Candidate-only package validation. No package assembly is loaded or executed.</summary>
    public static class UpdateContract
    {
        public const string MainExecutable = PackageContract.Executable;
        public const string ManifestName = PackageContract.Manifest;
        public const long MaximumPackageBytes = PackageContract.MaximumPackageBytes;
        public const long MaximumExpandedBytes = PackageContract.MaximumExpandedBytesExclusive;
        // Main remains last; the approved set and all bounded values have one owning JSON.
        internal static readonly string[] ApprovedFiles = PackageContract.Files
            .OrderBy(name => name == MainExecutable ? 1 : 0).ThenBy(name => name, StringComparer.Ordinal).ToArray();
        private static readonly Regex Digest = new Regex(@"\A[0-9a-f]{64}\z", RegexOptions.CultureInvariant);

        public static UpdatePlan ReadInstruction(string instructionPath)
        {
            var own = SafeFiles.Full(typeof(UpdateContract).Assembly.Location);
            var directory = Path.GetDirectoryName(own);
            if (!String.Equals(Path.GetFileName(directory), "client_updater", StringComparison.OrdinalIgnoreCase)
                || !String.Equals(Path.GetFileName(own), "Uten.Legacy.Updater.exe", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("The updater must run from its fixed installed directory.");
            var profile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Uten", "UIMP-Win7-WPF");
            return ReadInstructionForChecks(instructionPath, Path.GetDirectoryName(directory), profile,
                Environment.Is64BitProcess ? "x64" : "x86");
        }

        internal static UpdatePlan ReadInstructionForChecks(string instructionPath, string appRoot, string profileRoot, string processArchitecture)
        {
            instructionPath = SafeFiles.Full(instructionPath); appRoot = SafeFiles.Full(appRoot); profileRoot = SafeFiles.Full(profileRoot);
            var job = Path.GetDirectoryName(instructionPath); Guid jobId;
            if (Path.GetFileName(instructionPath) != "instruction.json" || !Guid.TryParse(Path.GetFileName(job), out jobId)
                || !SafeFiles.Same(Path.GetDirectoryName(job), Path.Combine(profileRoot, "client-updates")))
                throw new InvalidDataException("Instruction must belong to one private WPF update job.");
            using (SafeFiles.GuardDirectories(appRoot, job))
            {
                var value = StrictJson.Read(SafeFiles.Bytes(instructionPath, 65536));
                StrictJson.Keys(value, new[] { "schemaVersion", "packagePath", "sha256", "sizeBytes", "version", "buildNumber",
                    "architecture", "runtimeFamily", "parentPid", "parentStartTimeUtcTicks" });
                if (StrictJson.Integer(value, "schemaVersion", 1, 1) != 1 || StrictJson.Text(value, "runtimeFamily", 30) != "wpf_legacy")
                    throw new InvalidDataException("Only the independent WPF runtime can be updated.");
                var architecture = StrictJson.Text(value, "architecture", 8);
                if ((architecture != "x86" && architecture != "x64") || architecture != processArchitecture)
                    throw new InvalidDataException("Updater and application architectures differ.");
                var package = SafeFiles.Full(StrictJson.Text(value, "packagePath", 1024));
                if (!SafeFiles.Same(package, SafeFiles.Child(job, "package.zip"))) throw new InvalidDataException("Package leaves the private job.");
                var plan = new UpdatePlan { AppRoot = appRoot, JobRoot = job, PackagePath = package,
                    Sha256 = RequiredDigest(value, "sha256"), SizeBytes = StrictJson.Integer(value, "sizeBytes", 1, MaximumPackageBytes),
                    Version = RequiredVersion(value), BuildNumber = (int)StrictJson.Integer(value, "buildNumber", 1, 65535), Architecture = architecture,
                    ParentPid = (int)StrictJson.Integer(value, "parentPid", 1, Int32.MaxValue),
                    ParentStartTimeUtcTicks = StrictJson.Integer(value, "parentStartTimeUtcTicks", DateTime.MinValue.Ticks + 1, DateTime.MaxValue.Ticks) };
                if (plan.ParentPid == Process.GetCurrentProcess().Id && processArchitecture == (Environment.Is64BitProcess ? "x64" : "x86"))
                    throw new InvalidDataException("Updater cannot wait for itself.");
                var current = ReadIdentity(SafeFiles.Child(appRoot, MainExecutable), architecture, "Uten.Legacy.Desktop", true);
                plan.CurrentVersion = current.Item1; plan.CurrentBuild = current.Item2;
                if (plan.CurrentBuild < 1) throw new InvalidDataException("Installed build metadata is missing.");
                ReadIdentity(SafeFiles.Child(appRoot, "Uten.Legacy.Core.dll"), architecture, "Uten.Legacy.Core", false,
                    plan.CurrentVersion, plan.CurrentBuild);
                if (System.Version.Parse(plan.Version) < System.Version.Parse(plan.CurrentVersion) || plan.BuildNumber <= plan.CurrentBuild)
                    throw new InvalidDataException("Update must have a newer build and must not downgrade product version.");
                foreach (var name in ApprovedFiles)
                {
                    using (var file = SafeFiles.Open(SafeFiles.Child(appRoot, name), FileAccess.Read))
                    {
                        if (file.Length < 1 || file.Length >= MaximumExpandedBytes) throw new InvalidDataException("Installed file is missing or oversized.");
                        plan.OriginalFiles.Add(name, new UpdateFile { Name = name, Size = file.Length, Sha256 = SafeFiles.Hash(file) });
                    }
                }
                if (plan.OriginalFiles.Values.Sum(file => file.Size) >= MaximumExpandedBytes)
                    throw new InvalidDataException("Installed recovery copy exceeds its aggregate limit.");
                return plan;
            }
        }

        public static PreparedUpdate PreparePackage(UpdatePlan plan)
        {
            if (plan == null || plan.OriginalFiles.Count != ApprovedFiles.Length) throw new InvalidDataException("Expected an anchored update plan.");
            using (SafeFiles.GuardDirectories(plan.AppRoot, plan.JobRoot))
            using (var package = SafeFiles.Open(plan.PackagePath, FileAccess.Read))
            {
                if (package.Length != plan.SizeBytes || package.Length > MaximumPackageBytes || SafeFiles.Hash(package) != plan.Sha256)
                    throw new InvalidDataException("Update ZIP size or SHA-256 differs.");
                ZipDirectory.Require(package);
                using (var archive = new ZipArchive(package, ZipArchiveMode.Read, true))
                {
                    var expected = new HashSet<string>(ApprovedFiles, StringComparer.Ordinal) { ManifestName };
                    var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase); long expanded = 0;
                    foreach (var entry in archive.Entries)
                    {
                        var attributes = unchecked((uint)entry.ExternalAttributes); var unixType = (attributes >> 16) & 0xF000;
                        if (!names.Add(entry.FullName) || !expected.Contains(entry.FullName) || (attributes & (0x400 | 0x10)) != 0
                            || (unixType != 0 && unixType != 0x8000) || entry.Length < 1 || entry.Length > PackageContract.MaximumFileBytes)
                            throw new InvalidDataException("ZIP contains an unapproved, linked, duplicate or oversized entry.");
                        expanded = checked(expanded + entry.Length);
                        if (expanded >= MaximumExpandedBytes) throw new InvalidDataException("ZIP expanded size exceeds its aggregate limit.");
                    }
                    if (names.Count != expected.Count) throw new InvalidDataException("ZIP does not contain exactly the six runtime files and manifest.");
                    byte[] raw;
                    if (archive.GetEntry(ManifestName).Length > PackageContract.MaximumManifestBytes)
                        throw new InvalidDataException("Update manifest exceeds the shared contract limit.");
                    using (var stream = archive.GetEntry(ManifestName).Open())
                    using (var output = new MemoryStream()) { SafeFiles.Copy(stream, output, PackageContract.MaximumManifestBytes); raw = output.ToArray(); }
                    var manifest = StrictJson.Read(raw);
                    StrictJson.Keys(manifest, PackageContract.ManifestRequiredKeys, PackageContract.ManifestOptionalKeys);
                    if (StrictJson.Text(manifest, "packageKind", 20) != "update")
                        throw new InvalidDataException("Only update ZIPs may replace an installed runtime.");
                    if (manifest.ContainsKey("sourceCommit") && !Regex.IsMatch(StrictJson.Text(manifest, "sourceCommit", 40), @"\A[0-9a-f]{40}\z"))
                        throw new InvalidDataException("Invalid source commit identity.");
                    if (StrictJson.Integer(manifest, "schemaVersion", 1, 1) != 1 || StrictJson.Text(manifest, "platform", 20) != "windows"
                        || StrictJson.Text(manifest, "runtimeFamily", 30) != "wpf_legacy" || StrictJson.Text(manifest, "architecture", 8) != plan.Architecture
                        || RequiredVersion(manifest) != plan.Version || StrictJson.Integer(manifest, "buildNumber", 1, 65535) != plan.BuildNumber
                        || StrictJson.Text(manifest, "executable", 100) != MainExecutable)
                        throw new InvalidDataException("Update manifest family, version, architecture or identity differs.");
                    object flag;
                    if (manifest.TryGetValue("candidate", out flag) && (!(flag is bool) || !(bool)flag)
                        || manifest.TryGetValue("releaseReady", out flag) && (!(flag is bool) || (bool)flag))
                        throw new InvalidDataException("This executor is a candidate, not a release activation gate.");
                    var records = manifest["files"] as object[];
                    if (records == null || records.Length != ApprovedFiles.Length) throw new InvalidDataException("Invalid update file manifest.");
                    var files = new Dictionary<string, UpdateFile>(StringComparer.Ordinal);
                    foreach (var item in records)
                    {
                        var record = item as Dictionary<string, object>;
                        if (record == null) throw new InvalidDataException("Invalid update file record.");
                        StrictJson.Keys(record, PackageContract.FileRecordKeys);
                        var name = StrictJson.Text(record, "path", 100);
                        if (!ApprovedFiles.Contains(name, StringComparer.Ordinal) || files.ContainsKey(name)) throw new InvalidDataException("Unapproved update file.");
                        var file = new UpdateFile { Name = name, Size = StrictJson.Integer(record, "size", 1, MaximumPackageBytes), Sha256 = RequiredDigest(record, "sha256") };
                        if (archive.GetEntry(name).Length != file.Size) throw new InvalidDataException("ZIP and manifest lengths differ.");
                        files.Add(name, file);
                    }
                    if (files["BouncyCastle.Cryptography.dll"].Sha256 != PackageContract.DependencyDllSha256
                        || files["BouncyCastle-LICENSE.md"].Sha256 != PackageContract.DependencyLicenseSha256)
                        throw new InvalidDataException("Schema-1 managed TLS DLL/license differ from the authoritative dependency lock; install a new complete Setup for a dependency upgrade.");
                    var stage = SafeFiles.Child(plan.JobRoot, "stage");
                    if (Directory.Exists(stage) || File.Exists(stage)) throw new IOException("Stage already exists; preserve its recovery evidence.");
                    Directory.CreateDirectory(stage);
                    using (SafeFiles.GuardDirectories(stage))
                    {
                        foreach (var name in ApprovedFiles)
                        {
                            var record = files[name];
                            using (var source = archive.GetEntry(name).Open())
                            using (var output = SafeFiles.Open(SafeFiles.Child(stage, name), FileAccess.ReadWrite, true))
                            {
                                if (SafeFiles.Copy(source, output, record.Size) != record.Size || SafeFiles.Hash(output) != record.Sha256)
                                    throw new InvalidDataException("Extracted file size or SHA-256 differs.");
                                output.Flush(true);
                            }
                        }
                        ReadIdentity(SafeFiles.Child(stage, MainExecutable), plan.Architecture, "Uten.Legacy.Desktop", true, plan.Version, plan.BuildNumber, requireCompany: true);
                        ReadIdentity(SafeFiles.Child(stage, "Uten.Legacy.Core.dll"), plan.Architecture, "Uten.Legacy.Core", false, plan.Version, plan.BuildNumber, requireCompany: true);
                        ReadIdentity(SafeFiles.Child(stage, "BouncyCastle.Cryptography.dll"), plan.Architecture, "BouncyCastle.Cryptography", false, requireAnyCpu: true);
                    }
                    return new PreparedUpdate { StageRoot = stage, Files = ApprovedFiles.Select(name => files[name]).ToList().AsReadOnly() };
                }
            }
        }

        private static string RequiredDigest(Dictionary<string, object> value, string key)
        { var result = StrictJson.Text(value, key, 64); if (!Digest.IsMatch(result)) throw new InvalidDataException("Invalid SHA-256 metadata."); return result; }
        private static string RequiredVersion(Dictionary<string, object> value)
        {
            var text = StrictJson.Text(value, "version", 30); System.Version version;
            if (!Regex.IsMatch(text, @"\A[0-9]+\.[0-9]+\.[0-9]+\z") || !System.Version.TryParse(text, out version)
                || version.Major > 65535 || version.Minor > 65535 || version.Build > 65535 || version.ToString(3) != text)
                throw new InvalidDataException("Invalid product version.");
            return text;
        }

        internal static Tuple<string, int> ReadIdentity(string path, string architecture, string assemblyName, bool executable,
            string expectedVersion = null, int expectedBuild = 0, bool requireAnyCpu = false, bool requireCompany = false)
        {
            using (var file = SafeFiles.Open(path, FileAccess.Read))
            using (var reader = new BinaryReader(file, Encoding.UTF8, true))
            {
                if (file.Length < 1 || file.Length > PackageContract.MaximumManagedFileBytes)
                    throw new InvalidDataException("Managed image exceeds the shared WPF contract limit.");
                Func<long, int, byte[]> bytes = (offset, count) =>
                { if (offset < 0 || count < 0 || offset > file.Length - count) throw new InvalidDataException("Truncated PE metadata."); file.Position = offset; return reader.ReadBytes(count); };
                var dos = bytes(0, 64); if (dos[0] != 'M' || dos[1] != 'Z') throw new InvalidDataException("Missing PE header.");
                var pe = BitConverter.ToUInt32(dos, 60); var header = bytes(pe, 24);
                if (BitConverter.ToUInt32(header, 0) != 0x00004550) throw new InvalidDataException("Missing PE signature.");
                var machine = BitConverter.ToUInt16(header, 4); var sections = BitConverter.ToUInt16(header, 6);
                var optionalSize = BitConverter.ToUInt16(header, 20); var characteristics = BitConverter.ToUInt16(header, 22);
                if ((characteristics & 2) == 0 || ((characteristics & 0x2000) == 0) != executable || sections < 1 || sections > 96)
                    throw new InvalidDataException("PE executable/library role differs.");
                var optional = bytes(pe + 24, optionalSize); var magic = BitConverter.ToUInt16(optional, 0);
                var directories = magic == 0x10b ? 96 : magic == 0x20b ? 112 : 0;
                if (directories == 0 || optionalSize < directories + 120 || BitConverter.ToUInt32(optional, directories - 4) < 15)
                    throw new InvalidDataException("Missing CLR metadata directory.");
                var table = bytes(pe + 24 + optionalSize, sections * 40);
                Func<uint, int, long> map = (rva, count) =>
                {
                    for (var index = 0; index < sections; index++)
                    {
                        var start = BitConverter.ToUInt32(table, index * 40 + 12); var size = BitConverter.ToUInt32(table, index * 40 + 16);
                        if (rva >= start && (ulong)rva + (uint)count <= (ulong)start + size)
                            return (long)BitConverter.ToUInt32(table, index * 40 + 20) + rva - start;
                    }
                    throw new InvalidDataException("CLR metadata leaves backed PE sections.");
                };
                var clrSize = BitConverter.ToUInt32(optional, directories + 14 * 8 + 4);
                if (clrSize != PackageContract.ClrHeaderBytes) throw new InvalidDataException("Invalid CLR header length.");
                var clr = bytes(map(BitConverter.ToUInt32(optional, directories + 14 * 8), PackageContract.ClrHeaderBytes), PackageContract.ClrHeaderBytes);
                var flags = BitConverter.ToUInt32(clr, 16);
                if (BitConverter.ToUInt32(clr, 0) != PackageContract.ClrHeaderBytes || (flags & 1) == 0 || (flags & 0x10) != 0 || (flags & 0x20000) != 0)
                    throw new InvalidDataException("Only IL-only managed images are accepted.");
                var exactX86 = machine == 0x14c && magic == 0x10b && (flags & 2) != 0;
                var exactX64 = machine == 0x8664 && magic == 0x20b && (flags & 2) == 0;
                var anyCpu = machine == 0x14c && magic == 0x10b && (flags & 2) == 0;
                if (requireAnyCpu && !anyCpu) throw new InvalidDataException("The fixed managed TLS dependency must be AnyCPU.");
                if (!(architecture == "x86" ? exactX86 || !executable && anyCpu : architecture == "x64" && (exactX64 || !executable && anyCpu)))
                    throw new InvalidDataException("PE/CLR architecture differs from the installed application.");
                var metadataSize = BitConverter.ToUInt32(clr, 12);
                if (metadataSize < 20 || metadataSize > PackageContract.MaximumMetadataBytes) throw new InvalidDataException("Invalid CLR metadata size.");
                var metadataOffset = map(BitConverter.ToUInt32(clr, 8), (int)metadataSize);
                if (metadataOffset > file.Length - metadataSize) throw new InvalidDataException("Truncated CLR metadata region.");
                var metadata = bytes(metadataOffset, 16);
                var versionLength = BitConverter.ToUInt32(metadata, 12);
                if (BitConverter.ToUInt32(metadata, 0) != 0x424a5342 || versionLength < 1 || versionLength > PackageContract.MaximumClrVersionBytes || 16 + versionLength > metadataSize
                    || !Encoding.ASCII.GetString(bytes(map(BitConverter.ToUInt32(clr, 8), (int)metadataSize) + 16, (int)versionLength)).StartsWith(PackageContract.ClrVersionPrefix, StringComparison.Ordinal))
                    throw new InvalidDataException("Expected CLR v4 metadata.");
                // These APIs read PE/CLR metadata; neither loads an assembly for execution.
                var name = AssemblyName.GetAssemblyName(path);
                if (name.Name != assemblyName) throw new InvalidDataException("Managed assembly identity differs.");
                var info = FileVersionInfo.GetVersionInfo(path);
                if (requireCompany && !String.Equals(info.Comments, PackageContract.CompanyReleaseMarker, StringComparison.Ordinal))
                    throw new InvalidDataException("Only a compiled Release/Company application and Core may enter this WPF update.");
                var product = info.FileMajorPart + "." + info.FileMinorPart + "." + info.FileBuildPart;
                if (executable && (name.Version != new System.Version(product + ".0")
                    || info.ProductMajorPart != info.FileMajorPart || info.ProductMinorPart != info.FileMinorPart
                    || info.ProductBuildPart != info.FileBuildPart || info.ProductPrivatePart != info.FilePrivatePart))
                    throw new InvalidDataException("Installed application assembly and file versions differ.");
                if (expectedVersion != null && (product != expectedVersion || info.FilePrivatePart != expectedBuild
                    || info.ProductMajorPart != info.FileMajorPart || info.ProductMinorPart != info.FileMinorPart
                    || info.ProductBuildPart != info.FileBuildPart || info.ProductPrivatePart != expectedBuild
                    || name.Version != new System.Version(expectedVersion + ".0")))
                    throw new InvalidDataException("Application/Core version resources differ from the manifest.");
                return Tuple.Create(product, info.FilePrivatePart);
            }
        }
    }
}
