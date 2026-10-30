using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

namespace Uten.Legacy.Desktop.Updates
{
    // Executed by the offline console test project, never by application startup.
    public static class UpdateOutcomeContractChecks
    {
        public static int Run()
        {
            int assertions = 0;
            Action<bool, string> check = (condition, message) =>
            {
                if (!condition) throw new InvalidOperationException("Update outcome: " + message);
                assertions++;
            };
            string root = Path.Combine(Path.GetTempPath(), "uten-update-outcome-" + Guid.NewGuid().ToString("N"));
            try
            {
                var reader = new UpdateOutcomeReader(root);
                check(reader.ReadFirstPending() == null, "no jobs yields no outcome and no failure");

                string succeededJob = Job(root, 1);
                WriteResult(succeededJob, State(succeededJob));
                string interruptedSafe = Job(root, 2);
                File.WriteAllText(Path.Combine(interruptedSafe, "instruction.json"), "{}");
                File.WriteAllText(Path.Combine(interruptedSafe, "apply-authorized.json"), "{}");
                string failed = Job(root, 3);
                WriteResult(failed, State(failed, succeeded: false, rollback: false, state: "failed_manual_recovery"));
                Directory.SetCreationTimeUtc(succeededJob, new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc));
                Directory.SetCreationTimeUtc(interruptedSafe, new DateTime(2026, 1, 2, 0, 0, 0, DateTimeKind.Utc));
                Directory.SetCreationTimeUtc(failed, new DateTime(2026, 1, 3, 0, 0, 0, DateTimeKind.Utc));

                var newest = reader.ReadFirstPending();
                check(newest.State == "failed_manual_recovery" && newest.JobDirectory == failed
                    && !newest.Succeeded && !newest.RollbackComplete, "newest unconsumed result is surfaced first");
                check(newest.DisplayText().Contains("人工核对") && newest.DisplayText().Contains(failed),
                    "manual-recovery message names the real recovery path in words");
                reader.MarkConsumed(newest);
                check(File.Exists(Path.Combine(failed, "result-consumed.json")) && File.Exists(Path.Combine(failed, "result.json")),
                    "consumption marks the fact without deleting the result or recovery material");

                var interrupted = reader.ReadFirstPending();
                check(interrupted.State == "interrupted" && !interrupted.MutationMayHaveStarted,
                    "authorized job without result reports interruption before any file mutation");
                check(interrupted.DisplayText().Contains("没有修改任何程序文件"), "pre-mutation interruption keeps its honest no-change fact");
                // A recovery manifest proves the mutation phase had begun: the warning must escalate
                // while the outcome is still unconsumed.
                File.WriteAllText(Path.Combine(interruptedSafe, "recovery-manifest.json"), "{}");
                var escalated = new UpdateOutcomeReader(root).ReadFirstPending();
                check(escalated.State == "interrupted" && escalated.MutationMayHaveStarted
                    && escalated.DisplayText().Contains("可能已写入部分文件"), "mutation-phase interruption escalates to manual verification");
                new UpdateOutcomeReader(root).MarkConsumed(escalated);

                // The newest job is consumed, so the older succeeded job comes next.
                var consumedOutcome = new UpdateOutcomeReader(root).ReadFirstPending();
                check(consumedOutcome.State == "succeeded" && consumedOutcome.JobDirectory == succeededJob,
                    "consumed outcomes are skipped and older pending facts still surface");
                check(consumedOutcome.BuildAnchorMatches == (consumedOutcome.BuildNumber == ClientUpdateCoordinator.CurrentBuild),
                    "success anchors the running build against the recorded update build");

                string foreign = Job(root, 4);
                Directory.SetCreationTimeUtc(foreign, new DateTime(2026, 1, 4, 0, 0, 0, DateTimeKind.Utc));
                WriteResult(foreign, State(foreign).Replace("wpf_legacy", "flutter"));
                check(new UpdateOutcomeReader(root).ReadFirstPending().State == "unreadable_result",
                    "foreign runtime family result is never presented as this client's outcome");

                string oversized = Job(root, 5);
                Directory.SetCreationTimeUtc(oversized, new DateTime(2026, 1, 5, 0, 0, 0, DateTimeKind.Utc));
                File.WriteAllText(Path.Combine(oversized, "result.json"), new string('x', 16385));
                check(new UpdateOutcomeReader(root).ReadFirstPending().State == "unreadable_result",
                    "oversized result stays an unreadable fact instead of being parsed or ignored");

                string ignored = Path.Combine(root, "not-a-guid");
                Directory.CreateDirectory(ignored);
                File.WriteAllText(Path.Combine(ignored, "result.json"), "{}");
                Directory.SetCreationTimeUtc(ignored, new DateTime(2026, 1, 6, 0, 0, 0, DateTimeKind.Utc));
                check(new UpdateOutcomeReader(root).ReadFirstPending().State == "unreadable_result",
                    "non-GUID job directories never participate in outcome consumption");

                ExpectFailure(() => new UpdateOutcomeReader(root).MarkConsumed(
                    new StartupUpdateOutcome { State = "succeeded", JobDirectory = ignored }),
                    check, "consumption marker refuses directories outside the GUID job root");
            }
            finally
            {
                try { Directory.Delete(root, true); } catch (IOException) { }
            }
            return assertions;
        }

        private static string Job(string root, int index)
        {
            string id = new Guid(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, (byte)index).ToString("D", CultureInfo.InvariantCulture);
            string directory = Path.Combine(root, id);
            Directory.CreateDirectory(directory);
            return directory;
        }
        private static void WriteResult(string job, string json)
        {
            File.WriteAllText(Path.Combine(job, "result.json"), json);
        }
        private static string State(string job, bool succeeded = true, bool rollback = false, string state = "succeeded",
            int build = 2599, int pid = 4242)
        {
            return "{\"schemaVersion\":1,\"candidate\":true,\"state\":\"" + state + "\",\"succeeded\":" + (succeeded ? "true" : "false")
                + ",\"rollbackComplete\":" + (rollback ? "true" : "false") + ",\"runtimeFamily\":\"wpf_legacy\""
                + ",\"architecture\":\"" + ClientUpdateCoordinator.Architecture + "\",\"version\":\"2.5.99\",\"buildNumber\":" + build
                + ",\"restartedPid\":" + pid + ",\"restartedStartTimeUtcTicks\":1,\"recoveryDirectory\":\"" + job.Replace("\\", "\\\\")
                + "\",\"updaterPid\":99}";
        }
        private static void ExpectFailure(Action action, Action<bool, string> check, string message)
        {
            bool rejected = false;
            try { action(); }
            catch (InvalidOperationException) { rejected = true; }
            catch (IOException) { rejected = true; }
            check(rejected, message);
        }
    }
}
