using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace Uten.Legacy.Core
{
    /// <summary>No password or access token belongs in a durable session record.</summary>
    public sealed class StoredSession
    {
        public string Id { get; private set; }
        public string RefreshToken { get; private set; }
        public string IssuerApiBaseUrl { get; private set; }
        public string EndpointId { get; private set; }
        public string UserId { get; private set; }
        public StoredSession(string refreshToken, string issuerApiBaseUrl, string endpointId, string userId, string id = null)
        {
            if (String.IsNullOrWhiteSpace(refreshToken) || refreshToken.Length > 512
                || refreshToken.Any(Char.IsControl) || String.IsNullOrWhiteSpace(userId) || userId.Length > 128)
                throw new InvalidDataException("保存的会话信息无效。");
            var endpoint = new ServerEndpoint(endpointId, endpointId, issuerApiBaseUrl);
            Guid recordId;
            if (id != null && !Guid.TryParseExact(id, "D", out recordId))
                throw new InvalidDataException("保存的会话标识无效。");
            Id = id ?? Guid.NewGuid().ToString("D");
            RefreshToken = refreshToken;
            IssuerApiBaseUrl = endpoint.ApiBaseUrl;
            EndpointId = endpointId;
            UserId = userId;
        }
    }

    public interface ISessionStore
    {
        StoredSession Load();
        void Save(StoredSession session);
        void Clear();
        void EndSession(StoredSession session);
        void EnqueueRevocation(StoredSession session);
        IList<StoredSession> PendingRevocations();
        void AcknowledgeRevocation(string id);
    }

    /// <summary>A non-secret safety marker can block restore without rewriting a damaged DPAPI envelope.</summary>
    internal interface ISessionStoreSafetyFence
    {
        void FenceActiveSession();
    }

    /// <summary>CurrentUser DPAPI envelope, replaced atomically in an independent application directory.</summary>
    public sealed class DpapiSessionStore : ISessionStore, ISessionStoreSafetyFence
    {
        private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("Uten/UIMP-Win7-WPF/session-envelope/v1");
        private readonly object gate = new object();
        private readonly string directory;
        private readonly string file;
        private readonly string restoreFence;
        private const int MaximumBytes = 524288;

        public DpapiSessionStore() : this(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Uten", "UIMP-Win7-WPF")) { }
        internal DpapiSessionStore(string directory)
        {
            this.directory = Path.GetFullPath(directory);
            file = Path.Combine(this.directory, "session.dpapi");
            restoreFence = Path.Combine(this.directory, "restore-blocked.fence");
        }

        public StoredSession Load() { lock (gate) return File.Exists(restoreFence) ? null : Read().Session; }
        public IList<StoredSession> PendingRevocations()
        {
            lock (gate)
            {
                var state = Read();
                // Preserve original encrypted bytes after a failed logout write. Its old active
                // record is now a revocation candidate, never an automatically restorable login.
                if (File.Exists(restoreFence)) AddPending(state, state.Session);
                return state.Pending.ToList();
            }
        }
        public void Save(StoredSession session)
        {
            if (session == null) throw new ArgumentNullException(nameof(session));
            lock (gate)
            {
                var state = Read();
                if (File.Exists(restoreFence)) AddPending(state, state.Session);
                state.Session = session;
                Write(state);
                // Only a newly issued login committed durably can reopen automatic restoration.
                if (File.Exists(restoreFence)) File.Delete(restoreFence);
            }
        }
        public void Clear() { lock (gate) { var state = Read(); state.Session = null; Write(state); } }
        public void EndSession(StoredSession session)
        {
            lock (gate)
            {
                var state = Read();
                AddPending(state, session ?? state.Session);
                state.Session = null;
                Write(state);
            }
        }
        public void EnqueueRevocation(StoredSession session)
        {
            if (session == null) return;
            lock (gate) { var state = Read(); AddPending(state, session); Write(state); }
        }
        public void AcknowledgeRevocation(string id)
        {
            lock (gate)
            {
                var state = Read();
                state.Pending.RemoveAll(value => value.Id == id);
                if (File.Exists(restoreFence) && state.Session?.Id == id) state.Session = null;
                Write(state);
            }
        }

        void ISessionStoreSafetyFence.FenceActiveSession()
        {
            lock (gate)
            {
                Directory.CreateDirectory(directory);
                RejectLink(directory);
                if (File.Exists(restoreFence)) { RejectLink(restoreFence); return; }
                // Presence alone blocks restore, including an interrupted write. No token,
                // password, access grant, or replacement envelope is written to this marker.
                using (var stream = new FileStream(restoreFence, FileMode.CreateNew, FileAccess.Write,
                    FileShare.Read, 4096, FileOptions.WriteThrough))
                {
                    var marker = Encoding.ASCII.GetBytes("restore-blocked-v1\n");
                    stream.Write(marker, 0, marker.Length);
                    stream.Flush(true);
                }
            }
        }

        private static void AddPending(Envelope state, StoredSession session)
        {
            if (session == null || state.Pending.Any(value => value.RefreshToken == session.RefreshToken
                && value.IssuerApiBaseUrl == session.IssuerApiBaseUrl)) return;
            if (state.Pending.Count >= 256) throw new IOException("注销队列已满，请先恢复网络完成待处理注销。");
            state.Pending.Add(session);
        }

        private Envelope Read()
        {
            if (!File.Exists(file)) return new Envelope();
            RejectLink(file);
            var info = new FileInfo(file);
            if (info.Length > MaximumBytes) throw new InvalidDataException("本机会话文件过大。");
            byte[] plain = null;
            try
            {
                plain = ProtectedData.Unprotect(File.ReadAllBytes(file), Entropy, DataProtectionScope.CurrentUser);
                if (plain.Length > MaximumBytes) throw new InvalidDataException("本机会话文件过大。");
                var root = JsonValue.ParseObject(new UTF8Encoding(false, true).GetString(plain), MaximumBytes);
                if (JsonValue.Integer(root, "schema", 0, 1, 1) != 1) throw new InvalidDataException("本机会话格式不受支持。");
                var state = new Envelope();
                object active;
                if (root.TryGetValue("session", out active) && active != null) state.Session = ParseRecord(active);
                object pending;
                if (root.TryGetValue("pendingRevocations", out pending))
                {
                    var entries = pending as object[];
                    if (entries == null || entries.Length > 256) throw new InvalidDataException("本机注销队列无效。");
                    foreach (var entry in entries) state.Pending.Add(ParseRecord(entry));
                }
                return state;
            }
            finally { if (plain != null) Array.Clear(plain, 0, plain.Length); }
        }

        private void Write(Envelope state)
        {
            Directory.CreateDirectory(directory);
            RejectLink(directory);
            if (File.Exists(file)) RejectLink(file);
            var content = new Dictionary<string, object>
            {
                { "schema", 1 },
                { "session", state.Session == null ? null : Record(state.Session) },
                { "pendingRevocations", state.Pending.Select(Record).ToArray() }
            };
            var plain = Encoding.UTF8.GetBytes(JsonValue.Serialize(content));
            byte[] encrypted;
            try
            {
                if (plain.Length > MaximumBytes) throw new IOException("本机会话文件超出上限。");
                encrypted = ProtectedData.Protect(plain, Entropy, DataProtectionScope.CurrentUser);
            }
            finally { Array.Clear(plain, 0, plain.Length); }
            var temporary = Path.Combine(directory, "session-" + Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
                { stream.Write(encrypted, 0, encrypted.Length); stream.Flush(true); }
                if (File.Exists(file)) File.Replace(temporary, file, null);
                else File.Move(temporary, file);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }

        private static void RejectLink(string path)
        {
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("本机会话目录或文件不能是链接。");
        }
        private static Dictionary<string, object> Record(StoredSession session)
        {
            return new Dictionary<string, object>
            {
                { "id", session.Id }, { "refreshToken", session.RefreshToken },
                { "issuerApiBaseUrl", session.IssuerApiBaseUrl }, { "endpointId", session.EndpointId },
                { "userId", session.UserId }
            };
        }
        private static StoredSession ParseRecord(object input)
        {
            var value = input as Dictionary<string, object>;
            if (value == null) throw new InvalidDataException("本机会话记录无效。");
            return new StoredSession(JsonValue.RequiredString(value, "refreshToken", 512),
                JsonValue.RequiredString(value, "issuerApiBaseUrl", 2048), JsonValue.RequiredString(value, "endpointId", 64),
                JsonValue.RequiredString(value, "userId", 128), JsonValue.RequiredString(value, "id", 36));
        }
        private sealed class Envelope
        {
            internal StoredSession Session;
            internal readonly List<StoredSession> Pending = new List<StoredSession>();
        }
    }
}
