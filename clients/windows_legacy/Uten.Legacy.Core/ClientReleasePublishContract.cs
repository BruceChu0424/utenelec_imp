using System;
using System.Collections.Generic;
using System.Linq;

namespace Uten.Legacy.Core
{
    /// <summary>Draft snapshot contract for the publish workbench. Drafts are metadata-only:
    /// no file contents, no local paths, no credentials. Rows with an unconfirmed submission
    /// can never be saved without the unknown-submission flag, and can never be discarded.</summary>
    public static class ClientReleasePublishContract
    {
        public const int SchemaVersion = 1;
        public const string DraftKind = "client-release-publish-v1";
        public const string UnknownSubmissionKey = "_formDraftHasUnknownSubmission";

        private static readonly string[] RowKeys = { "localId", "metadata", "fileName", "sizeBytes", "requestId",
            "sha256", "releaseId", "stage", "pendingOperation", "retentionPending", "publishAcknowledged" };
        private static readonly string[] TopLevelKeys = { "schemaVersion", "rows", "context", "withdrawals", UnknownSubmissionKey };

        public static Dictionary<string, object> BuildSnapshot(IReadOnlyList<ClientReleaseQueueItem> rows,
            Dictionary<string, object> context, IReadOnlyDictionary<string, ClientReleaseWithdrawState> withdrawals)
        {
            var snapshotRows = new List<object>();
            foreach (var item in rows)
            {
                snapshotRows.Add(new Dictionary<string, object>
                {
                    { "localId", item.LocalId },
                    { "metadata", item.Metadata.ToDictionary() },
                    { "fileName", item.FileName },
                    { "sizeBytes", item.SizeBytes },
                    { "requestId", item.RequestId },
                    { "sha256", item.Sha256 },
                    { "releaseId", item.ReleaseId },
                    { "stage", item.Stage.ToString() },
                    { "pendingOperation", item.PendingOperation.HasValue ? item.PendingOperation.Value.ToString() : null },
                    { "retentionPending", item.RetentionPending },
                    { "publishAcknowledged", item.PublishAcknowledged }
                });
            }
            var snapshotWithdrawals = new List<object>();
            if (withdrawals != null)
                foreach (var entry in withdrawals)
                    snapshotWithdrawals.Add(new Dictionary<string, object> { { "id", entry.Key }, { "state", entry.Value.ToString() } });
            return new Dictionary<string, object>
            {
                { "schemaVersion", SchemaVersion },
                { "rows", snapshotRows },
                { "context", context },
                { "withdrawals", snapshotWithdrawals },
                { UnknownSubmissionKey, HasUncertainSubmission(rows, withdrawals) }
            };
        }

        public static bool HasUncertainSubmission(IReadOnlyList<ClientReleaseQueueItem> rows,
            IReadOnlyDictionary<string, ClientReleaseWithdrawState> withdrawals)
        {
            var rowsUncertain = rows != null && rows.Any(item => item.PendingOperation != null
                    || item.Stage == ClientReleaseQueueStage.Unknown
                    || item.Stage == ClientReleaseQueueStage.Uploading
                    || item.Stage == ClientReleaseQueueStage.Publishing
                    || item.Stage == ClientReleaseQueueStage.Published);
            var withdrawalsUncertain = withdrawals != null && withdrawals.Values.Any(state =>
                state == ClientReleaseWithdrawState.Sending || state == ClientReleaseWithdrawState.Unknown);
            return rowsUncertain || withdrawalsUncertain;
        }

        public sealed class ValidatedSnapshot
        {
            public List<ClientReleaseQueueItem> Rows;
            public Dictionary<string, ClientReleaseWithdrawState> Withdrawals;
            public Dictionary<string, object> Context;
            public bool HasUnknownSubmission;
        }

        /// <summary>Validates a stored draft and rebuilds the queue rows with the mandatory
        /// restore downgrades: a stored published row always re-enters as unknown pending
        /// publish, pending operations become unknown, and file-less non-store rows need a
        /// re-selected file.</summary>
        public static ValidatedSnapshot ValidateAndRestore(string json)
        {
            Dictionary<string, object> root;
            try { root = JsonValue.ParseObject(json); }
            catch (Exception error) when (error is FormatException || error is ArgumentException || error is InvalidOperationException)
            { throw new FormatException("发布队列草稿格式无效。"); }
            foreach (var key in root.Keys)
                if (!TopLevelKeys.Contains(key)) throw new FormatException("发布队列草稿格式无效。");
            if (!root.ContainsKey("schemaVersion") || !(root["schemaVersion"] is int)
                || (int)root["schemaVersion"] != SchemaVersion || !(root["rows"] is object[]))
                throw new FormatException("发布队列草稿格式无效。");
            var rawRows = (object[])root["rows"];
            if (rawRows.Length > ClientReleasePublishLimits.MaximumFiles) throw new FormatException("发布队列草稿格式无效。");
            object rawContext;
            var context = root.TryGetValue("context", out rawContext) && rawContext is Dictionary<string, object>
                ? (Dictionary<string, object>)rawContext : null;
            if (context != null) ClientReleasePublishMetadata.FromDictionary(context);

            var rows = new List<ClientReleaseQueueItem>();
            var seenLocalIds = new HashSet<string>(StringComparer.Ordinal);
            foreach (var rawRow in rawRows)
            {
                var row = rawRow as Dictionary<string, object>;
                if (row == null || row.Count != RowKeys.Length || row.Keys.Any(key => !RowKeys.Contains(key)))
                    throw new FormatException("发布队列草稿项目无效。");
                var localId = row["localId"] as string;
                ClientReleaseAdminContract.RequireUuid(localId, "发布草稿项目无效。");
                if (!seenLocalIds.Add(localId)) throw new FormatException("发布队列无效。");
                var metadata = ClientReleasePublishMetadata.FromDictionary(row["metadata"] as Dictionary<string, object>);
                var item = new ClientReleaseQueueItem
                {
                    LocalId = localId,
                    Metadata = metadata,
                    FileName = row["fileName"] as string,
                    SizeBytes = row["sizeBytes"] is int || row["sizeBytes"] is long ? Convert.ToInt64(row["sizeBytes"]) : 0,
                    RequestId = row["requestId"] as string,
                    Sha256 = row["sha256"] as string,
                    ReleaseId = row["releaseId"] as string
                };
                if (item.SizeBytes < 0 || item.SizeBytes > ClientReleasePublishLimits.MaxClientPackageBytes)
                    throw new FormatException("发布草稿项目无效。");
                if (item.RequestId != null) ClientReleaseAdminContract.RequireUuid(item.RequestId, "发布草稿项目无效。");
                if (item.ReleaseId != null) ClientReleaseAdminContract.RequireUuid(item.ReleaseId, "发布草稿项目无效。");
                item.RetentionPending = row["retentionPending"] is bool && (bool)row["retentionPending"];
                item.PublishAcknowledged = row["publishAcknowledged"] is bool && (bool)row["publishAcknowledged"];
                ClientReleaseQueueStage stage;
                var stageName = row["stage"] as string;
                if (stageName == null || !Enum.TryParse(stageName, out stage)) throw new FormatException("发布草稿项目无效。");
                item.Stage = stage;
                var operationName = row["pendingOperation"] as string;
                if (operationName != null)
                {
                    ClientReleaseQueueOperation operation;
                    if (!Enum.TryParse(operationName, out operation)) throw new FormatException("发布草稿项目无效。");
                    item.PendingOperation = operation;
                }
                // Restore downgrades: only a live server confirmation may show published.
                if (item.Stage == ClientReleaseQueueStage.Published) item.PendingOperation = ClientReleaseQueueOperation.Publish;
                if (item.PendingOperation != null) item.Stage = ClientReleaseQueueStage.Unknown;
                else if (item.Stage == ClientReleaseQueueStage.Validating || item.Stage == ClientReleaseQueueStage.Uploading
                    || item.Stage == ClientReleaseQueueStage.Publishing) item.Stage = ClientReleaseQueueStage.Unknown;
                if (item.RequestId == null && !metadata.IsStore) item.Stage = ClientReleaseQueueStage.NeedsFile;
                rows.Add(item);
            }

            var withdrawals = new Dictionary<string, ClientReleaseWithdrawState>(StringComparer.Ordinal);
            object rawWithdrawals;
            if (root.TryGetValue("withdrawals", out rawWithdrawals) && rawWithdrawals != null)
            {
                var entries = rawWithdrawals as object[];
                if (entries == null || entries.Length > 100) throw new FormatException("撤回草稿项目过多。");
                foreach (var rawEntry in entries)
                {
                    var entry = rawEntry as Dictionary<string, object>;
                    object id, state;
                    if (entry == null || entry.Count != 2 || !entry.TryGetValue("id", out id) || !entry.TryGetValue("state", out state))
                        throw new FormatException("撤回草稿格式无效。");
                    var recordId = id as string;
                    var stateName = state as string;
                    ClientReleaseWithdrawState parsed;
                    if (recordId == null || stateName == null || !Enum.TryParse(stateName, out parsed))
                        throw new FormatException("撤回草稿格式无效。");
                    ClientReleaseAdminContract.RequireUuid(recordId, "撤回草稿格式无效。");
                    if (withdrawals.ContainsKey(recordId)) throw new FormatException("撤回草稿编号重复。");
                    // A stored sending state has no confirmed outcome; it always re-enters unknown.
                    withdrawals.Add(recordId, parsed == ClientReleaseWithdrawState.Sending
                        ? ClientReleaseWithdrawState.Unknown : parsed);
                }
            }

            var hasUnknown = root.ContainsKey(UnknownSubmissionKey) && root[UnknownSubmissionKey] is bool && (bool)root[UnknownSubmissionKey];
            var stillUncertain = HasUncertainSubmission(rows, withdrawals);
            if (stillUncertain && !hasUnknown)
                throw new FormatException("未决发布草稿不能移除提交保护。");
            return new ValidatedSnapshot { Rows = rows, Withdrawals = withdrawals, Context = context, HasUnknownSubmission = hasUnknown };
        }
    }
}
