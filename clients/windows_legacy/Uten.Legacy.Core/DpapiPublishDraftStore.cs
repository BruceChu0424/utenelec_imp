using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace Uten.Legacy.Core
{
    public sealed class PublishDraftEntry
    {
        public string DraftId { get; internal set; }
        public DateTime LastWriteUtc { get; internal set; }
    }

    /// <summary>DPAPI (CurrentUser) storage for publish-workbench drafts. Drafts are
    /// metadata-only JSON; the store never touches credentials or file contents. Every write is
    /// compare-and-set against the raw bytes the caller last observed, so a second page can
    /// never silently overwrite another editor's draft.</summary>
    public sealed class DpapiPublishDraftStore
    {
        private static readonly object GlobalGate = new object();
        private readonly string root;

        public DpapiPublishDraftStore()
            : this(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "UtenLegacy", "publish-drafts")) { }

        /// <summary>Isolated-store constructor for offline checks; production uses the
        /// per-user default root.</summary>
        public DpapiPublishDraftStore(string root) { this.root = root; }

        /// <summary>Reads the raw draft JSON for a key, or null when no draft exists. Corrupt
        /// or tampered payloads surface as an explicit storage failure, never as empty data.</summary>
        public string Read(string key)
        {
            var path = PathOf(key);
            lock (GlobalGate)
            {
                if (!File.Exists(path)) return null;
                try
                {
                    var plain = ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy(key), DataProtectionScope.CurrentUser);
                    return Encoding.UTF8.GetString(plain);
                }
                catch (Exception error) when (error is IOException || error is UnauthorizedAccessException
                    || error is CryptographicException || error is FormatException || error is ArgumentException)
                { throw StoreFailure(); }
            }
        }

        public bool CompareAndSet(string key, string expectedRaw, string raw)
        {
            if (raw == null) throw new ArgumentNullException("raw");
            var path = PathOf(key);
            lock (GlobalGate)
            {
                try
                {
                    var current = File.Exists(path) ? Encoding.UTF8.GetString(
                        ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy(key), DataProtectionScope.CurrentUser)) : null;
                    if (current != expectedRaw) return false;
                    WriteAtomic(path, key, raw);
                    return true;
                }
                catch (Exception error) when (error is IOException || error is UnauthorizedAccessException
                    || error is CryptographicException || error is FormatException || error is ArgumentException)
                { throw StoreFailure(); }
            }
        }

        public bool CompareAndDelete(string key, string expectedRaw)
        {
            var path = PathOf(key);
            lock (GlobalGate)
            {
                try
                {
                    var current = File.Exists(path) ? Encoding.UTF8.GetString(
                        ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy(key), DataProtectionScope.CurrentUser)) : null;
                    if (current != expectedRaw) return false;
                    if (current != null) File.Delete(path);
                    return true;
                }
                catch (Exception error) when (error is IOException || error is UnauthorizedAccessException
                    || error is CryptographicException || error is FormatException || error is ArgumentException)
                { throw StoreFailure(); }
            }
        }

        /// <summary>Lists the drafts of one namespace with their last write time, newest first.
        /// Used by the page entry to offer resuming a previously saved queue.</summary>
        public IReadOnlyList<PublishDraftEntry> List(string namespaceHash)
        {
            if (namespaceHash == null || namespaceHash.Length < 16 || namespaceHash.Length > 128 || !IsSafeSegment(namespaceHash))
                throw StoreFailure();
            var directory = Path.Combine(root, namespaceHash);
            lock (GlobalGate)
            {
                try
                {
                    var result = new List<PublishDraftEntry>();
                    if (!Directory.Exists(directory)) return result.AsReadOnly();
                    foreach (var file in Directory.GetFiles(directory, "*.dpapi"))
                    {
                        var id = Path.GetFileNameWithoutExtension(file);
                        if (!IsDraftId(id)) continue;
                        result.Add(new PublishDraftEntry { DraftId = id, LastWriteUtc = File.GetLastWriteTimeUtc(file) });
                    }
                    result.Sort((left, right) => right.LastWriteUtc.CompareTo(left.LastWriteUtc));
                    return result.AsReadOnly();
                }
                catch (Exception error) when (error is IOException || error is UnauthorizedAccessException)
                { throw StoreFailure(); }
            }
        }

        private void WriteAtomic(string path, string key, string raw)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            var encrypted = ProtectedData.Protect(Encoding.UTF8.GetBytes(raw), Entropy(key), DataProtectionScope.CurrentUser);
            var temporary = Path.Combine(Path.GetDirectoryName(path), "draft-" + Guid.NewGuid().ToString("N") + ".tmp");
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096))
                stream.Write(encrypted, 0, encrypted.Length);
            try
            {
                if (File.Exists(path)) File.Replace(temporary, path, null);
                else File.Move(temporary, path);
            }
            catch
            {
                try { File.Delete(temporary); } catch (IOException) { }
                catch (UnauthorizedAccessException) { }
                throw;
            }
        }

        private string PathOf(string key)
        {
            if (key == null) throw StoreFailure();
            var parts = key.Split('/');
            if (parts.Length != 2 || parts[0].Length < 16 || parts[0].Length > 128
                || !IsSafeSegment(parts[0]) || !IsDraftId(parts[1]))
                throw StoreFailure();
            var combined = Path.Combine(root, parts[0], parts[1] + ".dpapi");
            var full = Path.GetFullPath(combined);
            if (!full.StartsWith(Path.GetFullPath(root) + Path.DirectorySeparatorChar.ToString(), StringComparison.Ordinal))
                throw StoreFailure();
            return full;
        }

        private static bool IsSafeSegment(string value)
        {
            foreach (var ch in value)
                if (!(ch >= 'a' && ch <= 'z' || ch >= '0' && ch <= '9')) return false;
            return true;
        }

        private static bool IsDraftId(string value)
        {
            Guid parsed;
            return Guid.TryParseExact(value, "D", out parsed) && parsed != Guid.Empty;
        }

        private static byte[] Entropy(string key)
        { return Encoding.UTF8.GetBytes("uten-legacy-publish-draft|" + key); }

        private static ApiException StoreFailure()
        { return new ApiException("LOCAL_PUBLISH_DRAFT_STORAGE", "本机发布草稿保存或读取失败，请联系管理员核对当前用户的私有目录。"); }
    }
}
