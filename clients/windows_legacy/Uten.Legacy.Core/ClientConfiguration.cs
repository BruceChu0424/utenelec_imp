using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;

namespace Uten.Legacy.Core
{
    /// <summary>Packaged administrator configuration; the UI selects IDs, never arbitrary URLs.</summary>
    public sealed class ClientConfiguration
    {
        public ReadOnlyCollection<ServerEndpoint> Endpoints { get; private set; }
        public string SelectedEndpointId { get; private set; }
        public TimeSpan RequestTimeout { get; private set; }
        public int MaxResponseBytes { get; private set; }
        public bool IsConfigured { get { return Endpoints.Count != 0; } }

        public ClientConfiguration(IEnumerable<ServerEndpoint> endpoints, string selectedEndpointId = null,
            int requestTimeoutSeconds = 30, int maxResponseBytes = 2097152)
        {
            var values = (endpoints ?? Enumerable.Empty<ServerEndpoint>()).ToList();
            if (values.Count > 8 || values.Any(value => value == null)
                || values.Select(value => value.Id).Distinct(StringComparer.Ordinal).Count() != values.Count)
                throw new InvalidDataException("服务器配置重复或数量超出限制。");
            if (requestTimeoutSeconds < 1 || requestTimeoutSeconds > 120
                || maxResponseBytes < 1024 || maxResponseBytes > 8388608)
                throw new InvalidDataException("网络超时或响应大小配置无效。");
            Endpoints = values.AsReadOnly();
            SelectedEndpointId = selectedEndpointId ?? values.FirstOrDefault()?.Id;
            if (SelectedEndpointId != null && !values.Any(value => value.Id == SelectedEndpointId))
                throw new InvalidDataException("所选服务器不在已审核的连接配置内。");
            RequestTimeout = TimeSpan.FromSeconds(requestTimeoutSeconds);
            MaxResponseBytes = maxResponseBytes;
        }

        public static ClientConfiguration Load(string path)
        {
            if (String.IsNullOrWhiteSpace(path) || !File.Exists(path))
                return new ClientConfiguration(null);
            var info = new FileInfo(path);
            if (info.Length > 65536) throw new InvalidDataException("服务器配置文件过大。");
            Dictionary<string, object> root;
            try { root = JsonValue.ParseObject(File.ReadAllText(path, new UTF8Encoding(false, true)), 65536); }
            catch (Exception error) when (error is FormatException || error is ArgumentException || error is DecoderFallbackException)
            { throw new InvalidDataException("服务器配置文件格式不正确。"); }
            var endpoints = new List<ServerEndpoint>();
            object entries;
            if (root.TryGetValue("endpoints", out entries))
            {
                var array = entries as object[];
                if (array == null || array.Length > 8) throw new InvalidDataException("服务器列表格式不正确。");
                foreach (var entry in array)
                {
                    var value = entry as Dictionary<string, object>;
                    if (value == null) throw new InvalidDataException("服务器列表格式不正确。");
                    endpoints.Add(new ServerEndpoint(JsonValue.RequiredString(value, "id", 64),
                        JsonValue.RequiredString(value, "name", 100), JsonValue.RequiredString(value, "apiBaseUrl", 2048)));
                }
            }
            return new ClientConfiguration(endpoints, JsonValue.OptionalString(root, "selectedEndpointId", 64),
                (int)JsonValue.Integer(root, "requestTimeoutSeconds", 30, 1, 120),
                (int)JsonValue.Integer(root, "maxResponseBytes", 2097152, 1024, 8388608));
        }
    }

    public sealed class ServerEndpoint
    {
        public string Id { get; private set; }
        public string Name { get; private set; }
        public Uri ApiBaseUri { get; private set; }
        public string ApiBaseUrl { get { return ApiBaseUri.AbsoluteUri.TrimEnd('/'); } }

        public ServerEndpoint(string id, string name, string apiBaseUrl)
        {
            if (String.IsNullOrWhiteSpace(id) || id.Length > 64 || id.Any(Char.IsControl)
                || String.IsNullOrWhiteSpace(name) || name.Length > 100 || name.Any(Char.IsControl))
                throw new InvalidDataException("服务器名称或标识无效。");
            Uri uri;
            if (apiBaseUrl == null || apiBaseUrl.Length > 2048 || apiBaseUrl.Any(Char.IsControl)
                || apiBaseUrl.Contains("\\") || !Uri.TryCreate(apiBaseUrl, UriKind.Absolute, out uri)
                || uri.Scheme != Uri.UriSchemeHttps || uri.UserInfo.Length != 0 || uri.Query.Length != 0
                || uri.Fragment.Length != 0 || uri.AbsolutePath.TrimEnd('/') != "/api" || IsLoopback(uri))
                throw new InvalidDataException("正式服务器必须使用固定的 HTTPS /api 地址，不能使用本机回环地址。");
            Id = id;
            Name = name;
            ApiBaseUri = new Uri(uri.GetLeftPart(UriPartial.Authority) + "/api", UriKind.Absolute);
        }

        private static bool IsLoopback(Uri uri)
        {
            IPAddress address;
            var host = uri.Host.TrimEnd('.');
            return uri.IsLoopback || host.Equals("localhost", StringComparison.OrdinalIgnoreCase)
                || host.EndsWith(".localhost", StringComparison.OrdinalIgnoreCase)
                || (IPAddress.TryParse(uri.Host.Trim('[', ']'), out address)
                    && (IPAddress.IsLoopback(address) || address.Equals(IPAddress.Any) || address.Equals(IPAddress.IPv6Any)));
        }

        internal Uri Resolve(string relativePath)
        {
            if (String.IsNullOrWhiteSpace(relativePath) || relativePath.Length > 4096
                || relativePath.Any(Char.IsControl) || relativePath.Contains("\\")
                || relativePath.Contains("#") || relativePath.StartsWith("//", StringComparison.Ordinal))
                throw new ApiException("INVALID_API_PATH", "接口路径无效。");
            var path = relativePath.TrimStart('/');
            var pathOnly = path.Split('?')[0];
            if (pathOnly.Length == 0 || pathOnly.Contains(":"))
                throw new ApiException("INVALID_API_PATH", "接口路径无效。");
            foreach (var part in pathOnly.Split('/'))
            {
                var decoded = Uri.UnescapeDataString(part);
                if (decoded == "." || decoded == ".." || decoded.Contains("/") || decoded.Contains("\\")
                    || decoded.Any(Char.IsControl))
                    throw new ApiException("INVALID_API_PATH", "接口路径无效。");
            }
            var result = new Uri(ApiBaseUrl + "/" + path, UriKind.Absolute);
            if (result.GetLeftPart(UriPartial.Authority) != ApiBaseUri.GetLeftPart(UriPartial.Authority)
                || !result.AbsolutePath.StartsWith("/api/", StringComparison.Ordinal))
                throw new ApiException("INVALID_API_PATH", "接口路径不能离开当前服务器。");
            return result;
        }
    }
}
