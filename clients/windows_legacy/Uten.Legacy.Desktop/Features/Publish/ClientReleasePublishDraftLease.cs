using System;
using System.Security.Cryptography;
using System.Text;
using Uten.Legacy.Core;

namespace Uten.Legacy.Desktop.Features.Publish
{
    /// <summary>One page's lease on a publish draft stored in the DPAPI publish store. Drafts
    /// live under the server+user+dataset namespace, are saved by compare-and-set, and can only
    /// be discarded while no unconfirmed submission is recorded in the stored snapshot.</summary>
    public sealed class ClientReleasePublishDraftLease
    {
        private readonly DpapiPublishDraftStore store;
        private readonly string key;
        private string raw;
        private bool discarding, discarded;

        public string DraftId { get; private set; }
        public bool Resumed { get; private set; }
        public string NamespaceHash { get; private set; }
        public bool HasUnknownSubmission { get; private set; }

        public static string ComputeNamespaceHash(string apiBaseUrl, UserProfile user)
        {
            if (user == null) throw new ArgumentNullException("user");
            if (String.IsNullOrWhiteSpace(apiBaseUrl)) throw new ArgumentException("发布草稿需要当前服务器地址。");
            var namespaceSource = new System.Web.Script.Serialization.JavaScriptSerializer().Serialize(
                new System.Collections.Generic.Dictionary<string, object>
                {
                    { "server", apiBaseUrl }, { "userId", user.Id },
                    { "datasetId", user.BusinessDatasetId }, { "generation", user.BusinessResetGeneration }
                });
            using (var sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(namespaceSource)))
                    .Replace("-", "").ToLowerInvariant().Substring(0, 40);
        }

        public ClientReleasePublishDraftLease(DpapiPublishDraftStore store, string apiBaseUrl, UserProfile user, string draftId)
        {
            if (store == null) throw new ArgumentNullException("store");
            if (user == null) throw new ArgumentNullException("user");
            if (String.IsNullOrWhiteSpace(apiBaseUrl)) throw new ArgumentException("发布草稿需要当前服务器地址。");
            if (String.IsNullOrEmpty(user.Id)) throw new InvalidOperationException("当前身份不能创建发布草稿。");
            this.store = store;
            DraftId = draftId ?? Guid.NewGuid().ToString("D");
            ClientReleaseAdminContract.RequireUuid(DraftId, "发布草稿编号无效");
            Resumed = draftId != null;
            NamespaceHash = ComputeNamespaceHash(apiBaseUrl, user);
            key = NamespaceHash + "/" + DraftId;
        }

        /// <summary>Reads the stored snapshot. A fresh lease never adopts a draft that another
        /// page saved under the same generated id; that is a conflict, not an overwrite.</summary>
        public string Load()
        {
            if (discarded) throw new InvalidOperationException("原发布草稿正在或已经明确丢弃。");
            raw = store.Read(key);
            if (raw != null)
            {
                if (!Resumed) throw new InvalidOperationException("这份发布草稿编号已被使用，请从草稿入口恢复或另存新草稿。");
                var validated = ClientReleasePublishContract.ValidateAndRestore(raw);
                HasUnknownSubmission = validated.HasUnknownSubmission;
            }
            return raw;
        }

        public void Save(string snapshotJson)
        {
            if (discarding) throw new InvalidOperationException("正在确认丢弃原草稿。");
            if (discarded) return;
            if (!store.CompareAndSet(key, raw, snapshotJson))
                throw new InvalidOperationException("这份草稿已在其他页面修改或删除。当前输入仍在页面中，请保留页面并另存草稿。");
            raw = snapshotJson;
            HasUnknownSubmission = SnapshotHasUnknown(snapshotJson);
        }

        private static bool SnapshotHasUnknown(string snapshotJson)
        {
            try { return ClientReleasePublishContract.ValidateAndRestore(snapshotJson).HasUnknownSubmission; }
            catch (Exception) { return true; }
        }

        /// <summary>Explicitly removes the draft. A stored unconfirmed submission blocks the
        /// removal; the identity re-check runs while the discard is in flight.</summary>
        public void Discard(Func<bool> isCurrent)
        {
            if (discarding || discarded) throw new InvalidOperationException("原草稿已在处理。");
            discarding = true;
            try
            {
                var previous = store.Read(key);
                if (previous != null)
                {
                    if (ClientReleasePublishContract.ValidateAndRestore(previous).HasUnknownSubmission)
                        throw new InvalidOperationException("提交结果待核对，请先核对提交，原记录不能删除。");
                }
                if (isCurrent != null && !isCurrent()) throw new InvalidOperationException("发布身份已变化，原草稿继续保留。");
                if (!store.CompareAndDelete(key, previous))
                    throw new InvalidOperationException("这份草稿已在其他页面修改或删除，请核对后重试。");
                discarded = true;
            }
            finally { discarding = false; }
        }
    }
}
