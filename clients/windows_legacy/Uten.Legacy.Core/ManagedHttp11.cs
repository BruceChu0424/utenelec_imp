using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;

namespace Uten.Legacy.Core
{
    /// <summary>
    /// A deliberately small HTTP/1.1 codec for an already authenticated TLS stream.
    /// The transport owns the stream, timeout, cancellation socket close, and server trust.
    /// Each invocation writes one request and the transport must then close the connection.
    /// </summary>
    internal static class ManagedHttp11
    {
        private const int MaxHeaderBytes = 32768;
        private const int MaxLineBytes = 8192;
        private const int MaxHeaderCount = 100;
        private const int MaxRequestBytes = 16384;
        private const int MaxChunkMetadataBytes = 32768;
        private static readonly uint[] CrcTable = CreateCrcTable();

        internal static HttpResponseMessage SendAndReceive(Stream tlsStream, HttpRequestMessage request,
            int maxResponseBytes, CancellationToken cancellationToken,
            Func<int, CancellationToken> beginResponseBody = null, HttpResponseSink responseSink = null)
        {
            if (tlsStream == null) throw new ArgumentNullException(nameof(tlsStream));
            if (request == null) throw new ArgumentNullException(nameof(request));
            if (maxResponseBytes <= 0) throw new ArgumentOutOfRangeException(nameof(maxResponseBytes));
            cancellationToken.ThrowIfCancellationRequested();

            // Fully validate and bound the request before its first byte reaches the wire.
            var outbound = BuildRequest(request, cancellationToken, responseSink != null);
            cancellationToken.ThrowIfCancellationRequested();
            MutationWirePermit.BeforeWireWrite(request, outbound.Body);
            tlsStream.Write(outbound.Headers, 0, outbound.Headers.Length);
            if (outbound.Body.Length != 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
                tlsStream.Write(outbound.Body, 0, outbound.Body.Length);
            }
            tlsStream.Flush();
            cancellationToken.ThrowIfCancellationRequested();
            return ReadResponse(tlsStream, request, maxResponseBytes, cancellationToken, beginResponseBody, responseSink);
        }

        private static OutboundRequest BuildRequest(HttpRequestMessage request, CancellationToken cancellationToken, bool identityEncoding)
        {
            var uri = request.RequestUri;
            if (uri == null || !uri.IsAbsoluteUri || uri.Scheme != Uri.UriSchemeHttps
                || uri.UserInfo.Length != 0 || uri.Fragment.Length != 0 || uri.Host.Length == 0
                || !uri.AbsolutePath.StartsWith("/api/", StringComparison.Ordinal)
                || request.Version != new Version(1, 1))
                throw Invalid("The request target is not supported.");
            // Uri can normalize backslashes and raw control characters. Do not accept them
            // even when the resulting AbsoluteUri would have been inside the API prefix.
            foreach (var ch in uri.OriginalString)
                if (ch <= 32 || ch == 127 || ch == '\\') throw Invalid("The request target is not supported.");
            var queryStart = uri.OriginalString.IndexOf('?');
            var originalPathAndAuthority = queryStart < 0 ? uri.OriginalString : uri.OriginalString.Substring(0, queryStart);
            var target = uri.GetComponents(UriComponents.PathAndQuery, UriFormat.UriEscaped);
            if (!target.StartsWith("/api/", StringComparison.Ordinal) || ContainsEncodedPathEscape(originalPathAndAuthority)
                || ContainsEncodedPathEscape(uri.AbsolutePath))
                throw Invalid("The request target is not supported.");
            ValidateAscii(target, false);
            var method = request.Method.Method;
            if (method != "GET" && method != "POST" && !MutationWirePermit.AllowsExtendedMethod(request))
                throw Invalid("The request method is not supported.");

            var host = uri.IdnHost;
            ValidateAscii(host, false);
            if (host.IndexOf('%') >= 0) throw Invalid("The request target is not supported.");
            if (uri.HostNameType == UriHostNameType.IPv6 && !host.StartsWith("[", StringComparison.Ordinal))
                host = "[" + host + "]";
            if (!uri.IsDefaultPort) host += ":" + uri.Port.ToString(System.Globalization.CultureInfo.InvariantCulture);

            var fields = new List<Field>();
            var requestBudget = MutationWirePermit.From(request)?.MaximumRequestBytes ?? MaxRequestBytes;
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var header in request.Headers)
            {
                ValidateName(header.Key);
                if (IsRequestControlledHeader(header.Key)) throw Invalid("A request header is not supported.");
                AddRequestField(fields, names, header.Key, header.Value);
            }

            var body = new byte[0];
            if (request.Content != null)
            {
                using (var sink = new BoundedWriteStream(requestBudget, cancellationToken))
                {
                    try { request.Content.CopyToAsync(sink).GetAwaiter().GetResult(); }
                    catch (OperationCanceledException) { throw; }
                    catch (Exception error) when (error is HttpRequestException || error is IOException
                        || error is InvalidOperationException || error is ArgumentException)
                    { throw Invalid("The request body could not be encoded within its limit."); }
                    body = sink.ToArray();
                }
                foreach (var header in request.Content.Headers)
                {
                    ValidateName(header.Key);
                    if (header.Key.Equals("Content-Length", StringComparison.OrdinalIgnoreCase))
                    {
                        var lengthValues = new List<string>(header.Value);
                        if (lengthValues.Count != 1 || ParseDecimal(lengthValues[0], requestBudget) != body.Length)
                            throw Invalid("The request body length is invalid.");
                        continue; // Always regenerate it from the actual bounded bytes.
                    }
                    if (IsRequestControlledHeader(header.Key) || header.Key.Equals("Content-Encoding", StringComparison.OrdinalIgnoreCase))
                        throw Invalid("A request content header is not supported.");
                    AddRequestField(fields, names, header.Key, header.Value);
                }
            }
            if (method == "GET" && body.Length != 0) throw Invalid("A GET request body is not supported.");
            var mutation = MutationWirePermit.From(request);
            if (mutation != null) mutation.ValidateEncoded(request, body);

            var lines = new StringBuilder();
            var count = 0;
            AppendRequestLine(lines, method + " " + target + " HTTP/1.1");
            AppendRequestHeader(lines, "Host", host, ref count);
            AppendRequestHeader(lines, "Connection", "close", ref count);
            AppendRequestHeader(lines, "Accept-Encoding", identityEncoding ? "identity" : "gzip", ref count);
            foreach (var field in fields) AppendRequestHeader(lines, field.Name, field.Value, ref count);
            if (request.Content != null || method == "POST")
                AppendRequestHeader(lines, "Content-Length", body.Length.ToString(System.Globalization.CultureInfo.InvariantCulture), ref count);
            AppendRequestLine(lines, String.Empty);
            return new OutboundRequest { Headers = Encoding.ASCII.GetBytes(lines.ToString()), Body = body };
        }

        private static bool ContainsEncodedPathEscape(string path)
        {
            // Keep URI routing unambiguous across proxies and application servers.
            return path.IndexOf("%2f", StringComparison.OrdinalIgnoreCase) >= 0
                || path.IndexOf("%5c", StringComparison.OrdinalIgnoreCase) >= 0
                || path.IndexOf("%2e", StringComparison.OrdinalIgnoreCase) >= 0
                || path.IndexOf("%25", StringComparison.OrdinalIgnoreCase) >= 0
                || path.IndexOf("%00", StringComparison.OrdinalIgnoreCase) >= 0
                || path.IndexOf("%0d", StringComparison.OrdinalIgnoreCase) >= 0
                || path.IndexOf("%0a", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private static bool IsRequestControlledHeader(string name)
        {
            switch (name.ToLowerInvariant())
            {
                case "host": case "connection": case "content-length": case "transfer-encoding":
                case "expect": case "te": case "trailer": case "upgrade": case "keep-alive":
                case "proxy-connection": case "proxy-authorization": case "cookie": case "cookie2":
                case "accept-encoding": return true;
                default: return false;
            }
        }

        private static void AddRequestField(List<Field> fields, HashSet<string> names, string name, IEnumerable<string> values)
        {
            if (fields.Count >= MaxHeaderCount - 4 || name.Length + 4 > MaxLineBytes)
                throw Invalid("The request headers exceed their limit.");
            if (!names.Add(name)) throw Invalid("A request header is duplicated.");
            var parts = new List<string>();
            var length = name.Length + 4;
            foreach (var value in values)
            {
                ValidateAscii(value, true);
                if (value.Length > MaxLineBytes - length - (parts.Count == 0 ? 0 : 2))
                    throw Invalid("The request headers exceed their limit.");
                length += value.Length + (parts.Count == 0 ? 0 : 2);
                parts.Add(value);
            }
            if (parts.Count == 0) throw Invalid("A request header is empty.");
            foreach (var field in fields) length += field.Name.Length + field.Value.Length + 4;
            if (length > MaxHeaderBytes) throw Invalid("The request headers exceed their limit.");
            fields.Add(new Field(name, String.Join(", ", parts)));
        }

        private static void AppendRequestHeader(StringBuilder target, string name, string value, ref int count)
        {
            if (++count > MaxHeaderCount) throw Invalid("The request headers exceed their limit.");
            AppendRequestLine(target, name + ": " + value);
        }

        private static void AppendRequestLine(StringBuilder target, string line)
        {
            if (line.Length + 2 > MaxLineBytes || target.Length > MaxHeaderBytes - line.Length - 2)
                throw Invalid("The request headers exceed their limit.");
            target.Append(line).Append("\r\n");
        }

        private static HttpResponseMessage ReadResponse(Stream stream, HttpRequestMessage request, int limit, CancellationToken token,
            Func<int, CancellationToken> beginResponseBody, HttpResponseSink responseSink)
        {
            var reader = new Reader(stream, token);
            List<Field> fields;
            Dictionary<string, string> singletons;
            int status;
            string reason;
            var informationalCount = 0;
            while (true)
            {
                ReadStatus(reader.ReadHeaderLine(), out status, out reason);
                fields = ReadFields(reader);
                singletons = ValidateResponseFields(fields);
                if (status >= 200) break;
                if (status == 101 || ++informationalCount > 5 || singletons.ContainsKey("Content-Length")
                    || singletons.ContainsKey("Transfer-Encoding") || singletons.ContainsKey("Content-Encoding"))
                    throw Invalid("An informational response is not supported.");
            }
            if (status >= 300 && status < 400) throw Invalid("HTTP redirects are not supported.");
            var streamToFile = responseSink != null && status == 200;
            if (streamToFile) limit = Math.Min(limit, responseSink.MaximumBytes);
            if (responseSink != null && status >= 200 && status < 300 && status != 200)
                throw Invalid("A package download must return a complete HTTP 200 response.");
            if (responseSink != null && !streamToFile) limit = responseSink.ErrorResponseBytes;

            string contentLength;
            string transferEncoding;
            string contentEncoding;
            var hasLength = singletons.TryGetValue("Content-Length", out contentLength);
            var chunked = singletons.TryGetValue("Transfer-Encoding", out transferEncoding);
            var gzip = singletons.TryGetValue("Content-Encoding", out contentEncoding);
            if (hasLength && chunked) throw Invalid("The response body framing is ambiguous.");
            if (chunked && !transferEncoding.Equals("chunked", StringComparison.OrdinalIgnoreCase))
                throw Invalid("The response transfer encoding is not supported.");
            if (gzip && !contentEncoding.Equals("gzip", StringComparison.OrdinalIgnoreCase))
                throw Invalid("The response content encoding is not supported.");
            if (streamToFile && (gzip || singletons.ContainsKey("Content-Range")))
                throw Invalid("Package downloads require an unencoded complete representation.");
            if (singletons.ContainsKey("Trailer") && !chunked) throw Invalid("The response trailers are invalid.");
            ValidateTrailerDeclaration(singletons);
            var hopHeaders = ConnectionHeaderNames(singletons);
            var exactLength = hasLength ? ParseDecimal(contentLength, limit) : 0;
            if (streamToFile && responseSink.ExpectedBytes < 0 && !hasLength && !chunked)
                throw Invalid("An export download requires explicit complete response framing.");
            if (streamToFile && responseSink.ExpectedBytes >= 0 && hasLength && exactLength != responseSink.ExpectedBytes)
                throw Invalid("The package content length disagrees with its release metadata.");
            if (status == 204 && (hasLength || chunked || gzip))
                throw Invalid("A no-content response contains body headers.");
            var bodyToken = beginResponseBody == null ? token : beginResponseBody(status);
            reader.UseCancellationToken(bodyToken);
            bodyToken.ThrowIfCancellationRequested();

            byte[] bytes;
            if (streamToFile)
            {
                var count = CopyBody(reader, fields, status, chunked, hasLength, exactLength, limit,
                    responseSink.Destination, Math.Min(4 * 1024 * 1024, Math.Max(MaxChunkMetadataBytes, limit / 128)));
                responseSink.Complete(count);
                bytes = new byte[0];
            }
            else
            {
                using (var output = new MemoryStream())
                {
                    CopyBody(reader, fields, status, chunked, hasLength, exactLength, limit, output, MaxChunkMetadataBytes);
                    bytes = output.ToArray();
                }
            }

            if (gzip) bytes = DecodeGzip(bytes, limit, bodyToken);
            if (status == 205 && bytes.Length != 0) throw Invalid("A reset-content response contains a body.");

            var response = new HttpResponseMessage((HttpStatusCode)status)
            {
                Version = new Version(1, 1), ReasonPhrase = reason, RequestMessage = request,
                Content = new ByteArrayContent(bytes)
            };
            try
            {
                foreach (var field in fields)
                {
                    if (IsHopOrCookieHeader(field.Name) || hopHeaders.Contains(field.Name)
                        || field.Name.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)
                        || field.Name.Equals("Content-Encoding", StringComparison.OrdinalIgnoreCase)) continue;
                    if (!response.Headers.TryAddWithoutValidation(field.Name, field.Value)
                        && !response.Content.Headers.TryAddWithoutValidation(field.Name, field.Value))
                        throw Invalid("A response header is not supported.");
                }
                response.Content.Headers.ContentLength = bytes.Length;
                return response;
            }
            catch { response.Dispose(); throw; }
        }

        private static void ReadStatus(string line, out int status, out string reason)
        {
            if (line.Length < 13 || !line.StartsWith("HTTP/1.1 ", StringComparison.Ordinal) || line[12] != ' '
                || line[9] < '1' || line[9] > '5' || line[10] < '0' || line[10] > '9' || line[11] < '0' || line[11] > '9')
                throw Invalid("The HTTP response status is invalid.");
            status = (line[9] - '0') * 100 + (line[10] - '0') * 10 + line[11] - '0';
            reason = line.Substring(13);
            ValidateFieldValue(reason);
        }

        private static List<Field> ReadFields(Reader reader)
        {
            var fields = new List<Field>();
            while (true)
            {
                var line = reader.ReadHeaderLine();
                if (line.Length == 0) return fields;
                reader.CountHeader();
                fields.Add(ParseField(line));
            }
        }

        private static Field ParseField(string line)
        {
            var colon = line.IndexOf(':');
            if (colon <= 0) throw Invalid("An HTTP response header is invalid.");
            var name = line.Substring(0, colon);
            ValidateName(name);
            var value = line.Substring(colon + 1).Trim(' ', '\t');
            ValidateFieldValue(value);
            return new Field(name, value);
        }

        private static Dictionary<string, string> ValidateResponseFields(List<Field> fields)
        {
            var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var field in fields)
            {
                if (!IsSingletonHeader(field.Name)) continue;
                if (result.ContainsKey(field.Name)) throw Invalid("A response framing or singleton header is duplicated.");
                result.Add(field.Name, field.Value);
            }
            return result;
        }

        private static bool IsSingletonHeader(string name)
        {
            switch (name.ToLowerInvariant())
            {
                case "content-length": case "transfer-encoding": case "content-encoding": case "content-type":
                case "content-range": case "content-disposition": case "location": case "connection": case "trailer":
                case "host": case "expect": case "upgrade": case "etag": case "last-modified": case "date":
                case "expires": case "retry-after": return true;
                default: return false;
            }
        }

        private static bool IsHopOrCookieHeader(string name)
        {
            switch (name.ToLowerInvariant())
            {
                case "connection": case "keep-alive": case "transfer-encoding": case "te": case "trailer":
                case "upgrade": case "proxy-connection": case "proxy-authenticate": case "proxy-authorization":
                case "set-cookie": case "set-cookie2": return true;
                default: return false;
            }
        }

        private static HashSet<string> ConnectionHeaderNames(Dictionary<string, string> singletons)
        {
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            string value;
            if (!singletons.TryGetValue("Connection", out value)) return names;
            foreach (var part in value.Split(','))
            {
                var name = part.Trim(' ', '\t');
                ValidateName(name);
                if (IsSingletonHeader(name) || name.Equals("Authorization", StringComparison.OrdinalIgnoreCase)
                    || name.Equals("WWW-Authenticate", StringComparison.OrdinalIgnoreCase))
                    throw Invalid("The connection header changes response semantics.");
                names.Add(name);
            }
            return names;
        }

        private static void ValidateTrailerDeclaration(Dictionary<string, string> singletons)
        {
            string value;
            if (!singletons.TryGetValue("Trailer", out value)) return;
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var part in value.Split(','))
            {
                var name = part.Trim(' ', '\t');
                ValidateName(name);
                if (IsForbiddenTrailer(name) || !names.Add(name)) throw Invalid("The response trailer declaration is invalid.");
            }
        }

        private static bool IsForbiddenTrailer(string name)
        {
            return IsSingletonHeader(name) || IsHopOrCookieHeader(name) || IsRequestControlledHeader(name)
                || name.StartsWith("Content-", StringComparison.OrdinalIgnoreCase)
                || name.Equals("Authorization", StringComparison.OrdinalIgnoreCase)
                || name.Equals("WWW-Authenticate", StringComparison.OrdinalIgnoreCase)
                || name.Equals("Authentication-Info", StringComparison.OrdinalIgnoreCase)
                || name.Equals("Cache-Control", StringComparison.OrdinalIgnoreCase)
                || name.Equals("Vary", StringComparison.OrdinalIgnoreCase);
        }

        private static int CopyBody(Reader reader, List<Field> fields, int status, bool chunked, bool hasLength,
            int exactLength, int limit, Stream output, int chunkMetadataLimit)
        {
            if (status == 204) return 0;
            if (chunked) return CopyChunked(reader, fields, output, limit, chunkMetadataLimit);
            if (hasLength) { reader.CopyExact(output, exactLength); return exactLength; }
            return reader.CopyUntilClose(output, limit);
        }

        private static int CopyChunked(Reader reader, List<Field> fields, Stream output, int limit, int chunkMetadataLimit)
        {
                var total = 0;
                var metadataBytes = 0;
                while (true)
                {
                    var line = reader.ReadChunkLine(ref metadataBytes, chunkMetadataLimit);
                    var size = ParseChunkSize(line, limit - total);
                    if (size == 0)
                    {
                        var trailerNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                        foreach (var field in fields) trailerNames.Add(field.Name);
                        foreach (var field in ReadFields(reader))
                        {
                            if (IsForbiddenTrailer(field.Name) || !trailerNames.Add(field.Name))
                                throw Invalid("A response trailer is invalid.");
                            fields.Add(field);
                        }
                        return total;
                    }
                    reader.CopyExact(output, size);
                    total += size;
                    reader.RequireCrLf();
                    if (metadataBytes > chunkMetadataLimit - 2) throw Invalid("The chunk metadata exceeds its limit.");
                    metadataBytes += 2;
                }
        }

        private static int ParseChunkSize(string line, int remaining)
        {
            var semicolon = line.IndexOf(';');
            var digits = semicolon < 0 ? line : line.Substring(0, semicolon);
            if (digits.Length == 0 || digits.Length > 16) throw Invalid("The HTTP chunk size is invalid.");
            var value = 0;
            foreach (var ch in digits)
            {
                var digit = HexDigit(ch);
                if (digit < 0 || value > (remaining - digit) / 16 || remaining < digit)
                    throw Invalid("The HTTP chunk exceeds its limit or has an invalid size.");
                value = value * 16 + digit;
            }
            if (semicolon >= 0) ValidateChunkExtensions(line.Substring(semicolon));
            return value;
        }

        private static void ValidateChunkExtensions(string text)
        {
            var index = 0;
            while (index < text.Length)
            {
                if (text[index++] != ';') throw Invalid("An HTTP chunk extension is invalid.");
                var start = index;
                while (index < text.Length && IsToken(text[index])) index++;
                if (index == start) throw Invalid("An HTTP chunk extension is invalid.");
                if (index == text.Length || text[index] == ';') continue;
                if (text[index++] != '=') throw Invalid("An HTTP chunk extension is invalid.");
                if (index < text.Length && text[index] == '"')
                {
                    index++;
                    var closed = false;
                    while (index < text.Length)
                    {
                        var ch = text[index++];
                        if (ch == '"') { closed = true; break; }
                        if (ch == '\\')
                        {
                            if (index == text.Length) throw Invalid("An HTTP chunk extension is invalid.");
                            ch = text[index++];
                        }
                        if (ch < 32 || ch > 126) throw Invalid("An HTTP chunk extension is invalid.");
                    }
                    if (!closed) throw Invalid("An HTTP chunk extension is invalid.");
                }
                else
                {
                    start = index;
                    while (index < text.Length && IsToken(text[index])) index++;
                    if (index == start) throw Invalid("An HTTP chunk extension is invalid.");
                }
                if (index < text.Length && text[index] != ';') throw Invalid("An HTTP chunk extension is invalid.");
            }
        }

        private static int ParseDecimal(string text, int limit)
        {
            if (String.IsNullOrEmpty(text)) throw Invalid("The HTTP body length is invalid.");
            var value = 0;
            foreach (var ch in text)
            {
                var digit = ch - '0';
                if (digit < 0 || digit > 9 || limit < digit || value > (limit - digit) / 10)
                    throw Invalid("The HTTP body length exceeds its limit or is invalid.");
                value = value * 10 + digit;
            }
            return value;
        }

        private static byte[] DecodeGzip(byte[] compressed, int limit, CancellationToken token)
        {
            // Use the framework DEFLATE implementation. Parse only the gzip envelope here:
            // Framework 4.x GZipStream can tolerate a missing trailer. One-byte input reads
            // expose the exact end of a DEFLATE member, rejecting concatenation/trailing data.
            if (compressed.Length < 18 || compressed[0] != 31 || compressed[1] != 139
                || compressed[2] != 8 || (compressed[3] & 224) != 0)
                throw Invalid("The gzip response is invalid.");
            var trailer = compressed.Length - 8;
            var index = 10;
            var flags = compressed[3];
            if ((flags & 4) != 0)
            {
                if (index > trailer - 2) throw Invalid("The gzip response is truncated.");
                var extraLength = compressed[index] | compressed[index + 1] << 8;
                index += 2;
                if (extraLength > trailer - index) throw Invalid("The gzip response is truncated.");
                index += extraLength;
            }
            if ((flags & 8) != 0) SkipGzipString(compressed, ref index, trailer);
            if ((flags & 16) != 0) SkipGzipString(compressed, ref index, trailer);
            if ((flags & 2) != 0)
            {
                if (index > trailer - 2) throw Invalid("The gzip response is truncated.");
                var expected = compressed[index] | compressed[index + 1] << 8;
                if ((Crc32(compressed, 0, index) & 65535) != expected) throw Invalid("The gzip response header is invalid.");
                index += 2;
            }
            if (index >= trailer) throw Invalid("The gzip response is truncated.");
            byte[] decoded;
            using (var input = new MemoryStream(compressed, index, trailer - index, false))
            using (var exactInput = new SingleByteReadStream(input, token))
            using (var inflater = new DeflateStream(exactInput, CompressionMode.Decompress, true))
            using (var output = new MemoryStream())
            {
                var buffer = new byte[4096];
                try
                {
                    while (true)
                    {
                        token.ThrowIfCancellationRequested();
                        var count = inflater.Read(buffer, 0, buffer.Length);
                        if (count == 0) break;
                        if (count > limit - output.Length) throw Invalid("The decompressed response exceeds its limit.");
                        output.Write(buffer, 0, count);
                    }
                }
                catch (InvalidDataException) { throw Invalid("The gzip response is invalid."); }
                if (exactInput.ReadBeyondEnd || input.Position != input.Length)
                    throw Invalid("The gzip response is truncated or contains additional data.");
                decoded = output.ToArray();
            }
            if (ReadUInt32(compressed, trailer) != Crc32(decoded, 0, decoded.Length)
                || ReadUInt32(compressed, trailer + 4) != (uint)decoded.Length)
                throw Invalid("The gzip response checksum or length is invalid.");
            return decoded;
        }

        private static void SkipGzipString(byte[] bytes, ref int index, int end)
        {
            while (index < end) if (bytes[index++] == 0) return;
            throw Invalid("The gzip response header is truncated.");
        }

        private static uint ReadUInt32(byte[] bytes, int offset)
        {
            return (uint)bytes[offset] | (uint)bytes[offset + 1] << 8
                | (uint)bytes[offset + 2] << 16 | (uint)bytes[offset + 3] << 24;
        }

        private static uint[] CreateCrcTable()
        {
            var table = new uint[256];
            for (var i = 0; i < table.Length; i++)
            {
                var value = (uint)i;
                for (var bit = 0; bit < 8; bit++) value = (value & 1) != 0 ? 0xedb88320U ^ (value >> 1) : value >> 1;
                table[i] = value;
            }
            return table;
        }

        private static uint Crc32(byte[] bytes, int offset, int count)
        {
            var crc = UInt32.MaxValue;
            for (var i = offset; i < offset + count; i++) crc = CrcTable[(crc ^ bytes[i]) & 255] ^ (crc >> 8);
            return ~crc;
        }

        private static void ValidateName(string name)
        {
            if (String.IsNullOrEmpty(name)) throw Invalid("An HTTP header name is invalid.");
            foreach (var ch in name) if (!IsToken(ch)) throw Invalid("An HTTP header name is invalid.");
        }

        private static bool IsToken(char ch)
        {
            return ch >= '0' && ch <= '9' || ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z'
                || "!#$%&'*+-.^_`|~".IndexOf(ch) >= 0;
        }

        private static int HexDigit(char ch)
        {
            if (ch >= '0' && ch <= '9') return ch - '0';
            if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
            if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
            return -1;
        }

        private static void ValidateAscii(string text, bool spaces)
        {
            if (text == null) throw Invalid("An HTTP request value is invalid.");
            foreach (var ch in text)
                if (ch < (spaces ? 32 : 33) || ch > 126) throw Invalid("An HTTP request value is invalid.");
        }

        private static void ValidateFieldValue(string value)
        {
            foreach (var ch in value)
                if (ch < 32 && ch != '\t' || ch == 127) throw Invalid("An HTTP response header value is invalid.");
        }

        private static HttpRequestException Invalid(string message) { return new HttpRequestException(message); }

        private sealed class Field
        {
            internal Field(string name, string value) { Name = name; Value = value; }
            internal readonly string Name;
            internal readonly string Value;
        }

        private sealed class OutboundRequest
        {
            internal byte[] Headers;
            internal byte[] Body;
        }

        private sealed class Reader
        {
            private readonly Stream stream;
            private CancellationToken token;
            private int headerBytes;
            private int headerCount;
            internal Reader(Stream stream, CancellationToken token) { this.stream = stream; this.token = token; }
            internal void UseCancellationToken(CancellationToken value) { token = value; }
            internal void CountHeader()
            {
                if (++headerCount > MaxHeaderCount) throw Invalid("The response headers exceed their limit.");
            }
            internal string ReadHeaderLine() { return ReadLine(ref headerBytes, MaxHeaderBytes); }
            internal string ReadChunkLine(ref int metadataBytes, int maximum) { return ReadLine(ref metadataBytes, maximum); }
            private string ReadLine(ref int totalBytes, int totalLimit)
            {
                var line = new StringBuilder();
                while (true)
                {
                    var value = ReadByte();
                    if (value < 0) throw Invalid("The HTTP response headers or chunks are truncated.");
                    if (++totalBytes > totalLimit || line.Length + 1 > MaxLineBytes)
                        throw Invalid("The response headers or chunk metadata exceed their limit.");
                    if (value == 13)
                    {
                        if (++totalBytes > totalLimit || line.Length + 2 > MaxLineBytes || ReadByte() != 10)
                            throw Invalid("An HTTP response line ending is invalid.");
                        return line.ToString();
                    }
                    if (value == 10) throw Invalid("An HTTP response line ending is invalid.");
                    line.Append((char)value);
                }
            }
            private int ReadByte() { token.ThrowIfCancellationRequested(); return stream.ReadByte(); }
            internal void RequireCrLf()
            {
                if (ReadByte() != 13 || ReadByte() != 10) throw Invalid("An HTTP chunk terminator is invalid.");
            }
            internal void CopyExact(Stream output, int count)
            {
                var buffer = new byte[Math.Min(4096, count)];
                while (count > 0)
                {
                    token.ThrowIfCancellationRequested();
                    var read = stream.Read(buffer, 0, Math.Min(buffer.Length, count));
                    if (read <= 0) throw Invalid("The HTTP response body is truncated.");
                    output.Write(buffer, 0, read);
                    count -= read;
                }
            }
            internal int CopyUntilClose(Stream output, int limit)
            {
                    var total = 0;
                    var buffer = new byte[4096];
                    while (true)
                    {
                        token.ThrowIfCancellationRequested();
                        var read = stream.Read(buffer, 0, (int)Math.Min(buffer.Length, (long)limit - total + 1));
                        if (read == 0) return total;
                        if (read > limit - total) throw Invalid("The response body exceeds its limit.");
                        output.Write(buffer, 0, read);
                        total += read;
                    }
            }
        }

        private sealed class BoundedWriteStream : Stream
        {
            private readonly MemoryStream output = new MemoryStream();
            private readonly int limit;
            private readonly CancellationToken token;
            internal BoundedWriteStream(int limit, CancellationToken token) { this.limit = limit; this.token = token; }
            internal byte[] ToArray() { return output.ToArray(); }
            public override void Write(byte[] buffer, int offset, int count)
            {
                token.ThrowIfCancellationRequested();
                if (count > limit - output.Length) throw Invalid("The request body exceeds its limit.");
                output.Write(buffer, offset, count);
            }
            public override void WriteByte(byte value)
            {
                token.ThrowIfCancellationRequested();
                if (output.Length == limit) throw Invalid("The request body exceeds its limit.");
                output.WriteByte(value);
            }
            protected override void Dispose(bool disposing) { if (disposing) output.Dispose(); base.Dispose(disposing); }
            public override bool CanRead { get { return false; } }
            public override bool CanSeek { get { return false; } }
            public override bool CanWrite { get { return true; } }
            public override long Length { get { return output.Length; } }
            public override long Position { get { return output.Length; } set { throw new NotSupportedException(); } }
            public override void Flush() { }
            public override int Read(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
            public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
            public override void SetLength(long value) { throw new NotSupportedException(); }
        }

        private sealed class SingleByteReadStream : Stream
        {
            private readonly Stream input;
            private readonly CancellationToken token;
            internal bool ReadBeyondEnd;
            internal SingleByteReadStream(Stream input, CancellationToken token) { this.input = input; this.token = token; }
            public override int Read(byte[] buffer, int offset, int count)
            {
                token.ThrowIfCancellationRequested();
                if (count == 0) return 0;
                var read = input.Read(buffer, offset, 1);
                if (read == 0) ReadBeyondEnd = true;
                return read;
            }
            public override bool CanRead { get { return true; } }
            public override bool CanSeek { get { return false; } }
            public override bool CanWrite { get { return false; } }
            public override long Length { get { throw new NotSupportedException(); } }
            public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
            public override void Flush() { }
            public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
            public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
            public override void SetLength(long value) { throw new NotSupportedException(); }
        }
    }
}
