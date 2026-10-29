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
        internal readonly int ErrorResponseBytes;
        internal readonly string ExpectedPath;
        internal readonly string ExpectedQuery;
        internal bool Completed { get; private set; }
        internal HttpResponseSink(Stream destination, long expectedBytes, int errorResponseBytes,
            string expectedPath, string expectedQuery)
        {
            if (destination == null || !destination.CanWrite || expectedBytes < 1 || expectedBytes > MaximumPackageBytes
                || errorResponseBytes < 1 || errorResponseBytes > 8388608) throw new ArgumentException("下载目标或大小无效。");
            Destination = destination; ExpectedBytes = expectedBytes; ErrorResponseBytes = errorResponseBytes;
            ExpectedPath = expectedPath; ExpectedQuery = expectedQuery;
        }
        internal static HttpResponseSink FromRequest(HttpRequestMessage request)
        {
            object value;
            return request.Properties.TryGetValue(RequestProperty, out value) ? value as HttpResponseSink : null;
        }
        internal bool Owns(Uri uri)
        { return uri != null && uri.AbsolutePath == ExpectedPath && uri.Query == ExpectedQuery; }
        internal void Complete(long bytes)
        {
            if (bytes != ExpectedBytes) throw new HttpRequestException("下载内容长度与发布信息不一致。");
            Completed = true;
        }
    }
}
