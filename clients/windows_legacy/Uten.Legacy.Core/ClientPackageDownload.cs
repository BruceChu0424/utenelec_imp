using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core
{
    public sealed partial class SessionCoordinator
    {
        /// <summary>Save a verified package from this session's approved issuer. Does not launch/install it.</summary>
        public Task<string> DownloadClientPackageAsync(string releaseId, string expectedSha256, long expectedBytes,
            string runtimeFamily, string outputPath, CancellationToken cancellationToken, IProgress<long> progress = null)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Guid id;
            var family = runtimeFamily ?? "flutter";
            if (!Guid.TryParseExact(releaseId, "D", out id) || expectedSha256 == null
                || !Regex.IsMatch(expectedSha256, "^[0-9a-fA-F]{64}$") || expectedBytes < 1
                || expectedBytes > HttpResponseSink.MaximumPackageBytes || (family != "flutter" && family != "wpf_legacy"))
                throw new ApiException("INVALID_DOWNLOAD_METADATA", "软件下载信息无效，请刷新已发布版本后重试。");
            string finalPath;
            try { finalPath = Path.GetFullPath(outputPath); ValidateDownloadDestination(finalPath); }
            catch (Exception error) when (error is ArgumentException || error is NotSupportedException || error is IOException || error is UnauthorizedAccessException)
            { throw new ApiException("INVALID_DOWNLOAD_DESTINATION", "请选择存在且可写的本机文件夹，目标不能是链接或目录。"); }
            Scope scope;
            lock (gate)
            {
                RequireAuthenticated();
                if (credentials.User.MustChangePassword) throw new ApiException("PASSWORD_CHANGE_REQUIRED", "请先修改登录密码。", 403);
                scope = CaptureLocked();
            }
            var relative = "client-updates/" + id.ToString("D") + "/download" + (family == "wpf_legacy" ? "?runtimeFamily=wpf_legacy" : "");
            // File IO/hash work never inherits the WPF dispatcher context.
            return Task.Run(() => DownloadOwnedPackageAsync(scope, relative, expectedSha256.ToLowerInvariant(), expectedBytes,
                finalPath, cancellationToken, progress));
        }

        private async Task<string> DownloadOwnedPackageAsync(Scope scope, string relativePath, string expectedHash,
            long expectedBytes, string finalPath, CancellationToken callerCancellation, IProgress<long> progress)
        {
            string temporary = null;
            var ownsTemporary = false;
            using (var lifetime = CancellationTokenSource.CreateLinkedTokenSource(callerCancellation, scope.Cancellation))
            {
                // Separate overall package budget; ordinary JSON and socket-stall limits stay unchanged.
                lifetime.CancelAfter(TimeSpan.FromMinutes(30));
                try
                {
                    var token = lifetime.Token;
                    var owned = await EnsureAccessAsync(scope, false, null, token).ConfigureAwait(false);
                    token.ThrowIfCancellationRequested();
                    RequireScope(scope);
                    ValidateDownloadDestination(finalPath);
                    temporary = Path.Combine(Path.GetDirectoryName(finalPath), ".uten-download-" + Guid.NewGuid().ToString("N") + ".tmp");
                    var ownedFile = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.SequentialScan);
                    ownsTemporary = true;
                    using (var file = ownedFile)
                    using (var verified = new VerifiedDownloadStream(file, expectedBytes, token, () => RequireScope(scope), progress))
                    {
                        var uri = scope.Endpoint.Resolve(relativePath);
                        for (var attempt = 0; ; attempt++)
                        {
                            token.ThrowIfCancellationRequested();
                            RequireScope(scope);
                            var sink = new HttpResponseSink(verified, expectedBytes, configuration.MaxResponseBytes, uri.AbsolutePath, uri.Query);
                            using (var request = new HttpRequestMessage(HttpMethod.Get, uri))
                            {
                                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", owned.AccessToken);
                                request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/octet-stream"));
                                request.Properties[HttpResponseSink.RequestProperty] = sink;
                                using (var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false))
                                {
                                    RequireScope(scope);
                                    token.ThrowIfCancellationRequested();
                                    var status = (int)response.StatusCode;
                                    if (status >= 300 && status <= 399 || response.RequestMessage?.RequestUri != null && response.RequestMessage.RequestUri != uri)
                                        throw new ApiException("REDIRECT_BLOCKED", "软件下载返回了重定向，未继续下载。", status);
                                    if (status != 200)
                                    {
                                        if (status >= 200 && status <= 299)
                                            throw new ApiException("INVALID_DOWNLOAD_RESPONSE", "下载没有返回完整文件。", status);
                                        var failure = ErrorFrom(await ReadDownloadErrorAsync(response, token).ConfigureAwait(false), false);
                                        if (attempt == 0 && verified.Written == 0 && failure.StatusCode == 401
                                            && failure.HasResponseCode && failure.Code == "UNAUTHORIZED")
                                        {
                                            owned = await EnsureAccessAsync(scope, true, owned, token).ConfigureAwait(false);
                                            continue; // Safe GET replay only: no package bytes have been written.
                                        }
                                        if (failure.Code != "VALIDATION_FAILED" && IsDefinitiveRejection(failure)) RejectCurrent(scope, owned);
                                        throw failure;
                                    }
                                    if (!sink.Completed)
                                    {
                                        // Injected high-level handlers can expose a stream directly. Production
                                        // uses the same HTTP codec's sink path and never buffers the package.
                                        if (response.Content == null || response.Content.Headers.ContentRange != null
                                            || response.Content.Headers.ContentEncoding.Any()
                                            || response.Content.Headers.ContentLength.HasValue && response.Content.Headers.ContentLength.Value != expectedBytes)
                                            throw new ApiException("INVALID_DOWNLOAD_LENGTH", "下载长度或内容编码与发布信息不一致。");
                                        using (var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                                        {
                                            var buffer = new byte[65536];
                                            int count;
                                            while ((count = await input.ReadAsync(buffer, 0, buffer.Length, token).ConfigureAwait(false)) != 0)
                                                verified.Write(buffer, 0, count);
                                        }
                                        sink.Complete(verified.Written);
                                    }
                                    verified.Verify(expectedHash);
                                    token.ThrowIfCancellationRequested();
                                    RequireScope(scope);
                                    file.Flush(true);
                                    break;
                                }
                            }
                        }
                    }
                    lock (gate)
                    {
                        RequireScopeLocked(scope);
                        lifetime.Token.ThrowIfCancellationRequested();
                        ValidateDownloadDestination(finalPath);
                        if (File.Exists(finalPath)) File.Replace(temporary, finalPath, null);
                        else File.Move(temporary, finalPath);
                        temporary = null;
                    }
                    return finalPath;
                }
                catch (OperationCanceledException)
                {
                    RequireScope(scope);
                    if (callerCancellation.IsCancellationRequested) throw;
                    throw new ApiException("DOWNLOAD_TIMEOUT", "软件下载超时，未保存未验证的文件，请重新下载。");
                }
                catch (HttpRequestException error)
                {
                    RequireScope(scope);
                    if (IsTlsFailure(error)) throw new ApiException("TLS_VALIDATION_FAILED", "软件下载服务器证书验证失败。");
                    throw new ApiException("DOWNLOAD_NETWORK", "软件下载中断或响应不完整，未保存未验证的文件。");
                }
                catch (Exception error) when (error is IOException || error is UnauthorizedAccessException || error is CryptographicException)
                { RequireScope(scope); throw new ApiException("DOWNLOAD_IO", "软件下载读取或保存失败，请检查目标文件夹。"); }
                finally
                {
                    // Only the exact CreateNew GUID file owned by this operation is eligible for cleanup.
                    if (ownsTemporary && temporary != null && File.Exists(temporary))
                    {
                        try { File.Delete(temporary); }
                        catch (Exception error) when (error is IOException || error is UnauthorizedAccessException)
                        { throw new ApiException("DOWNLOAD_TEMP_CLEANUP_FAILED", "下载临时文件清理失败，请关闭占用后联系管理员核对。"); }
                    }
                }
            }
        }

        private async Task<Reply> ReadDownloadErrorAsync(HttpResponseMessage response, CancellationToken token)
        {
            if (response.Content == null) return new Reply((int)response.StatusCode, "", ReadScopeHeaders.Capture(response));
            if (response.Content.Headers.ContentLength > configuration.MaxResponseBytes)
                throw new ApiException("RESPONSE_TOO_LARGE", "下载错误响应超出读取上限。");
            using (var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
            using (var bytes = new MemoryStream())
            {
                var buffer = new byte[8192]; int count;
                while ((count = await input.ReadAsync(buffer, 0, buffer.Length, token).ConfigureAwait(false)) != 0)
                {
                    if (bytes.Length + count > configuration.MaxResponseBytes) throw new ApiException("RESPONSE_TOO_LARGE", "下载错误响应超出读取上限。");
                    bytes.Write(buffer, 0, count);
                }
                return new Reply((int)response.StatusCode, new UTF8Encoding(false, true).GetString(bytes.ToArray()), ReadScopeHeaders.Capture(response));
            }
        }
        private static void ValidateDownloadDestination(string path)
        {
            var directory = Path.GetDirectoryName(path);
            if (String.IsNullOrWhiteSpace(Path.GetFileName(path)) || directory == null || !Directory.Exists(directory)
                || Directory.Exists(path) || (File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0
                || File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Unsupported download destination");
        }

        private sealed class VerifiedDownloadStream : Stream
        {
            private readonly Stream destination;
            private readonly long expected;
            private readonly CancellationToken cancellation;
            private readonly Action checkScope;
            private readonly IProgress<long> progress;
            private readonly SHA256 hash = SHA256.Create();
            private readonly Stopwatch reporting = Stopwatch.StartNew();
            internal long Written { get; private set; }
            internal VerifiedDownloadStream(Stream destination, long expected, CancellationToken cancellation, Action checkScope, IProgress<long> progress)
            { this.destination = destination; this.expected = expected; this.cancellation = cancellation; this.checkScope = checkScope; this.progress = progress; if (progress != null) progress.Report(0); }
            public override void Write(byte[] buffer, int offset, int count)
            {
                cancellation.ThrowIfCancellationRequested(); checkScope();
                if (count < 0 || count > expected - Written) throw new ApiException("INVALID_DOWNLOAD_LENGTH", "下载内容超过发布的文件大小。");
                destination.Write(buffer, offset, count);
                hash.TransformBlock(buffer, offset, count, null, 0);
                Written += count;
                if (progress != null && (Written == expected || reporting.ElapsedMilliseconds >= 100))
                { reporting.Restart(); progress.Report(Written); }
            }
            internal void Verify(string expectedHash)
            {
                if (Written != expected) throw new ApiException("INVALID_DOWNLOAD_LENGTH", "下载未达到发布的完整文件大小。");
                hash.TransformFinalBlock(new byte[0], 0, 0);
                var actual = BitConverter.ToString(hash.Hash).Replace("-", "").ToLowerInvariant();
                if (actual != expectedHash) throw new ApiException("DOWNLOAD_CHECKSUM_MISMATCH", "下载文件校验不一致，已丢弃临时文件，请重新下载。");
            }
            protected override void Dispose(bool disposing) { if (disposing) hash.Dispose(); base.Dispose(disposing); }
            public override void Flush() { destination.Flush(); }
            public override bool CanRead { get { return false; } }
            public override bool CanSeek { get { return false; } }
            public override bool CanWrite { get { return true; } }
            public override long Length { get { return Written; } }
            public override long Position { get { return Written; } set { throw new NotSupportedException(); } }
            public override int Read(byte[] buffer,int offset,int count) { throw new NotSupportedException(); }
            public override long Seek(long offset,SeekOrigin origin) { throw new NotSupportedException(); }
            public override void SetLength(long value) { throw new NotSupportedException(); }
        }
    }
}
