using System;
using System.Diagnostics;
using System.IO;

namespace Uten.Legacy.Updater
{
    /// <summary>A normal parent exit is not update consent. Cancellation always dominates consent.</summary>
    internal static class UpdateAuthorization
    {
        internal static void ThrowIfCancelled(UpdatePlan plan)
        {
            var marker = SafeFiles.Child(plan.JobRoot, "cancel.flag");
            if (File.Exists(marker) || Directory.Exists(marker))
                throw new OperationCanceledException("The private update job was cancelled.");
        }

        internal static void Require(UpdatePlan plan)
        {
            ThrowIfCancelled(plan);
            var path = SafeFiles.Child(plan.JobRoot, "apply-authorized.json");
            var value = StrictJson.Read(SafeFiles.Bytes(path, 16384));
            StrictJson.Keys(value, new[] { "schemaVersion", "state", "runtimeFamily", "architecture", "packageSha256",
                "packageSizeBytes", "version", "buildNumber", "parentPid", "parentStartTimeUtcTicks", "updaterPid" });
            if (StrictJson.Integer(value, "schemaVersion", 1, 1) != 1
                || StrictJson.Text(value, "state", 30) != "apply_authorized"
                || StrictJson.Text(value, "runtimeFamily", 30) != "wpf_legacy"
                || StrictJson.Text(value, "architecture", 8) != plan.Architecture
                || StrictJson.Text(value, "packageSha256", 64) != plan.Sha256
                || StrictJson.Integer(value, "packageSizeBytes", 1, UpdateContract.MaximumPackageBytes) != plan.SizeBytes
                || StrictJson.Text(value, "version", 30) != plan.Version
                || StrictJson.Integer(value, "buildNumber", 1, 65535) != plan.BuildNumber
                || StrictJson.Integer(value, "parentPid", 1, Int32.MaxValue) != plan.ParentPid
                || StrictJson.Integer(value, "parentStartTimeUtcTicks", 1, DateTime.MaxValue.Ticks) != plan.ParentStartTimeUtcTicks
                || StrictJson.Integer(value, "updaterPid", 1, Int32.MaxValue) != Process.GetCurrentProcess().Id)
                throw new InvalidDataException("Explicit update consent does not match this private job and helper.");
            ThrowIfCancelled(plan);
        }
    }
}
