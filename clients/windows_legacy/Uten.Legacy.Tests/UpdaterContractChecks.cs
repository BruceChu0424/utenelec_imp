using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Reflection.Emit;
using System.Text;
using System.Threading;
using Uten.Legacy.Updater;
using DesktopPreparedUpdate = Uten.Legacy.Desktop.Updates.PreparedUpdate;

namespace Uten.Legacy.Tests
{
    /// <summary>Only owned temporary fixtures. Never calls updater Execute or starts a package executable.</summary>
    public static class UpdaterContractChecks
    {
        private static int assertions;
        private static FixtureAssemblyEmitter emitter;
        public static int Run()
        {
            assertions = 0;
            // Synthetic assemblies deliberately use product identities for metadata validation.
            // Keep their dynamic builders out of WPF's resource-resolution AppDomain.
            var domain = AppDomain.CreateDomain("UtenUpdaterFixtureEmitter-" + Guid.NewGuid().ToString("N"), null,
                new AppDomainSetup { ApplicationBase = AppDomain.CurrentDomain.BaseDirectory });
            try
            {
                emitter = (FixtureAssemblyEmitter)domain.CreateInstanceAndUnwrap(typeof(FixtureAssemblyEmitter).Assembly.FullName,
                    typeof(FixtureAssemblyEmitter).FullName);
                ValidPreparationDoesNotChangeInstallation();
                UnsafeZipAndRuntimeContracts();
                PackageAndMetadataIdentityChecks();
                ConcurrentChangesArePreserved();
                ExclusiveLeasesAndControlledRollback();
                ExplicitAuthorizationAndCancellation();
                DesktopConsentLifecycle();
                InstructionScopeAndDuplicateJson();
                return assertions;
            }
            finally { emitter = null; AppDomain.Unload(domain); }
        }
        private static void ValidPreparationDoesNotChangeInstallation()
        {
            using (var fixture = new Fixture())
            {
                var plan = fixture.Plan(); var original = fixture.InstalledHashes();
                var prepared = UpdateContract.PreparePackage(plan);
                Equal(6, prepared.Files.Count, "exact six-file runtime");
                foreach (var file in prepared.Files)
                {
                    Equal(file.Sha256, SafeFiles.Hash(Path.Combine(prepared.StageRoot, file.Name)), "extracted content matches SHA");
                    Equal(original[file.Name], SafeFiles.Hash(Path.Combine(fixture.AppRoot, file.Name)), "preparation does not mutate installation");
                }
                True(!File.Exists(Path.Combine(fixture.JobRoot, "ready.json")), "preparation alone cannot authorize parent shutdown");
            }
        }
        private static void UnsafeZipAndRuntimeContracts()
        {
            foreach (var extra in new[] { "../escape.exe", "client_updater/evil.exe", "payload:stream", "uten.legacy.desktop.exe", "uten-wpf.ico" })
                using (var fixture = new Fixture())
                {
                    fixture.WritePackage(extra: extra);
                    Throws(() => UpdateContract.PreparePackage(fixture.Plan()), "ZIP path/case/protected-file whitelist");
                    True(!Directory.Exists(Path.Combine(fixture.JobRoot, "stage")), "unsafe ZIP is rejected before extraction");
                }
            using (var fixture = new Fixture())
            {
                fixture.Manifest["runtimeFamily"] = "flutter"; fixture.WritePackage();
                Throws(() => UpdateContract.PreparePackage(fixture.Plan()), "cross-runtime update denied");
            }
            using (var fixture = new Fixture())
            {
                fixture.Manifest["packageKind"] = "installer"; fixture.WritePackage();
                Throws(() => UpdateContract.PreparePackage(fixture.Plan()), "installer cannot apply as update");
            }
            using (var fixture = new Fixture())
            {
                fixture.Manifest.Remove("packageKind"); fixture.WritePackage();
                Throws(() => UpdateContract.PreparePackage(fixture.Plan()), "new WPF ZIP requires explicit update kind");
            }
            using (var fixture = new Fixture())
            {
                fixture.Manifest["packageKind"] = null; fixture.WritePackage();
                Throws(() => UpdateContract.PreparePackage(fixture.Plan()), "new WPF ZIP rejects null kind");
            }
            using (var fixture = new Fixture())
            {
                fixture.WritePackage(linked: true);
                Throws(() => UpdateContract.PreparePackage(fixture.Plan()), "ZIP symlink attributes denied");
            }
            using (var fixture = new Fixture())
            {
                fixture.InflateCentralDirectoryLengths();
                Throws(() => UpdateContract.PreparePackage(fixture.Plan()), "aggregate zipbomb denied before decompression");
                True(!Directory.Exists(Path.Combine(fixture.JobRoot, "stage")), "bomb did not create stage");
            }
        }
        private static void PackageAndMetadataIdentityChecks()
        {
            using (var fixture = new Fixture())
            {
                var plan = fixture.Plan(); plan.Sha256 = new string('0', 64);
                Throws(() => UpdateContract.PreparePackage(plan), "outer ZIP hash");
            }
            using (var fixture = new Fixture())
            {
                var plan = fixture.Plan(); plan.SizeBytes++;
                Throws(() => UpdateContract.PreparePackage(plan), "outer ZIP size");
            }
            using (var fixture = new Fixture())
            {
                fixture.Emit("Uten.Legacy.Core", false, fixture.Incoming, "2.5.35", 2536, fixture.Architecture);
                fixture.WritePackage();
                Throws(() => UpdateContract.PreparePackage(fixture.Plan()), "Core file version differs from app/build");
            }
            using (var fixture = new Fixture())
            {
                var main = Path.Combine(fixture.Incoming, UpdateContract.MainExecutable);
                var bytes = File.ReadAllBytes(main); var pe = BitConverter.ToInt32(bytes, 60);
                bytes[pe + 4] = 0; bytes[pe + 5] = 0; File.WriteAllBytes(main, bytes); fixture.WritePackage();
                Throws(() => UpdateContract.PreparePackage(fixture.Plan()), "PE architecture does not follow filename");
            }
            using (var fixture = new Fixture())
            {
                var instruction = fixture.Instruction(); instruction["buildNumber"] = 2534;
                File.WriteAllBytes(fixture.InstructionPath, StrictJson.Write(instruction));
                Throws(() => fixture.ReadPlan(), "same/lower installed build rejected");
            }
        }
        private static void ConcurrentChangesArePreserved()
        {
            using (var fixture = new Fixture())
            {
                var plan = fixture.Plan(); var prepared = UpdateContract.PreparePackage(plan);
                fixture.Authorize(plan);
                var external = Path.Combine(fixture.AppRoot, "uten.client.json");
                File.WriteAllText(external, "external-change-owned-by-fixture");
                Throws(() => UpdateExecutor.ApplyForChecks(plan, prepared), "external edit causes fail-closed apply");
                Equal("external-change-owned-by-fixture", File.ReadAllText(external), "external change is never overwritten");
                True(!Directory.Exists(Path.Combine(fixture.JobRoot, "backup")), "no approved file changed before conflict decision");
            }
        }
        private static void ExclusiveLeasesAndControlledRollback()
        {
            using (var fixture = new Fixture())
            {
                var plan = fixture.Plan(); var prepared = UpdateContract.PreparePackage(plan); var old = fixture.InstalledHashes();
                fixture.Authorize(plan);
                var result = UpdateExecutor.ApplyForChecks(plan, prepared, count => { if (count == 1) throw new IOException("fixture failure after first file"); });
                True(!result.Succeeded && result.RollbackComplete, "in-process failure rolls back completely");
                foreach (var name in old.Keys) Equal(old[name], SafeFiles.Hash(Path.Combine(fixture.AppRoot, name)), "old file restored exactly");
                True(Directory.Exists(Path.Combine(fixture.JobRoot, "backup")) && Directory.Exists(prepared.StageRoot), "all recovery materials retained");
            }
            using (var fixture = new Fixture())
            {
                var plan = fixture.Plan(); var prepared = UpdateContract.PreparePackage(plan); var blocked = false;
                fixture.Authorize(plan);
                var result = UpdateExecutor.ApplyForChecks(plan, prepared, count =>
                {
                    if (count != 1) return;
                    try { File.WriteAllText(Path.Combine(fixture.AppRoot, "Uten.Legacy.Core.dll"), "unwanted writer"); }
                    catch (IOException) { blocked = true; }
                });
                True(blocked && result.Succeeded, "exclusive leases deny concurrent external writes during application");
                foreach (var file in prepared.Files) Equal(file.Sha256, SafeFiles.Hash(Path.Combine(fixture.AppRoot, file.Name)), "complete candidate installed in fixture only");
            }
            using (var fixture = new Fixture())
            {
                var plan = fixture.Plan(); var prepared = UpdateContract.PreparePackage(plan); var old = fixture.InstalledHashes();
                File.WriteAllText(Path.Combine(fixture.JobRoot, "cancel.flag"), "cancelled");
                Throws(() => UpdateExecutor.ApplyForChecks(plan, prepared), "cancelled job does not apply");
                foreach (var name in old.Keys) Equal(old[name], SafeFiles.Hash(Path.Combine(fixture.AppRoot, name)), "cancel leaves installed bytes intact");
            }
        }
        private static void ExplicitAuthorizationAndCancellation()
        {
            using (var fixture = new Fixture())
            {
                var plan = fixture.Plan(); var prepared = UpdateContract.PreparePackage(plan); var old = fixture.InstalledHashes();
                // This is the same gate reached after a normal verified parent exit.
                Throws(() => UpdateExecutor.ApplyForChecks(plan, prepared), "ordinary parent exit without explicit consent never applies");
                fixture.AssertUnchanged(old, "no-consent job leaves installation intact");
                True(!Directory.Exists(Path.Combine(fixture.JobRoot, "backup")), "no consent does not begin installation backup");
            }
            foreach (var field in new[] { "schemaVersion", "state", "runtimeFamily", "architecture", "packageSha256", "packageSizeBytes",
                "version", "buildNumber", "parentPid", "parentStartTimeUtcTicks", "updaterPid", "unknown" })
                using (var fixture = new Fixture())
                {
                    var plan = fixture.Plan(); var prepared = UpdateContract.PreparePackage(plan); var old = fixture.InstalledHashes();
                    var consent = fixture.Consent(plan);
                    switch (field)
                    {
                        case "schemaVersion": consent[field] = 2; break;
                        case "packageSizeBytes": consent[field] = plan.SizeBytes + 1; break;
                        case "buildNumber": consent[field] = plan.BuildNumber + 1; break;
                        case "parentPid": consent[field] = plan.ParentPid + 1; break;
                        case "parentStartTimeUtcTicks": consent[field] = plan.ParentStartTimeUtcTicks + 1; break;
                        case "updaterPid": consent[field] = Process.GetCurrentProcess().Id + 1; break;
                        default: consent[field] = "wrong-fixture-value"; break;
                    }
                    fixture.WriteConsent(consent);
                    Throws(() => UpdateExecutor.ApplyForChecks(plan, prepared), "consent mismatch rejected: " + field);
                    fixture.AssertUnchanged(old, "invalid consent never mutates approved files");
                }
            foreach (var cancellationAfter in new[] { 1, 6 })
                using (var fixture = new Fixture())
                {
                    var plan = fixture.Plan(); var prepared = UpdateContract.PreparePackage(plan); var old = fixture.InstalledHashes();
                    fixture.Authorize(plan);
                    var result = UpdateExecutor.ApplyForChecks(plan, prepared, count =>
                    { if (count == cancellationAfter) fixture.Cancel(); });
                    True(!result.Succeeded && result.RollbackComplete, "cancellation during apply uses controlled rollback");
                    fixture.AssertUnchanged(old, "cancel after an approved write restores previous complete installation");
                }
        }
        private static void DesktopConsentLifecycle()
        {
            using (var fixture = new Fixture())
            using (var token = new CancellationTokenSource())
            {
                var plan = fixture.Plan(); var prepared = UpdateContract.PreparePackage(plan); var old = fixture.InstalledHashes();
                using (var capability = fixture.Capability(plan, token.Token))
                {
                    capability.SetReadyForChecks(Process.GetCurrentProcess().Id);
                    capability.Cancel();
                    True(File.Exists(Path.Combine(fixture.JobRoot, "cancel.flag")), "ready then Cancel persists same-job cancellation");
                    // Parent may exit later; even a forged matching consent cannot override its cancel.
                    fixture.Authorize(plan);
                    Throws(() => UpdateExecutor.ApplyForChecks(plan, prepared), "ready then cancel then later parent exit cannot apply");
                    fixture.AssertUnchanged(old, "cancelled ready job preserves old bytes");
                    Throws(() => capability.AuthorizeShutdown(), "cancelled capability cannot authorize shutdown");
                }
            }
            using (var fixture = new Fixture())
            using (var token = new CancellationTokenSource())
            {
                var plan = fixture.Plan();
                using (var capability = fixture.Capability(plan, token.Token))
                {
                    capability.SetReadyForChecks(Process.GetCurrentProcess().Id); token.Cancel();
                    True(File.Exists(Path.Combine(fixture.JobRoot, "cancel.flag")), "pending caller CT durably cancels ready job");
                    Throws(() => capability.AuthorizeShutdown(), "cancelled owner token cannot authorize");
                    True(!File.Exists(Path.Combine(fixture.JobRoot, "apply-authorized.json")), "pending cancellation never emits consent");
                }
            }
            using (var fixture = new Fixture())
            {
                var plan = fixture.Plan(); var owner = true;
                using (var capability = fixture.Capability(plan, CancellationToken.None, () => owner))
                {
                    capability.SetReadyForChecks(Process.GetCurrentProcess().Id); owner = false;
                    Throws(() => capability.AuthorizeShutdown(), "changed session cannot authorize");
                    True(File.Exists(Path.Combine(fixture.JobRoot, "cancel.flag")), "changed session persists cancellation");
                    True(!File.Exists(Path.Combine(fixture.JobRoot, "apply-authorized.json")), "changed session has no consent");
                }
            }
            using (var fixture = new Fixture())
            using (var token = new CancellationTokenSource())
            {
                var plan = fixture.Plan(); var prepared = UpdateContract.PreparePackage(plan);
                using (var capability = fixture.Capability(plan, token.Token))
                {
                    capability.SetReadyForChecks(Process.GetCurrentProcess().Id); capability.AuthorizeShutdown();
                    True(capability.IsAuthorized, "explicit checked consent publishes authorization");
                    token.Cancel(); // The application's confirmed normal shutdown cancels its lifetime token.
                    True(!File.Exists(Path.Combine(fixture.JobRoot, "cancel.flag")), "confirmed normal shutdown does not cancel authorized job");
                    UpdateAuthorization.Require(plan);
                    True(UpdateExecutor.ApplyForChecks(plan, prepared).Succeeded, "desktop consent retains complete apply preflight");
                }
                True(!File.Exists(Path.Combine(fixture.JobRoot, "cancel.flag")), "disposing confirmed capability does not revoke consent");
            }
            using (var fixture = new Fixture())
            {
                var plan = fixture.Plan(); var owner = true; var checks = 0;
                using (var capability = fixture.Capability(plan, CancellationToken.None, () => owner,
                    () => { if (++checks == 3) owner = false; }))
                {
                    capability.SetReadyForChecks(Process.GetCurrentProcess().Id);
                    // MarkReady is check1; authorization check2; before atomic rename is check3.
                    Throws(() => capability.AuthorizeShutdown(), "ownership loss during consent publication cancels before shutdown");
                    True(File.Exists(Path.Combine(fixture.JobRoot, "cancel.flag")), "consent-publication race has a durable cancellation fence");
                    Throws(() => UpdateAuthorization.Require(plan), "a raced consent marker cannot override its cancellation fence");
                }
            }
            using (var fixture = new Fixture())
            {
                var plan = fixture.Plan();
                using (var capability = fixture.Capability(plan, CancellationToken.None))
                {
                    capability.SetReadyForChecks(Process.GetCurrentProcess().Id); capability.AuthorizeShutdown(); capability.Cancel();
                    Throws(() => UpdateAuthorization.Require(plan), "explicit Cancel dominates previously published consent");
                }
            }
            using (var fixture = new Fixture())
            {
                var plan = fixture.Plan();
                using (var capability = fixture.Capability(plan, CancellationToken.None)) { }
                True(File.Exists(Path.Combine(fixture.JobRoot, "cancel.flag")), "disposing unconfirmed preparation persists cancel");
            }
        }
        private static void InstructionScopeAndDuplicateJson()
        {
            Throws(() => StrictJson.Read(Encoding.UTF8.GetBytes("{\"x\":1,\"\\u0078\":2}")), "escaped duplicate JSON keys");
            using (var fixture = new Fixture())
            {
                var value = fixture.Instruction(); value["packagePath"] = Path.Combine(fixture.Root, "outside.zip");
                File.WriteAllBytes(fixture.InstructionPath, StrictJson.Write(value));
                Throws(() => fixture.ReadPlan(), "package cannot escape its private job");
                value = fixture.Instruction(); value["command"] = "never-executed";
                File.WriteAllBytes(fixture.InstructionPath, StrictJson.Write(value));
                Throws(() => fixture.ReadPlan(), "instruction cannot supply a shell command");
            }
        }
        private static void True(bool value, string label) { assertions++; if (!value) throw new InvalidOperationException(label); }
        private static void Equal<T>(T expected, T actual, string label) { True(EqualityComparer<T>.Default.Equals(expected, actual), label); }
        private static void Throws(Action action, string label)
        {
            try { action(); }
            catch (Exception error) when (error is IOException || error is InvalidDataException || error is BadImageFormatException
                || error is ArgumentException || error is OperationCanceledException)
            { assertions++; return; }
            catch (Uten.Legacy.Core.ApiException) { assertions++; return; }
            throw new InvalidOperationException("Expected rejection: " + label);
        }

        private sealed class Fixture : IDisposable
        {
            internal readonly string Root, AppRoot, Incoming, ProfileRoot, JobRoot, InstructionPath, Architecture;
            internal Dictionary<string, object> Manifest;
            internal Fixture()
            {
                Root = Path.Combine(Path.GetTempPath(), "uten-wpf-updater-check-" + Guid.NewGuid().ToString("N"));
                Architecture = Environment.Is64BitProcess ? "x64" : "x86";
                AppRoot = Path.Combine(Root, "installed"); Incoming = Path.Combine(Root, "incoming"); ProfileRoot = Path.Combine(Root, "profile");
                JobRoot = Path.Combine(ProfileRoot, "client-updates", Guid.NewGuid().ToString("D")); InstructionPath = Path.Combine(JobRoot, "instruction.json");
                Directory.CreateDirectory(AppRoot); Directory.CreateDirectory(Incoming); Directory.CreateDirectory(JobRoot);
                foreach (var directory in new[] { AppRoot, Incoming })
                {
                    var next = directory == Incoming; var version = next ? "2.5.35" : "2.5.34"; var build = next ? 2535 : 2534;
                    Emit("Uten.Legacy.Desktop", true, directory, version, build, Architecture);
                    Emit("Uten.Legacy.Core", false, directory, version, build, Architecture);
                    Emit("BouncyCastle.Cryptography", false, directory, "2.7.0", 1, "anycpu");
                    File.WriteAllText(Path.Combine(directory, "Uten.Legacy.Desktop.exe.config"), next ? "new-runtime-configuration" : "old-runtime-configuration");
                    File.WriteAllText(Path.Combine(directory, "BouncyCastle-LICENSE.md"), "fixture-license");
                    File.WriteAllText(Path.Combine(directory, "uten.client.json"), next ? "new-approved-config-fixture" : "old-approved-config-fixture");
                }
                Manifest = new Dictionary<string, object> { { "schemaVersion", 1 }, { "platform", "windows" }, { "runtimeFamily", "wpf_legacy" },
                    { "architecture", Architecture }, { "version", "2.5.35" }, { "buildNumber", 2535 }, { "packageKind", "update" },
                    { "executable", UpdateContract.MainExecutable }, { "sourceCommit", new string('1', 40) }, { "candidate", true }, { "releaseReady", false } };
                WritePackage();
            }
            internal void Emit(string name, bool executable, string directory, string version, int build, string architecture)
            { emitter.Emit(name, executable, directory, version, build, architecture); }
            internal void WritePackage(string extra = null, bool linked = false)
            {
                Manifest["files"] = UpdateContract.ApprovedFiles.Select(name => (object)new Dictionary<string, object>
                { { "path", name }, { "size", new FileInfo(Path.Combine(Incoming, name)).Length }, { "sha256", SafeFiles.Hash(Path.Combine(Incoming, name)) } }).ToArray();
                using (var file = File.Create(Path.Combine(JobRoot, "package.zip")))
                using (var archive = new ZipArchive(file, ZipArchiveMode.Create))
                {
                    foreach (var name in UpdateContract.ApprovedFiles)
                    {
                        var entry = archive.CreateEntry(name);
                        if (linked && name == UpdateContract.MainExecutable) entry.ExternalAttributes = unchecked((int)0xa1ff0000);
                        using (var output = entry.Open()) { var bytes = File.ReadAllBytes(Path.Combine(Incoming, name)); output.Write(bytes, 0, bytes.Length); }
                    }
                    using (var output = archive.CreateEntry(UpdateContract.ManifestName).Open())
                    { var bytes = StrictJson.Write(Manifest); output.Write(bytes, 0, bytes.Length); }
                    if (extra != null) using (var output = archive.CreateEntry(extra).Open()) output.WriteByte(1);
                }
            }
            internal Dictionary<string, object> Instruction()
            {
                var package = Path.Combine(JobRoot, "package.zip");
                return new Dictionary<string, object> { { "schemaVersion", 1 }, { "packagePath", package }, { "sha256", SafeFiles.Hash(package) },
                    { "sizeBytes", new FileInfo(package).Length }, { "version", "2.5.35" }, { "buildNumber", 2535 }, { "architecture", Architecture },
                    { "runtimeFamily", "wpf_legacy" }, { "parentPid", 1 }, { "parentStartTimeUtcTicks", DateTime.UtcNow.Ticks } };
            }
            internal UpdatePlan Plan() { File.WriteAllBytes(InstructionPath, StrictJson.Write(Instruction())); return ReadPlan(); }
            internal UpdatePlan ReadPlan() { return UpdateContract.ReadInstructionForChecks(InstructionPath, AppRoot, ProfileRoot, Architecture); }
            internal Dictionary<string, string> InstalledHashes()
            { return UpdateContract.ApprovedFiles.ToDictionary(name => name, name => SafeFiles.Hash(Path.Combine(AppRoot, name))); }
            internal void AssertUnchanged(Dictionary<string, string> old, string label)
            { foreach (var name in old.Keys) Equal(old[name], SafeFiles.Hash(Path.Combine(AppRoot, name)), label); }
            internal Dictionary<string, object> Consent(UpdatePlan plan)
            { return new Dictionary<string, object> { { "schemaVersion", 1 }, { "state", "apply_authorized" }, { "runtimeFamily", "wpf_legacy" },
                { "architecture", plan.Architecture }, { "packageSha256", plan.Sha256 }, { "packageSizeBytes", plan.SizeBytes },
                { "version", plan.Version }, { "buildNumber", plan.BuildNumber }, { "parentPid", plan.ParentPid },
                { "parentStartTimeUtcTicks", plan.ParentStartTimeUtcTicks }, { "updaterPid", Process.GetCurrentProcess().Id } }; }
            internal void WriteConsent(Dictionary<string, object> consent)
            { File.WriteAllBytes(Path.Combine(JobRoot, "apply-authorized.json"), StrictJson.Write(consent)); }
            internal void Authorize(UpdatePlan plan) { WriteConsent(Consent(plan)); }
            internal void Cancel() { File.WriteAllText(Path.Combine(JobRoot, "cancel.flag"), "fixture-cancelled"); }
            internal DesktopPreparedUpdate Capability(UpdatePlan plan, CancellationToken cancellation, Func<bool> owner = null, Action afterJobCheck = null)
            { return new DesktopPreparedUpdate(JobRoot, plan.Sha256, plan.SizeBytes, plan.Version, plan.BuildNumber, plan.Architecture,
                plan.ParentPid, plan.ParentStartTimeUtcTicks, cancellation, owner ?? (() => true), () =>
                {
                    if (!SafeFiles.Same(Path.GetDirectoryName(JobRoot), Path.Combine(ProfileRoot, "client-updates")))
                        throw new InvalidOperationException("Capability fixture leaves its private job parent.");
                    Uten.Legacy.Desktop.Updates.ClientUpdateCoordinator.RejectLinks(JobRoot);
                    if (afterJobCheck != null) afterJobCheck();
                }); }
            internal void InflateCentralDirectoryLengths()
            {
                var path = Path.Combine(JobRoot, "package.zip"); var bytes = File.ReadAllBytes(path);
                for (var index = 0; index <= bytes.Length - 46; index++)
                {
                    if (BitConverter.ToUInt32(bytes, index) != 0x02014b50) continue;
                    var nameLength = BitConverter.ToUInt16(bytes, index + 28);
                    if (index + 46 + nameLength > bytes.Length) throw new InvalidOperationException("fixture central directory");
                    var name = Encoding.UTF8.GetString(bytes, index + 46, nameLength);
                    if (name != UpdateContract.ManifestName) Array.Copy(BitConverter.GetBytes(200 * 1024 * 1024), 0, bytes, index + 24, 4);
                }
                File.WriteAllBytes(path, bytes);
            }
            public void Dispose() { DeleteOwnedTree(Root, Root); }
            private static void DeleteOwnedTree(string anchor, string directory)
            {
                var root = Path.GetFullPath(anchor); var full = Path.GetFullPath(directory);
                if (!Path.GetFileName(root).StartsWith("uten-wpf-updater-check-", StringComparison.Ordinal)
                    || !SafeFiles.Same(Path.GetDirectoryName(root), Path.GetTempPath().TrimEnd(Path.DirectorySeparatorChar))
                    || !(full == root || full.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase)))
                    throw new InvalidOperationException("Fixture cleanup leaves its exact temporary workspace.");
                if ((File.GetAttributes(full) & FileAttributes.ReparsePoint) != 0) throw new IOException("Fixture cleanup refuses directory links.");
                foreach (var file in Directory.GetFiles(full))
                {
                    if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0) throw new IOException("Fixture cleanup refuses links.");
                    File.Delete(file);
                }
                foreach (var child in Directory.GetDirectories(full)) DeleteOwnedTree(anchor, child);
                Directory.Delete(full, false); // No recursive delete API and no production path accepted.
            }
        }

        /// <summary>Only emits known inert test bytes in a separate unloadable AppDomain.</summary>
        public sealed class FixtureAssemblyEmitter : MarshalByRefObject
        {
            public override object InitializeLifetimeService() { return null; }
            public void Emit(string name, bool executable, string directory, string version, int build, string architecture)
            {
                var identity = new AssemblyName(name) { Version = new Version(version + ".0") };
                var builder = AppDomain.CurrentDomain.DefineDynamicAssembly(identity, AssemblyBuilderAccess.Save, directory);
                builder.SetCustomAttribute(new CustomAttributeBuilder(typeof(AssemblyFileVersionAttribute).GetConstructor(new[] { typeof(string) }), new object[] { version + "." + build }));
                builder.SetCustomAttribute(new CustomAttributeBuilder(typeof(AssemblyInformationalVersionAttribute).GetConstructor(new[] { typeof(string) }), new object[] { version + "." + build }));
                var filename = name + (executable ? ".exe" : ".dll");
                var module = builder.DefineDynamicModule(name, filename); var type = module.DefineType("FixtureOnly", TypeAttributes.Public);
                if (executable)
                {
                    var main = type.DefineMethod("Main", MethodAttributes.Public | MethodAttributes.Static, typeof(void), Type.EmptyTypes);
                    main.GetILGenerator().Emit(OpCodes.Ret); type.CreateType(); builder.SetEntryPoint(main, PEFileKinds.WindowApplication);
                }
                else type.CreateType();
                builder.DefineVersionInfoResource();
                var kind = PortableExecutableKinds.ILOnly;
                if (architecture == "x86") kind |= PortableExecutableKinds.Required32Bit;
                if (architecture == "x64") kind |= PortableExecutableKinds.PE32Plus;
                builder.Save(filename, kind, architecture == "x64" ? ImageFileMachine.AMD64 : ImageFileMachine.I386);
            }
        }
    }
}
