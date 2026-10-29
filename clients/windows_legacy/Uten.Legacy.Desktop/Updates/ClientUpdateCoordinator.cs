using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Features.Downloads;

[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("Uten.Legacy.Tests")]

namespace Uten.Legacy.Desktop.Updates
{
    /// <summary>Only prepares this installed WPF runtime's verified update.
    /// Exiting the application remains a user action after the helper is ready.</summary>
    public sealed class ClientUpdateCoordinator
    {
        private readonly SessionCoordinator session;
        public static string Architecture { get { return Environment.Is64BitProcess ? "x64" : "x86"; } }
        public static int CurrentBuild { get { return InstalledVersion().FilePrivatePart; } }
        public ClientUpdateCoordinator(SessionCoordinator session) { this.session = session ?? throw new ArgumentNullException(nameof(session)); }

        public async Task<ClientPackageDescriptor> CheckAsync(CancellationToken cancellationToken)
        {
            string json = await session.GetAsync("/client-updates/check?platform=windows&architecture=" + Architecture
                + "&currentBuildNumber=" + CurrentBuild.ToString(CultureInfo.InvariantCulture) + "&runtimeFamily=wpf_legacy", cancellationToken);
            var root = new JavaScriptSerializer { MaxJsonLength = 2097152 }.DeserializeObject(json) as Dictionary<string, object>;
            object available, raw;
            if (root == null || !root.TryGetValue("updateAvailable", out available) || !(available is bool))
                throw new ApiException("INVALID_UPDATE_RESPONSE", "更新信息无法验证，请稍后重试。");
            if (!(bool)available) return null;
            if (!root.TryGetValue("release", out raw) || !(raw is Dictionary<string, object>))
                throw new ApiException("INVALID_UPDATE_RESPONSE", "更新信息无法验证，请稍后重试。");
            var candidate = ClientPackageDescriptor.Parse((Dictionary<string, object>)raw);
            if (!candidate.IsUpdateFor("wpf_legacy", Architecture, CurrentBuild))
                throw new ApiException("UPDATE_TARGET_MISMATCH", "该更新不适用于当前 Win7 兼容客户端。");
            return candidate;
        }

        public async Task<PreparedUpdate> PrepareAsync(ClientPackageDescriptor release, CancellationToken cancellationToken,
            IProgress<long> progress = null)
        {
            if (release == null || !release.IsUpdateFor("wpf_legacy", Architecture, CurrentBuild))
                throw new ApiException("UPDATE_TARGET_MISMATCH", "该更新不适用于当前 Win7 兼容客户端。");
            long generation = session.Generation;
            string applicationRoot = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            string helper = Path.Combine(applicationRoot, "client_updater", "Uten.Legacy.Updater.exe");
            RejectLinks(helper);
            if (!File.Exists(helper))
                throw new ApiException("UPDATE_BOOTSTRAP_REQUIRED", "此客户端尚未安装原生更新组件，请使用对应版本的完整安装包。");
            string jobs = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Uten", "UIMP-Win7-WPF", "client-updates");
            RejectLinks(jobs);
            string job = Path.Combine(jobs, Guid.NewGuid().ToString("D"));
            PreparedUpdate pending = null;
            Process child = null;
            bool transferred = false;
            try
            {
                Directory.CreateDirectory(job);
                RejectLinks(job);
                string archive = Path.Combine(job, "package.zip");
                int parentPid; long parentStart;
                using (var parent = Process.GetCurrentProcess())
                { parentPid = parent.Id; parentStart = parent.StartTime.ToUniversalTime().Ticks; }
                pending = new PreparedUpdate(job, release.Sha256, release.SizeBytes, release.Version,
                    release.BuildNumber, Architecture, parentPid, parentStart, cancellationToken,
                    () => session.IsAuthenticated && session.Generation == generation,
                    () => UpdateJobFiles.RequireJob(job));
                await session.DownloadClientPackageAsync(release.Id, release.Sha256, release.SizeBytes,
                    release.RuntimeFamily, archive, cancellationToken, progress);
                pending.RequireCurrent();
                var instruction = new Dictionary<string, object>
                {
                    { "schemaVersion", 1 }, { "packagePath", archive }, { "sha256", release.Sha256 },
                    { "sizeBytes", release.SizeBytes }, { "version", release.Version }, { "buildNumber", release.BuildNumber },
                    { "architecture", Architecture }, { "runtimeFamily", "wpf_legacy" },
                    { "parentPid", parentPid }, { "parentStartTimeUtcTicks", parentStart }
                };
                string instructionPath = Path.Combine(job, "instruction.json");
                UpdateJobFiles.AtomicJson(job, "instruction.json", instruction, pending.RequireCurrent);
                pending.RequireCurrent();
                child = Process.Start(new ProcessStartInfo(helper, "\"" + instructionPath + "\"")
                { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = applicationRoot });
                if (child == null) throw new ApiException("UPDATE_HELPER_FAILED", "更新组件未能启动，当前版本保持运行。");
                pending.BindHelper(child, helper);
                string readyPath = Path.Combine(job, "ready.json");
                var clock = Stopwatch.StartNew();
                while (clock.Elapsed < TimeSpan.FromSeconds(15))
                {
                    pending.RequireCurrent();
                    if (child.HasExited) throw new ApiException("UPDATE_HELPER_FAILED", "更新预检未通过，当前版本保持运行。");
                    if (File.Exists(readyPath))
                    {
                        RejectLinks(readyPath);
                        if (new FileInfo(readyPath).Length > 16384) break;
                        var ready = new JavaScriptSerializer { MaxJsonLength = 16384, RecursionLimit = 16 }
                            .DeserializeObject(File.ReadAllText(readyPath, Encoding.UTF8)) as Dictionary<string, object>;
                        if (ready != null && Number(ready, "schemaVersion") == 1 && Text(ready, "state") == "ready"
                            && Number(ready, "parentPid") == parentPid
                            && Number(ready, "parentStartTimeUtcTicks") == parentStart
                            && Number(ready, "updaterPid") == child.Id)
                        { pending.MarkReady(); transferred = true; return pending; }
                        break;
                    }
                    await Task.Delay(100, cancellationToken);
                }
                throw new ApiException("UPDATE_HELPER_NOT_READY", "更新组件未能完成预检，当前版本保持运行。");
            }
            finally
            {
                if (child != null) child.Dispose();
                // No returned ready capability means no consent, even if this parent later
                // exits normally. The helper also independently requires apply-authorized.json.
                if (!transferred && Directory.Exists(job))
                {
                    if (pending != null) pending.Cancel();
                    else UpdateJobFiles.Cancel(job);
                }
            }
        }

        private static FileVersionInfo InstalledVersion() { return FileVersionInfo.GetVersionInfo(Assembly.GetExecutingAssembly().Location); }
        private static string Text(Dictionary<string, object> value, string key) { object raw; return value.TryGetValue(key, out raw) ? raw as string : null; }
        private static long Number(Dictionary<string, object> value, string key)
        { object raw; return value.TryGetValue(key, out raw) && (raw is int || raw is long) ? Convert.ToInt64(raw) : -1; }
        internal static void RejectLinks(string path)
        {
            for (string current = Path.GetFullPath(path); !string.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
            {
                if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new ApiException("UPDATE_LINKED_PATH", "更新目录不能使用链接或重解析路径。");
                string parent = Path.GetDirectoryName(current);
                if (string.Equals(parent, current, StringComparison.OrdinalIgnoreCase)) break;
            }
        }
    }

    /// <summary>Ready is preparation only. The caller must explicitly authorize the final normal shutdown.</summary>
    public sealed class PreparedUpdate : IDisposable
    {
        private enum CapabilityState { Pending, Authorized, Cancelled }
        private readonly object gate = new object();
        private readonly string packageSha256, version, architecture;
        private readonly long packageSizeBytes, parentStart;
        private readonly int buildNumber, parentPid;
        private readonly CancellationToken cancellation;
        private readonly Func<bool> ownsSession;
        private readonly Action requireJob;
        private CancellationTokenRegistration registration;
        private CapabilityState state;
        private bool ready, detached;
        private Action verifyHelper;
        public string JobDirectory { get; private set; }
        public int HelperPid { get; private set; }
        public bool IsAuthorized { get { lock (gate) return state == CapabilityState.Authorized; } }

        internal PreparedUpdate(string jobDirectory, string packageSha256, long packageSizeBytes, string version,
            int buildNumber, string architecture, int parentPid, long parentStart, CancellationToken cancellation,
            Func<bool> ownsSession, Action requireJob)
        {
            JobDirectory = jobDirectory; this.packageSha256 = packageSha256; this.packageSizeBytes = packageSizeBytes;
            this.version = version; this.buildNumber = buildNumber; this.architecture = architecture;
            this.parentPid = parentPid; this.parentStart = parentStart; this.cancellation = cancellation;
            this.ownsSession = ownsSession; this.requireJob = requireJob;
            registration = cancellation.Register(CancelFromToken);
        }
        internal void BindHelper(Process process, string expectedPath)
        {
            int id = process.Id; long ticks = process.StartTime.ToUniversalTime().Ticks;
            HelperPid = id;
            verifyHelper = () =>
            {
                using (var helper = Process.GetProcessById(id))
                    if (helper.HasExited || helper.StartTime.ToUniversalTime().Ticks != ticks
                        || !String.Equals(Path.GetFullPath(helper.MainModule.FileName), Path.GetFullPath(expectedPath), StringComparison.OrdinalIgnoreCase))
                        throw new ApiException("UPDATE_HELPER_NOT_READY", "更新组件已变化或退出，当前客户端不会退出。");
            };
        }
        internal void MarkReady() { RequireCurrent(); lock (gate) ready = true; }
        internal void RequireCurrent()
        {
            lock (gate)
            {
                if (state == CapabilityState.Cancelled || cancellation.IsCancellationRequested)
                    throw new OperationCanceledException(cancellation);
                if (!ownsSession()) throw new ApiException("SESSION_CHANGED", "账号或服务器已变化，当前客户端不会退出。");
                requireJob();
                if (File.Exists(Path.Combine(JobDirectory, "cancel.flag")) || Directory.Exists(Path.Combine(JobDirectory, "cancel.flag")))
                    throw new OperationCanceledException("更新任务已取消。");
            }
        }
        public void AuthorizeShutdown()
        {
            try
            {
                lock (gate)
                {
                    if (state == CapabilityState.Authorized) return;
                    RequireCurrent();
                    if (!ready || verifyHelper == null) throw new ApiException("UPDATE_HELPER_NOT_READY", "更新预检尚未完成，当前客户端不会退出。");
                    verifyHelper();
                    var consent = new Dictionary<string, object>
                    {
                        { "schemaVersion", 1 }, { "state", "apply_authorized" }, { "runtimeFamily", "wpf_legacy" },
                        { "architecture", architecture }, { "packageSha256", packageSha256 }, { "packageSizeBytes", packageSizeBytes },
                        { "version", version }, { "buildNumber", buildNumber }, { "parentPid", parentPid },
                        { "parentStartTimeUtcTicks", parentStart }, { "updaterPid", HelperPid }
                    };
                    // Check ownership around the atomic publication. A change during IO
                    // persists a dominating cancel marker before this capability can return.
                    UpdateJobFiles.AtomicJson(JobDirectory, "apply-authorized.json", consent, RequireCurrent);
                    RequireCurrent();
                    state = CapabilityState.Authorized;
                }
            }
            catch { Cancel(); throw; }
            finally { DetachCancellation(); }
        }
        public void Cancel()
        {
            try
            {
                lock (gate)
                {
                    state = CapabilityState.Cancelled;
                    requireJob(); UpdateJobFiles.Cancel(JobDirectory);
                }
            }
            finally { DetachCancellation(); }
        }
        private void CancelFromToken()
        {
            lock (gate)
            {
                if (state != CapabilityState.Pending) return; // Confirmed AppShutdown is not cancellation.
                state = CapabilityState.Cancelled;
                try { requireJob(); UpdateJobFiles.Cancel(JobDirectory); }
                catch (Exception error) when (error is IOException || error is UnauthorizedAccessException || error is ApiException)
                { /* Consent was never published; missing/failed cancel IO cannot authorize application. */ }
            }
        }
        private void DetachCancellation()
        {
            CancellationTokenRegistration held;
            lock (gate) { if (detached) return; detached = true; held = registration; }
            // Dispose outside gate: an in-flight callback may be waiting for it.
            held.Dispose();
        }
        public void Dispose() { if (!IsAuthorized) Cancel(); else DetachCancellation(); }

        internal void SetReadyForChecks(int helperPid)
        { HelperPid = helperPid; verifyHelper = () => { }; MarkReady(); }
    }

    internal static class UpdateJobFiles
    {
        internal static void RequireJob(string job)
        {
            var parent = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Uten", "UIMP-Win7-WPF", "client-updates");
            Guid id;
            if (!Guid.TryParse(Path.GetFileName(job), out id)
                || !String.Equals(Path.GetDirectoryName(Path.GetFullPath(job)), Path.GetFullPath(parent), StringComparison.OrdinalIgnoreCase))
                throw new ApiException("UPDATE_JOB_PATH", "更新任务不属于当前兼容客户端的私有目录。");
            ClientUpdateCoordinator.RejectLinks(job);
        }
        internal static void Cancel(string job)
        {
            ClientUpdateCoordinator.RejectLinks(job);
            var path = Path.Combine(job, "cancel.flag");
            if (File.Exists(path) || Directory.Exists(path)) return;
            AtomicJson(job, "cancel.flag", new Dictionary<string, object> { { "schemaVersion", 1 }, { "state", "cancelled" } });
        }
        internal static void AtomicJson(string job, string leaf, object value, Action beforeCommit = null)
        {
            if (leaf != "instruction.json" && leaf != "cancel.flag" && leaf != "apply-authorized.json")
                throw new InvalidOperationException("Unapproved private job leaf.");
            ClientUpdateCoordinator.RejectLinks(job);
            string target = Path.Combine(job, leaf), temporary = Path.Combine(job, ".pending-" + Guid.NewGuid().ToString("N") + ".tmp");
            var bytes = Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(value));
            if (bytes.Length > 16384) throw new InvalidDataException("更新指令超出大小限制。");
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            { output.Write(bytes, 0, bytes.Length); output.Flush(true); }
            if (beforeCommit != null) beforeCommit();
            ClientUpdateCoordinator.RejectLinks(temporary); ClientUpdateCoordinator.RejectLinks(target);
            if (File.Exists(target) || Directory.Exists(target)) throw new IOException("更新任务状态已存在，不能覆盖。");
            // Both fixed leaves are in this same previously validated GUID job. No directory move.
            File.Move(temporary, target);
        }
    }
}
