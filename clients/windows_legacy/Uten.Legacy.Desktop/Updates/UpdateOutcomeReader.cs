using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;

namespace Uten.Legacy.Desktop.Updates
{
    public sealed class StartupUpdateOutcome
    {
        public string State { get; internal set; }
        public bool Succeeded { get; internal set; }
        public bool RollbackComplete { get; internal set; }
        public string Version { get; internal set; }
        public int BuildNumber { get; internal set; }
        public string JobDirectory { get; internal set; }
        public int RestartedPid { get; internal set; }
        // Interrupted updates only: a recovery manifest proves the mutation phase had begun.
        public bool MutationMayHaveStarted { get; internal set; }
        // Build anchor: the running build compared with the outcome's own build fact.
        public bool BuildAnchorMatches { get; internal set; }

        public string DisplayText()
        {
            string recovery = "恢复资料目录（请勿删除）：" + JobDirectory;
            switch (State)
            {
                case "succeeded":
                    return "软件已更新到 " + Version + "（内部版本 " + BuildNumber.ToString(CultureInfo.InvariantCulture) + "）。"
                        + (BuildAnchorMatches ? "" : "注意：当前运行的内部版本与更新记录不一致，请人工核对。")
                        + " 更新前的完整备份与记录保留在本机：" + JobDirectory + "。如发现问题请联系管理员。";
                case "failed_rolled_back":
                    return "上次更新未完成，已自动恢复原有文件，当前版本保持不变。" + recovery + "。可稍后重试更新或使用完整安装包。";
                case "failed_manual_recovery":
                    return "上次更新失败且未能完全自动恢复，需要人工核对。请暂停使用软件更新功能并联系管理员。" + recovery + "。";
                case "failed_before_apply":
                    return "上次更新在预检或等待退出阶段停止，没有修改任何程序文件，当前版本保持不变。任务目录：" + JobDirectory + "。";
                case "interrupted":
                    return MutationMayHaveStarted
                        ? "上次更新在写入文件阶段被中断（可能断电或强制关机），可能已写入部分文件。必须联系管理员按恢复资料核对后才能继续使用更新。" + recovery + "。"
                        : "上次更新在开始写入文件前被中断，没有修改任何程序文件。任务目录：" + JobDirectory + "。可重新检查更新。";
                default:
                    return "发现无法核对的更新结果记录（状态：" + (State ?? "未知") + "），需人工核对。" + recovery + "。";
            }
        }
    }

    /// <summary>Consumes the private update job's final result on client startup.
    /// Result and recovery material are only ever read and marked here, never deleted:
    /// retention and cleanup belong to the owning update policy, not to this reader.</summary>
    public sealed class UpdateOutcomeReader
    {
        private const int ResultLimitBytes = 16384;
        private readonly string jobsRoot;
        public UpdateOutcomeReader() : this(DefaultJobsRoot()) { }
        internal UpdateOutcomeReader(string jobsRoot)
        {
            this.jobsRoot = Path.GetFullPath(jobsRoot ?? throw new ArgumentNullException(nameof(jobsRoot)));
        }
        internal static string DefaultJobsRoot()
        {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Uten", "UIMP-Win7-WPF", "client-updates");
        }

        /// <summary>Newest not-yet-consumed outcome, or null. A consumed marker only records
        /// that the fact was shown; it never removes result.json, instruction.json or backups.</summary>
        public StartupUpdateOutcome ReadFirstPending()
        {
            ClientUpdateCoordinator.RejectLinks(jobsRoot);
            if (!Directory.Exists(jobsRoot)) return null;
            StartupUpdateOutcome best = null; long bestStamp = long.MinValue;
            foreach (string directory in Directory.GetDirectories(jobsRoot))
            {
                ClientUpdateCoordinator.RejectLinks(directory);
                Guid id;
                if (!Guid.TryParseExact(Path.GetFileName(directory), "D", out id)) continue;
                long stamp;
                try { stamp = new DirectoryInfo(directory).CreationTimeUtc.Ticks; }
                catch (IOException) { continue; }
                StartupUpdateOutcome outcome;
                try { outcome = ReadJob(directory); }
                catch (Exception error) when (error is IOException || error is UnauthorizedAccessException)
                { continue; }
                if (outcome == null) continue;
                if (best == null || stamp > bestStamp) { best = outcome; bestStamp = stamp; }
            }
            return best;
        }

        private static StartupUpdateOutcome ReadJob(string directory)
        {
            string result = Path.Combine(directory, "result.json");
            bool consumed = File.Exists(Path.Combine(directory, "result-consumed.json"));
            if (File.Exists(result)) return consumed ? null : ReadResult(directory, result);
            // apply-authorized without any result: the helper was cleared to mutate but the
            /// journal never reached a final state (power loss or forced termination).
            if (File.Exists(Path.Combine(directory, "apply-authorized.json"))
                && File.Exists(Path.Combine(directory, "instruction.json")) && !consumed)
            {
                return new StartupUpdateOutcome
                {
                    State = "interrupted",
                    MutationMayHaveStarted = File.Exists(Path.Combine(directory, "recovery-manifest.json")),
                    JobDirectory = directory,
                    BuildNumber = ClientUpdateCoordinator.CurrentBuild,
                    BuildAnchorMatches = true
                };
            }
            return null;
        }

        private static StartupUpdateOutcome ReadResult(string directory, string resultPath)
        {
            var outcome = new StartupUpdateOutcome { JobDirectory = directory };
            var root = ReadBounded(resultPath);
            if (root == null)
            { outcome.State = "unreadable_result"; return outcome; }
            object raw; string state = Text(root, "state"); object family, architecture;
            bool validFamily = root.TryGetValue("runtimeFamily", out family) && family as string == "wpf_legacy";
            bool validArchitecture = root.TryGetValue("architecture", out architecture)
                && architecture as string == ClientUpdateCoordinator.Architecture;
            outcome.Succeeded = root.TryGetValue("succeeded", out raw) && raw is bool && (bool)raw;
            outcome.RollbackComplete = root.TryGetValue("rollbackComplete", out raw) && raw is bool && (bool)raw;
            outcome.Version = Text(root, "version");
            outcome.BuildNumber = (int)Number(root, "buildNumber");
            outcome.RestartedPid = (int)Number(root, "restartedPid");
            outcome.BuildAnchorMatches = outcome.Succeeded && outcome.BuildNumber == ClientUpdateCoordinator.CurrentBuild;
            if (state != "succeeded" && state != "failed_rolled_back" && state != "failed_manual_recovery"
                && state != "failed_before_apply" || !validFamily || !validArchitecture || Number(root, "schemaVersion") != 1)
            { outcome.State = "unreadable_result"; return outcome; }
            outcome.State = state;
            return outcome;
        }

        private static Dictionary<string, object> ReadBounded(string path)
        {
            if (new FileInfo(path).Length > ResultLimitBytes) return null;
            var parsed = new JavaScriptSerializer { MaxJsonLength = ResultLimitBytes, RecursionLimit = 16 }
                .DeserializeObject(File.ReadAllText(path, Encoding.UTF8)) as Dictionary<string, object>;
            return parsed;
        }
        private static string Text(Dictionary<string, object> value, string key)
        { object raw; return value.TryGetValue(key, out raw) ? raw as string : null; }
        private static long Number(Dictionary<string, object> value, string key)
        {
            object raw;
            if (!value.TryGetValue(key, out raw) || !(raw is int || raw is long)) return -1;
            return Convert.ToInt64(raw, CultureInfo.InvariantCulture);
        }

        public void MarkConsumed(StartupUpdateOutcome outcome)
        {
            if (outcome == null) throw new ArgumentNullException(nameof(outcome));
            string directory = Path.GetFullPath(outcome.JobDirectory);
            if (!Guid.TryParseExact(Path.GetFileName(directory), "D", out Guid id)
                || !String.Equals(Path.GetDirectoryName(directory), Path.GetFullPath(jobsRoot), StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("更新结果不属于当前客户端的私有任务目录。");
            ClientUpdateCoordinator.RejectLinks(directory);
            string marker = Path.Combine(directory, "result-consumed.json");
            if (File.Exists(marker)) return;
            var body = Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(new Dictionary<string, object>
            {
                { "schemaVersion", 1 }, { "state", "consumed" }, { "consumedAtUtc", DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) },
                { "outcomeState", outcome.State }, { "consumingPid", System.Diagnostics.Process.GetCurrentProcess().Id }
            }));
            if (body.Length > ResultLimitBytes) throw new InvalidDataException("更新结果标记超出大小限制。");
            string temporary = Path.Combine(directory, ".pending-" + Guid.NewGuid().ToString("N") + ".tmp");
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            { output.Write(body, 0, body.Length); output.Flush(true); }
            ClientUpdateCoordinator.RejectLinks(temporary);
            try { File.Move(temporary, marker); }
            catch (IOException) { File.Delete(temporary); if (File.Exists(marker)) return; throw; }
        }
    }
}
