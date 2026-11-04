using System;
using System.Linq;
using System.Net.Http;

namespace Uten.Legacy.Core
{
    /// <summary>Only the fixed automatic staff watch receives a long-poll response budget.</summary>
    internal static class SessionWatchContract
    {
        internal static TimeSpan ForRequest(HttpRequestMessage request, TimeSpan fallback)
        {
            var uri = request?.RequestUri;
            return request != null && request.Method == HttpMethod.Get && request.Content == null
                && uri != null && uri.IsAbsoluteUri && uri.Scheme == Uri.UriSchemeHttps
                && uri.AbsolutePath == "/api/auth/session/watch" && uri.Query.Length == 0 && uri.Fragment.Length == 0
                && request.Headers.Authorization?.Scheme == "Bearer"
                && request.Headers.TryGetValues("X-Uten-Automatic", out var values) && values.SequenceEqual(new[] { "1" })
                ? TimeSpan.FromSeconds(35) : fallback;
        }
    }
}
