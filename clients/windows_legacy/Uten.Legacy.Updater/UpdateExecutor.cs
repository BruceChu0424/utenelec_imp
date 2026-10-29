using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;

namespace Uten.Legacy.Updater
{
    public sealed class UpdateResult
    {
        public bool Succeeded { get; internal set; }
        public bool RollbackComplete { get; internal set; }
        public string State { get; internal set; }
        public int RestartedPid { get; internal set; }
        public long RestartedStartTimeUtcTicks { get; internal set; }
    }

    /// <summary>
    /// Candidate executor. Exclusive handles prevent concurrent file writes/renames while applying.
    /// In-place writes are deliberately NOT claimed to be a power-loss or cross-file transaction.
    /// All recovery material is retained; a failed update never launches a possibly partial app.
    /// </summary>
    public sealed class UpdateExecutor
    {
        private readonly UpdatePlan plan;
        public UpdateExecutor(string instructionPath) { plan = UpdateContract.ReadInstruction(instructionPath); }

        public UpdateResult Execute()
        {
            using (SafeFiles.GuardDirectories(plan.AppRoot, plan.JobRoot, SafeFiles.Child(plan.AppRoot, "client_updater")))
            using (SafeFiles.Open(SafeFiles.Child(SafeFiles.Child(plan.AppRoot, "client_updater"), "update.lock"), FileAccess.ReadWrite, lockFile: true))
            using (SafeFiles.Open(SafeFiles.Child(plan.JobRoot, "execution.lock"), FileAccess.ReadWrite, lockFile: true))
            using (var journal = new Journal(plan.JobRoot))
            {
                try
                {
                    CheckCancelled(plan);
                    journal.Record("validating");
                    var prepared = UpdateContract.PreparePackage(plan);
                    using (var parent = VerifiedParent(plan))
                    {
                        CheckCancelled(plan);
                        SafeFiles.NewJson(plan.JobRoot, "ready.json", new Dictionary<string, object>
                        {
                            { "schemaVersion", 1 }, { "state", "ready" }, { "parentPid", plan.ParentPid },
                            { "parentStartTimeUtcTicks", plan.ParentStartTimeUtcTicks }, { "updaterPid", Process.GetCurrentProcess().Id }
                        });
                        journal.Record("waiting_for_parent");
                        CheckCancelled(plan);
                        var deadline = Stopwatch.StartNew();
                        while (!parent.WaitForExit(100))
                        {
                            CheckCancelled(plan);
                            if (deadline.Elapsed > TimeSpan.FromSeconds(30)) throw new IOException("Parent did not exit normally before timeout.");
                        }
                        if (parent.ExitCode != 0) throw new IOException("Parent did not exit successfully.");
                    }
                    CheckCancelled(plan);
                    UpdateAuthorization.Require(plan);
                    var result = ApplyPrepared(plan, prepared, journal, null);
                    if (result.Succeeded)
                    {
                        // Verify all approved final files together under read leases while CreateProcess
                        // binds the anchored main executable. No shell, package command, or URL is used.
                        var leases = new List<FileStream>();
                        try
                        {
                            UpdateAuthorization.Require(plan);
                            foreach (var file in prepared.Files)
                            {
                                var lease = SafeFiles.Open(SafeFiles.Child(plan.AppRoot, file.Name), FileAccess.Read);
                                leases.Add(lease);
                                if (lease.Length != file.Size || SafeFiles.Hash(lease) != file.Sha256) throw new IOException("Installed file changed before restart.");
                            }
                            var started = Process.Start(new ProcessStartInfo
                            {
                                FileName = SafeFiles.Child(plan.AppRoot, UpdateContract.MainExecutable), WorkingDirectory = plan.AppRoot,
                                UseShellExecute = false, Arguments = String.Empty
                            });
                            if (started == null) throw new IOException("The anchored application did not start.");
                            result.RestartedPid = started.Id;
                            result.RestartedStartTimeUtcTicks = started.StartTime.ToUniversalTime().Ticks;
                            started.Dispose();
                        }
                        finally { foreach (var lease in leases) lease.Dispose(); }
                        journal.Record("succeeded");
                    }
                    ResultFile(plan, result);
                    return result;
                }
                catch (Exception error)
                {
                    journal.TryRecord("failed", error.GetType().Name + ": " + error.Message);
                    var result = new UpdateResult { State = journal.MutationStarted ? "failed_manual_recovery" : "failed_before_apply",
                        Succeeded = false, RollbackComplete = !journal.MutationStarted };
                    try { ResultFile(plan, result); } catch (IOException) { /* Recovery material is still retained; never restart after failure. */ }
                    return result;
                }
            }
        }

        private static ParentProcessLease VerifiedParent(UpdatePlan plan) { return ParentProcessLease.Open(plan); }
        private static void CheckCancelled(UpdatePlan plan)
        { UpdateAuthorization.ThrowIfCancelled(plan); }
        private static void ResultFile(UpdatePlan plan, UpdateResult result)
        {
            SafeFiles.NewJson(plan.JobRoot, "result.json", new Dictionary<string, object>
            {
                { "schemaVersion", 1 }, { "candidate", true }, { "state", result.State }, { "succeeded", result.Succeeded },
                { "rollbackComplete", result.RollbackComplete }, { "runtimeFamily", "wpf_legacy" },
                { "architecture", plan.Architecture }, { "version", plan.Version }, { "buildNumber", plan.BuildNumber },
                { "restartedPid", result.RestartedPid }, { "restartedStartTimeUtcTicks", result.RestartedStartTimeUtcTicks },
                { "recoveryDirectory", plan.JobRoot }, { "updaterPid", Process.GetCurrentProcess().Id }
            });
        }

        // Tests use only randomly created local fixture directories and never invoke Execute/Process.Start.
        internal static UpdateResult ApplyForChecks(UpdatePlan plan, PreparedUpdate prepared, Action<int> afterFile = null)
        {
            using (SafeFiles.GuardDirectories(plan.AppRoot, plan.JobRoot))
            using (var journal = new Journal(plan.JobRoot)) return ApplyPrepared(plan, prepared, journal, afterFile);
        }

        private static UpdateResult ApplyPrepared(UpdatePlan plan, PreparedUpdate prepared, Journal journal, Action<int> afterFile)
        {
            var locked = new Dictionary<string, FileStream>(StringComparer.Ordinal);
            var changed = new List<string>();
            var backup = SafeFiles.Child(plan.JobRoot, "backup");
            try
            {
                CheckCancelled(plan);
                UpdateAuthorization.Require(plan);
                // Pin every current file exclusively before making any backup or mutation.
                // A process that already has a conflicting handle makes the entire operation fail.
                foreach (var name in UpdateContract.ApprovedFiles)
                {
                    var file = SafeFiles.Open(SafeFiles.Child(plan.AppRoot, name), FileAccess.ReadWrite);
                    locked.Add(name, file);
                    var original = plan.OriginalFiles[name];
                    if (file.Length != original.Size || SafeFiles.Hash(file) != original.Sha256)
                        throw new IOException("Concurrent installed-file change detected; nothing is overwritten.");
                }
                if (Directory.Exists(backup) || File.Exists(backup)) throw new IOException("Recovery directory already exists.");
                var backupBytes = plan.OriginalFiles.Values.Sum(file => file.Size);
                var growth = prepared.Files.Sum(file => Math.Max(0, file.Size - plan.OriginalFiles[file.Name].Size));
                var sameDrive = String.Equals(Path.GetPathRoot(plan.AppRoot), Path.GetPathRoot(plan.JobRoot), StringComparison.OrdinalIgnoreCase);
                if (new DriveInfo(Path.GetPathRoot(plan.JobRoot)).AvailableFreeSpace < backupBytes + (sameDrive ? growth : 0) + 16L * 1024 * 1024
                    || !sameDrive && new DriveInfo(Path.GetPathRoot(plan.AppRoot)).AvailableFreeSpace < growth + 16L * 1024 * 1024)
                    throw new IOException("Insufficient free space for complete recovery material.");
                Directory.CreateDirectory(backup);
                using (SafeFiles.GuardDirectories(backup, prepared.StageRoot))
                {
                    foreach (var name in UpdateContract.ApprovedFiles)
                    {
                        var original = plan.OriginalFiles[name]; var file = locked[name]; file.Position = 0;
                        using (var output = SafeFiles.Open(SafeFiles.Child(backup, name), FileAccess.ReadWrite, true))
                        {
                            if (SafeFiles.Copy(file, output, original.Size) != original.Size || SafeFiles.Hash(output) != original.Sha256)
                                throw new IOException("Recovery copy verification failed.");
                            output.Flush(true);
                        }
                    }
                    journal.Record("all_backups_verified");
                    // This record survives an interrupted process and binds every retained
                    // backup to the package and anchored installation. It is recovery
                    // evidence, not a claim of an atomic/power-loss-safe transaction.
                    SafeFiles.NewJson(plan.JobRoot, "recovery-manifest.json", new Dictionary<string, object>
                    {
                        { "schemaVersion", 1 }, { "runtimeFamily", "wpf_legacy" }, { "architecture", plan.Architecture },
                        { "appRoot", plan.AppRoot }, { "packageSha256", plan.Sha256 }, { "packageSizeBytes", plan.SizeBytes },
                        { "originalVersion", plan.CurrentVersion }, { "originalBuildNumber", plan.CurrentBuild },
                        { "version", plan.Version }, { "buildNumber", plan.BuildNumber },
                        { "files", prepared.Files.Select(record => (object)new Dictionary<string, object>
                            {
                                { "path", record.Name }, { "originalSize", plan.OriginalFiles[record.Name].Size },
                                { "originalSha256", plan.OriginalFiles[record.Name].Sha256 },
                                { "targetSize", record.Size }, { "targetSha256", record.Sha256 }
                            }).ToArray() }
                    });
                    try
                    {
                        var index = 0;
                        foreach (var record in prepared.Files)
                        {
                            CheckCancelled(plan);
                            UpdateAuthorization.Require(plan);
                            using (var source = SafeFiles.Open(SafeFiles.Child(prepared.StageRoot, record.Name), FileAccess.Read))
                            {
                                if (source.Length != record.Size || SafeFiles.Hash(source) != record.Sha256) throw new IOException("Prepared file changed.");
                                journal.Record("applying", record.Name);
                                journal.MutationStarted = true;
                                changed.Add(record.Name); // Includes an interrupted write to this file.
                                Rewrite(source, locked[record.Name], record.Size, record.Sha256);
                            }
                            journal.Record("applied", record.Name);
                            if (afterFile != null) afterFile(++index);
                        }
                        UpdateAuthorization.Require(plan);
                        journal.Record("all_installed_hashes_verified");
                        return new UpdateResult { Succeeded = true, RollbackComplete = false, State = "succeeded" };
                    }
                    catch (Exception error)
                    {
                        journal.TryRecord("rolling_back", error.GetType().Name);
                        var complete = true;
                        foreach (var name in changed.AsEnumerable().Reverse())
                        {
                            try
                            {
                                var original = plan.OriginalFiles[name];
                                using (var source = SafeFiles.Open(SafeFiles.Child(backup, name), FileAccess.Read))
                                {
                                    if (source.Length != original.Size || SafeFiles.Hash(source) != original.Sha256) throw new IOException("Recovery copy changed.");
                                    Rewrite(source, locked[name], original.Size, original.Sha256);
                                }
                                journal.TryRecord("restored", name);
                            }
                            catch (Exception recoveryError) { complete = false; journal.TryRecord("manual_recovery_required", recoveryError.GetType().Name); }
                        }
                        foreach (var pair in locked)
                        {
                            var original = plan.OriginalFiles[pair.Key];
                            if (pair.Value.Length != original.Size || SafeFiles.Hash(pair.Value) != original.Sha256) complete = false;
                        }
                        return new UpdateResult { State = complete ? "failed_rolled_back" : "failed_manual_recovery", RollbackComplete = complete };
                    }
                }
            }
            finally { foreach (var file in locked.Values) file.Dispose(); }
        }
        private static void Rewrite(FileStream source, FileStream target, long size, string sha256)
        {
            source.Position = target.Position = 0; target.SetLength(size);
            if (SafeFiles.Copy(source, target, size) != size) throw new IOException("Approved file write was incomplete.");
            target.Flush(true);
            if (target.Length != size || SafeFiles.Hash(target) != sha256) throw new IOException("Installed file verification failed.");
        }
        private sealed class Journal : IDisposable
        {
            private readonly FileStream file;
            internal bool MutationStarted;
            internal Journal(string root) { file = SafeFiles.Open(SafeFiles.Child(root, "update.log"), FileAccess.ReadWrite, true); }
            internal void Record(string phase, string subject = null)
            {
                var bytes = StrictJson.Write(new Dictionary<string, object> { { "utc", DateTime.UtcNow.ToString("o") }, { "phase", phase }, { "subject", subject } });
                file.Write(bytes, 0, bytes.Length); file.WriteByte(10); file.Flush(true);
            }
            internal void TryRecord(string phase, string subject = null)
            { try { Record(phase, subject); } catch (IOException) { } }
            public void Dispose() { file.Dispose(); }
        }
    }
}
