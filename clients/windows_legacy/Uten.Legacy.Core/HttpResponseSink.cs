using System;
using System.IO;
using System.Net.Http;

namespace Uten.Legacy.Core
{
    /// <summary>Owned destination for the existing HTTP framing reader; never a second transport.</summary>
    internal sealed class HttpResponseSink
    {
        internal const string RequestProperty = "Uten.OwnedVerifiedResponseSink";
        internal const int MaximumPackageBytes = 512 * 1024 * 1024;
        internal readonly Stream Destination;
        internal readonly long ExpectedBytes;
        internal readonly int MaximumBytes;
        internal readonly int ErrorResponseBytes;
        internal readonly string ExpectedPath;
        internal readonly string ExpectedQuery;
        internal readonly string ExpectedMethod;
        internal bool Completed { get; private set; }
        internal HttpResponseSink(Stream destination, long expectedBytes, int errorResponseBytes,
            string expectedPath, string expectedQuery)
            : this(destination, expectedBytes, MaximumPackageBytes, errorResponseBytes, expectedPath, expectedQuery, "GET")
        { if (expectedBytes < 1) throw new ArgumentException("Package downloads require a known positive length."); }
        private HttpResponseSink(Stream destination, long expectedBytes, int maximumBytes, int errorResponseBytes,
            string expectedPath, string expectedQuery, string method)
        {
            if (destination == null || !destination.CanWrite || expectedBytes != -1 && expectedBytes < 1 || expectedBytes > maximumBytes
                || maximumBytes < 1 || maximumBytes > MaximumPackageBytes
                || errorResponseBytes < 1 || errorResponseBytes > 8388608) throw new ArgumentException("下载目标或大小无效。");
            Destination = destination; ExpectedBytes = expectedBytes; ErrorResponseBytes = errorResponseBytes;
            MaximumBytes = maximumBytes;
            ExpectedPath = expectedPath; ExpectedQuery = expectedQuery;
            ExpectedMethod = method;
        }
        internal static HttpResponseSink BoundedExport(Stream destination, int maximumBytes, int errorResponseBytes, string path, string query)
        {
            bool job = System.Text.RegularExpressions.Regex.IsMatch(path ?? "", "^/api/report-export-jobs/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/download$");
            if (job && !String.IsNullOrEmpty(query) || !job && path != "/api/master/units/export")
                throw new ArgumentException("Only approved unit export read paths can use this sink.");
            return new HttpResponseSink(destination, -1, maximumBytes, errorResponseBytes, path, query, "POST");
        }
        internal static HttpResponseSink FromRequest(HttpRequestMessage request)
        {
            object value;
            return request.Properties.TryGetValue(RequestProperty, out value) ? value as HttpResponseSink : null;
        }
        internal bool Owns(Uri uri)
        { return uri != null && uri.AbsolutePath == ExpectedPath && uri.Query == ExpectedQuery; }
        internal bool Owns(HttpRequestMessage request)
        { return request != null && request.Method.Method == ExpectedMethod && Owns(request.RequestUri); }
        internal void Complete(long bytes)
        {
            if (bytes < 1 || bytes > MaximumBytes || ExpectedBytes >= 0 && bytes != ExpectedBytes)
                throw new HttpRequestException("下载内容长度与接口合同不一致。");
            Completed = true;
        }
    }
}
