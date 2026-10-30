using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace Uten.Legacy.Core
{
    /// <summary>Native client release publish contracts mirroring the reviewed Flutter queue and
    /// the server admin controller. Stage/operation names and user-facing messages are the same
    /// contract on both clients; the server stays the single authority.</summary>
    public enum ClientReleaseQueueStage
    {
        NeedsFile = 0,
        Ready = 1,
        Validating = 2,
        Prepared = 3,
        Uploading = 4,
        Uploaded = 5,
        Publishing = 6,
        Published = 7,
        Withdrawn = 8,
        Rejected = 9,
        Unknown = 10
    }

    public enum ClientReleaseQueueOperation { Prepare = 0, Upload = 1, Publish = 2 }

    public enum ClientReleaseWithdrawState { Sending = 0, Unknown = 1, Ready = 2, Confirmed = 3 }

    public static class ClientReleasePublishLimits
    {
        public const int MaximumFiles = 100;
        public const long MaxClientPackageBytes = 536870912; // 512 MiB, matches the server contract.
        public const int MaximumReleaseNotesLength = 10000;
        public const string PublishPermission = "client_release:publish";
    }

    /// <summary>One admin release record parsed from GET list / GET one / prepare / upload /
    /// publish / withdraw responses. Only the three server states are accepted.</summary>
    public sealed class ClientReleaseRecord
    {
        public string Id { get; private set; }
        public string Platform { get; private set; }
        public string Architecture { get; private set; }
        public string Version { get; private set; }
        public long BuildNumber { get; private set; }
        public string ReleaseNotes { get; private set; }
        public string InstallMode { get; private set; }
        public string Sha256 { get; private set; }
        public long SizeBytes { get; private set; }
        public bool Mandatory { get; private set; }
        public string StoreUrl { get; private set; }
        public string State { get; private set; }
        public string PackageKind { get; private set; }
        public string FileName { get; private set; }
        public string RuntimeFamily { get; private set; }
        public string DeliveryContract { get; private set; }
        public string ExpectedSha256 { get; private set; }

        internal static ClientReleaseRecord Parse(Dictionary<string, object> value)
        {
            if (value == null) throw new FormatException("服务器管理记录不是有效对象。");
            var record = new ClientReleaseRecord
            {
                Id = JsonValue.RequiredString(value, "id", 64),
                Platform = JsonValue.RequiredString(value, "platform", 32),
                Architecture = JsonValue.RequiredString(value, "architecture", 32),
                Version = JsonValue.RequiredString(value, "version", 64),
                BuildNumber = JsonValue.Integer(value, "buildNumber", 0, 1, Int64.MaxValue),
                ReleaseNotes = JsonValue.OptionalString(value, "releaseNotes", ClientReleasePublishLimits.MaximumReleaseNotesLength),
                InstallMode = JsonValue.OptionalString(value, "installMode", 64),
                Sha256 = JsonValue.OptionalString(value, "sha256", 64),
                SizeBytes = JsonValue.Integer(value, "sizeBytes", 0, 0, ClientReleasePublishLimits.MaxClientPackageBytes),
                Mandatory = JsonValue.Boolean(value, "mandatory"),
                StoreUrl = JsonValue.OptionalString(value, "storeUrl", 2048),
                State = JsonValue.RequiredString(value, "state", 32),
                PackageKind = JsonValue.OptionalString(value, "packageKind", 32),
                FileName = JsonValue.OptionalString(value, "fileName", 200),
                RuntimeFamily = JsonValue.OptionalString(value, "runtimeFamily", 32),
                DeliveryContract = JsonValue.OptionalString(value, "deliveryContract", 32),
                ExpectedSha256 = JsonValue.OptionalString(value, "expectedSha256", 64)
            };
            if (record.State != "DRAFT" && record.State != "PUBLISHED" && record.State != "WITHDRAWN")
                throw new FormatException("服务器管理记录缺少明确有效的发布状态，原记录已保留。");
            if (record.Sha256 != null && !Regex.IsMatch(record.Sha256, "^[0-9a-f]{64}$")) throw new FormatException("服务器管理记录的摘要格式无效。");
            return record;
        }
    }

    /// <summary>The per-row frozen publish intent plus its local validation rules. The metadata
    /// mirrors Flutter's ClientReleasePublishMetadata exactly, including the Chinese messages.</summary>
    public sealed class ClientReleasePublishMetadata
    {
        public string Platform { get; set; }
        public string RuntimeFamily { get; set; }
        public string Architecture { get; set; }
        public string PackageKind { get; set; }
        public string Version { get; set; }
        public string BuildNumber { get; set; }
        public string ReleaseNotes { get; set; }
        public string StoreUrl { get; set; }

        public bool IsStore { get { return !String.IsNullOrEmpty(StoreUrl); } }
        public string GroupKey
        { get { return Platform + "/" + RuntimeFamily + "/" + Architecture + "/" + Version.Trim() + "/" + BuildNumber.Trim(); } }
        public string KindKey { get { return GroupKey + "/" + PackageKind; } }

        public ClientReleasePublishMetadata Clone()
        {
            return new ClientReleasePublishMetadata
            {
                Platform = Platform, RuntimeFamily = RuntimeFamily, Architecture = Architecture,
                PackageKind = PackageKind, Version = Version, BuildNumber = BuildNumber,
                ReleaseNotes = ReleaseNotes, StoreUrl = StoreUrl
            };
        }

        public string ValidationError()
        {
            var platform = Platform == null ? null : Platform.Trim();
            if (platform != "windows" && platform != "android" && platform != "ios" && platform != "macos")
                return "此平台尚未提供发布服务。";
            if (Version == null || !Regex.IsMatch(Version.Trim(), @"^\d+\.\d+\.\d+$"))
                return "版本号使用三段数字，例如 2.5.34。";
            long build;
            if (String.IsNullOrWhiteSpace(BuildNumber) || !Int64.TryParse(BuildNumber.Trim(), out build)
                || build < 1 || build > 2147483647)
                return "请填写有效的构建号。";
            if (platform == "windows")
            {
                var family = RuntimeFamily == null ? "flutter" : RuntimeFamily;
                var supported = family == "wpf_legacy"
                    ? new[] { "x86", "x64" }
                    : family == "flutter" ? new[] { "x86", "x64", "arm64" } : new string[0];
                if (supported.Length == 0 || !supported.Contains(Architecture)) return "客户端类型与架构不匹配。";
                if (PackageKind != "installer" && PackageKind != "update") return "Windows 必须使用安装包或更新 ZIP。";
            }
            else
            {
                if ((RuntimeFamily != null && RuntimeFamily != "flutter") || PackageKind != "update")
                    return "该平台不支持此运行时或安装类型。";
                var allowed = platform == "android" ? new[] { "arm64", "armeabi-v7a", "x64", "universal" }
                    : platform == "ios" ? new[] { "arm64", "universal" }
                    : new[] { "arm64", "x64", "universal" };
                if (!allowed.Contains(Architecture)) return "此平台不支持所选架构。";
            }
            if (IsStore && TrustedClientStore.Parse(StoreUrl, platform) == null)
                return "请填写该平台的官方商店链接。";
            if (ReleaseNotes != null && ReleaseNotes.Length > ClientReleasePublishLimits.MaximumReleaseNotesLength)
                return "发布说明最多 10000 字。";
            return null;
        }

        public Dictionary<string, object> ToDictionary()
        {
            return new Dictionary<string, object>
            {
                { "platform", Platform ?? "" }, { "runtimeFamily", RuntimeFamily ?? "" },
                { "architecture", Architecture ?? "" }, { "packageKind", PackageKind ?? "" },
                { "version", Version ?? "" }, { "buildNumber", BuildNumber ?? "" },
                { "releaseNotes", ReleaseNotes ?? "" }, { "storeUrl", StoreUrl ?? "" }
            };
        }

        public static ClientReleasePublishMetadata FromDictionary(Dictionary<string, object> value)
        {
            if (value == null) throw new FormatException("发布草稿包含未支持的元数据。");
            if (value.Count != 8) throw new FormatException("发布草稿包含未支持的元数据。");
            foreach (var entry in value)
            {
                if (!(entry.Value is string) || ((string)entry.Value).Length > 10000
                    || !new[] { "platform", "runtimeFamily", "architecture", "packageKind", "version", "buildNumber", "releaseNotes", "storeUrl" }.Contains(entry.Key))
                    throw new FormatException("发布草稿包含未支持的元数据。");
            }
            return new ClientReleasePublishMetadata
            {
                Platform = (string)value["platform"], RuntimeFamily = (string)value["runtimeFamily"],
                Architecture = (string)value["architecture"], PackageKind = (string)value["packageKind"],
                Version = (string)value["version"], BuildNumber = (string)value["buildNumber"],
                ReleaseNotes = (string)value["releaseNotes"], StoreUrl = (string)value["storeUrl"]
            };
        }

        /// <summary>The frozen prepare request body. runtimeFamily is only sent for wpf_legacy,
        /// matching the Flutter gateway and the server's default of flutter.</summary>
        public Dictionary<string, object> ToRequestBody(string requestId, string fileName, string expectedSha256)
        {
            var body = new Dictionary<string, object>
            {
                { "requestId", requestId },
                { "platform", Platform.Trim() },
                { "architecture", Architecture },
                { "version", Version.Trim() },
                { "buildNumber", Int64.Parse(BuildNumber.Trim()) },
                { "releaseNotes", (ReleaseNotes ?? "").Trim() },
                { "mandatory", false },
                { "packageKind", PackageKind }
            };
            var family = RuntimeFamily == null ? "flutter" : RuntimeFamily;
            if (family != "flutter") body.Add("runtimeFamily", family);
            if (IsStore) body.Add("storeUrl", StoreUrl.Trim());
            else
            {
                body.Add("fileName", fileName);
                body.Add("expectedSha256", expectedSha256);
            }
            return body;
        }
    }

    /// <summary>Trusted official store links, mirroring the server's validateStoreUrl whitelist.</summary>
    public static class TrustedClientStore
    {
        public static Uri Parse(string candidate, string platform)
        {
            if (String.IsNullOrEmpty(candidate) || candidate.Length > 2048) return null;
            Uri uri;
            if (!Uri.TryCreate(candidate.Trim(), UriKind.Absolute, out uri) || uri.Scheme != Uri.UriSchemeHttps
                || uri.UserInfo.Length != 0 || uri.Fragment.Length != 0 || (uri.Port != 443 && !uri.IsDefaultPort))
                return null;
            var host = uri.Host;
            if (platform == "ios" || platform == "macos")
                return host == "apps.apple.com" ? uri : null;
            if (platform == "android")
                return host == "play.google.com" && uri.AbsolutePath.StartsWith("/store/apps/details", StringComparison.Ordinal) ? uri : null;
            return null;
        }
    }

    public static class ClientReleaseAdminContract
    {
        public static ClientReleaseRecord ParseRecord(string json)
        {
            return ClientReleaseRecord.Parse(JsonValue.ParseObject(json));
        }

        public static IReadOnlyList<ClientReleaseRecord> ParseRecordList(string json)
        {
            var serializer = new System.Web.Script.Serialization.JavaScriptSerializer { MaxJsonLength = 8388608 };
            object parsed;
            try { parsed = serializer.DeserializeObject(json); }
            catch (Exception error) when (error is ArgumentException || error is InvalidOperationException || error is FormatException)
            { throw new FormatException("发布记录列表格式无效。"); }
            var entries = parsed as object[];
            if (entries == null)
            {
                var wrapper = parsed as Dictionary<string, object>;
                object data;
                if (wrapper != null && wrapper.TryGetValue("data", out data)) entries = data as object[];
            }
            if (entries == null || entries.Length > 1000) throw new FormatException("发布记录列表格式无效。");
            var records = new List<ClientReleaseRecord>();
            foreach (object entry in entries)
                records.Add(ClientReleaseRecord.Parse(entry as Dictionary<string, object>));
            return records;
        }

        public static void RequireUuid(string value, string message)
        {
            if (value == null || !Regex.IsMatch(value, "^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$"))
                throw new FormatException(message);
        }

        /// <summary>Validates an admin reply against the frozen local intent. Any mismatch keeps
        /// the original record and throws; it never adopts a different target or receipt.</summary>
        public static void ValidateRecord(ClientReleaseRecord record, ClientReleasePublishMetadata metadata,
            string requestId, string fileName, string sha256, long sizeBytes)
        {
            if (record.Id != requestId
                || record.Platform != metadata.Platform.Trim()
                || record.Architecture != metadata.Architecture
                || (record.RuntimeFamily ?? "flutter") != (metadata.RuntimeFamily ?? "flutter")
                || record.PackageKind != metadata.PackageKind
                || record.Version != metadata.Version.Trim()
                || record.BuildNumber.ToString(System.Globalization.CultureInfo.InvariantCulture) != metadata.BuildNumber.Trim()
                || (record.ReleaseNotes ?? "") != (metadata.ReleaseNotes ?? "").Trim()
                || record.Mandatory)
                throw new FormatException("服务器返回的发布目标与本项目不一致，原编号已保留。");
            var expectedInstallMode = ExpectedInstallMode(metadata);
            if (record.InstallMode != expectedInstallMode)
                throw new FormatException("服务器返回的包类型、文件或商店链接与原意图不一致，原编号已保留。");
            if (metadata.IsStore)
            {
                if (String.IsNullOrEmpty(record.StoreUrl) || record.StoreUrl != metadata.StoreUrl.Trim())
                    throw new FormatException("服务器返回的包类型、文件或商店链接与原意图不一致，原编号已保留。");
            }
            else
            {
                if (record.FileName != fileName || record.ExpectedSha256 != sha256
                    || (!String.IsNullOrEmpty(record.StoreUrl)))
                    throw new FormatException("服务器返回的包类型、文件或商店链接与原意图不一致，原编号已保留。");
                if ((record.State == "PUBLISHED" || !String.IsNullOrEmpty(record.Sha256) || record.SizeBytes != 0)
                    && (record.Sha256 != sha256 || record.SizeBytes != sizeBytes))
                    throw new FormatException("服务器记录的文件大小或SHA-256与原文件不一致，原编号已保留。");
            }
        }

        public static void ValidateDeliveryContract(ClientReleaseRecord record, ClientReleasePublishMetadata metadata)
        {
            if (metadata.Platform == "windows" && record.DeliveryContract != "paired_v1")
                throw new ApiException("DELIVERY_CONTRACT_UNSUPPORTED", "服务器尚未启用同组合双包发布契约，请先升级发布服务。");
            if (metadata.Platform == "android" && !metadata.IsStore && record.DeliveryContract != "audited_v1")
                throw new ApiException("DELIVERY_CONTRACT_UNSUPPORTED", "服务器尚未启用APK内容校验，请先升级发布服务。");
        }

        public static string ExpectedInstallMode(ClientReleasePublishMetadata metadata)
        {
            if (metadata.IsStore) return "store";
            var family = metadata.RuntimeFamily ?? "flutter";
            if (metadata.Platform == "windows")
            {
                if (metadata.PackageKind == "installer") return family == "wpf_legacy" ? "windows_wpf_setup" : "windows_setup";
                return family == "wpf_legacy" ? "windows_wpf_archive" : "windows_archive";
            }
            if (metadata.Platform == "android") return "android_package";
            return "store";
        }

        /// <summary>Complete Windows pair groups across the ledger and freshly confirmed queue
        /// records. Same family/architecture/version/build with installer+update published.</summary>
        public static IReadOnlyList<ClientReleasePairGroup> BuildPairGroups(
            IEnumerable<ClientReleaseRecord> ledger, IEnumerable<ClientReleaseQueueItem> items)
        {
            var byId = new Dictionary<string, ClientReleaseRecord>(StringComparer.Ordinal);
            if (ledger != null)
                foreach (var record in ledger)
                    if (record != null && !String.IsNullOrEmpty(record.Id)) byId[record.Id] = record;
            if (items != null)
                foreach (var item in items)
                {
                    var published = item != null ? item.PublishedRelease : null;
                    if (published != null && !String.IsNullOrEmpty(published.Id)) byId[published.Id] = published;
                }
            var groups = new Dictionary<string, List<ClientReleaseRecord>>(StringComparer.Ordinal);
            var order = new List<string>();
            foreach (var record in byId.Values)
            {
                if (record.Platform != "windows" || record.State != "PUBLISHED"
                    || String.IsNullOrEmpty(record.Sha256) || record.SizeBytes <= 0) continue;
                var key = record.RuntimeFamily + "/" + record.Architecture + "/" + record.Version + "/"
                    + record.BuildNumber.ToString(System.Globalization.CultureInfo.InvariantCulture);
                List<ClientReleaseRecord> bucket;
                if (!groups.TryGetValue(key, out bucket)) { bucket = new List<ClientReleaseRecord>(); groups.Add(key, bucket); order.Add(key); }
                bucket.Add(record);
            }
            var result = new List<ClientReleasePairGroup>();
            foreach (var key in order)
            {
                var bucket = groups[key];
                var hasInstaller = bucket.Any(record => record.PackageKind == "installer");
                var hasUpdate = bucket.Any(record => record.PackageKind == "update");
                result.Add(new ClientReleasePairGroup { Key = key, Records = bucket.AsReadOnly(), Complete = hasInstaller && hasUpdate });
            }
            return result.AsReadOnly();
        }
    }

    public sealed class ClientReleasePairGroup
    {
        public string Key { get; internal set; }
        public IReadOnlyList<ClientReleaseRecord> Records { get; internal set; }
        public bool Complete { get; internal set; }
    }

    /// <summary>One queue row. The frozen intent is requestId: once assigned it never changes and
    /// re-selected files must carry the same SHA-256. Errors and progress never enter drafts.</summary>
    public sealed class ClientReleaseQueueItem
    {
        public string LocalId { get; internal set; }
        public ClientReleasePublishMetadata Metadata { get; internal set; }
        /// <summary>Local path of the picked file; kept only until the row reaches a terminal,
        /// rejected or unknown outcome, mirroring the Flutter one-shot stream contract.</summary>
        public string SourcePath { get; internal set; }
        public long SourceSize { get; internal set; }
        public string FileName { get; internal set; }
        public string RequestId { get; internal set; }
        public string Sha256 { get; internal set; }
        public string ReleaseId { get; internal set; }
        public string Error { get; internal set; }
        public long SizeBytes { get; internal set; }
        public ClientReleaseQueueStage Stage { get; internal set; }
        public ClientReleaseQueueOperation? PendingOperation { get; internal set; }
        public double Progress { get; internal set; }
        public ClientReleaseRecord PublishedRelease { get; internal set; }
        public bool RetentionPending { get; internal set; }
        public bool PublishAcknowledged { get; internal set; }
        internal bool Dispatched { get; set; }

        public bool Frozen { get { return RequestId != null; } }
        public bool Uncertain { get { return Stage == ClientReleaseQueueStage.Unknown || PendingOperation != null; } }
        public bool Published { get { return Stage == ClientReleaseQueueStage.Published; } }
        public bool Terminal { get { return Published || Stage == ClientReleaseQueueStage.Withdrawn; } }
        public bool NeedsFile
        {
            get
            {
                return !Metadata.IsStore && SourcePath == null
                    && (Stage == ClientReleaseQueueStage.NeedsFile || Stage == ClientReleaseQueueStage.Ready
                        || Stage == ClientReleaseQueueStage.Validating || Stage == ClientReleaseQueueStage.Prepared
                        || Stage == ClientReleaseQueueStage.Rejected);
            }
        }
    }
}
