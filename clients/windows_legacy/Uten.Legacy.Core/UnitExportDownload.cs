using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core
{
    public sealed class UnitExportFile
    {
        public string Path { get; private set; }
        public long SizeBytes { get; private set; }
        /// <summary>Digest of the received file, not a fabricated server receipt/digest.</summary>
        public string Sha256 { get; private set; }
        internal UnitExportFile(string path, long bytes, string sha) { Path = path; SizeBytes = bytes; Sha256 = sha; }
    }

    public sealed partial class SessionCoordinator
    {
        public Task<UnitExportFile> DownloadUnitExportJobAsync(string jobId, string password, string outputPath,
            MutationOwnerSnapshot owner, CancellationToken token, IProgress<long> progress = null)
        {
            jobId = CanonicalCommandId(jobId);
            return BeginUnitExportDownload("report-export-jobs/" + jobId + "/download",
                new Dictionary<string, object> { ["password"] = ValidateExportPassword(password) }, outputPath, owner, token, progress);
        }
        /// <summary>Only for an unavailable durable export-job capability; never a fallback
        /// after a possibly accepted submit. The UI owns that explicit capability decision.</summary>
        public Task<UnitExportFile> DownloadLegacyUnitExportAsync(IDictionary<string, string> parameters, string password,
            string projectionJson, string outputPath, MutationOwnerSnapshot owner, CancellationToken token, IProgress<long> progress = null)
        {
            var body = new Dictionary<string, object> { ["password"] = ValidateExportPassword(password) };
            if (projectionJson != null)
            {
                if (new UTF8Encoding(false, true).GetByteCount(projectionJson) > 12000) throw new ApiException("EXPORT_PROJECTION_INVALID", "导出列定义过大。");
                var projection = JsonValue.ParseObject(projectionJson, 12000);
                if (projection.Keys.Any(key => key != "tableKey" && key != "scope" && key != "columns"))
                    throw new ApiException("EXPORT_PROJECTION_INVALID", "导出列定义包含不支持的字段。");
                body.Add("columnProjection", projection);
            }
            return BeginUnitExportDownload("master/units/export" + UnitExportQuery(parameters), body, outputPath, owner, token, progress);
        }
        private Task<UnitExportFile> BeginUnitExportDownload(string relative, IDictionary<string, object> body, string outputPath,
            MutationOwnerSnapshot owner, CancellationToken token, IProgress<long> progress)
        {
            token.ThrowIfCancellationRequested();
            string path;
            try { path = System.IO.Path.GetFullPath(outputPath); ValidateDownloadDestination(path); }
            catch (Exception error) when (error is IOException || error is UnauthorizedAccessException || error is ArgumentException || error is NotSupportedException)
            { throw new ApiException("EXPORT_DESTINATION_INVALID", "请选择存在且可写的本机文件夹，不能选择链接或目录。"); }
            Scope scope; CancellationToken readLifetime;
            lock (gate)
            {
                RequireMutationOwnerLocked(owner); RequireMutationPermissionsLocked(new[] { "unit:export" });
                scope = CaptureLocked(); readLifetime = readCancellation.Token;
            }
            string passwordBody = JsonValue.Serialize(body);
            return Task.Run(() => DownloadOwnedUnitExportAsync(relative, passwordBody, path, owner, scope, readLifetime, token, progress));
        }
        private async Task<UnitExportFile> DownloadOwnedUnitExportAsync(string relative, string passwordBody, string path,
            MutationOwnerSnapshot owner, Scope scope, CancellationToken readLifetime, CancellationToken caller, IProgress<long> progress)
        {
            string temporary = null; bool created = false;
            using (var wait = CancellationTokenSource.CreateLinkedTokenSource(caller, scope.Cancellation, readLifetime))
            {
                wait.CancelAfter(TimeSpan.FromMinutes(30)); var token = wait.Token;
                Action require = () =>
                {
                    token.ThrowIfCancellationRequested();
                    lock (gate) { RequireMutationOwnerLocked(owner); RequireMutationPermissionsLocked(new[] { "unit:export" }); }
                };
                try
                {
                    var credentials = await EnsureAccessAsync(scope, false, null, token).ConfigureAwait(false);
                    require(); ValidateDownloadDestination(path);
                    temporary = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(path), ".uten-export-" + Guid.NewGuid().ToString("N") + ".tmp");
                    using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.SequentialScan))
                    {
                        created = true;
                        using (var bounded = new ExportWriteStream(file, require, progress))
                        {
                            var uri = scope.Endpoint.Resolve(relative);
                            var sink = HttpResponseSink.BoundedExport(bounded, 512 * 1024 * 1024, configuration.MaxResponseBytes, uri.AbsolutePath, uri.Query);
                            using (var request = new HttpRequestMessage(HttpMethod.Post, uri))
                            {
                                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", credentials.AccessToken);
                                request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"));
                                request.Content = new StringContent(passwordBody, new UTF8Encoding(false, true), "application/json");
                                request.Properties[HttpResponseSink.RequestProperty] = sink;
                                // This is a read of an already named artifact (or explicit legacy read).
                                // No 401/timeout/error automatically replays even this password-bearing POST.
                                using (var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false))
                                {
                                    require();
                                    int status = (int)response.StatusCode;
                                    if (status >= 300 && status < 400 || response.RequestMessage?.RequestUri != null && response.RequestMessage.RequestUri != uri)
                                        throw new ApiException("REDIRECT_BLOCKED", "导出返回了重定向，未继续下载。", status);
                                    if (status != 200)
                                    {
                                        if (status >= 200 && status < 300) throw new ApiException("EXPORT_DOWNLOAD_INCOMPLETE", "导出没有返回完整文件。", status);
                                        var failure = ErrorFrom(await ReadDownloadErrorAsync(response, token).ConfigureAwait(false), false);
                                        if (failure.Code != "VALIDATION_FAILED" && IsDefinitiveRejection(failure)) RejectCurrent(scope, credentials);
                                        throw failure;
                                    }
                                    string media = response.Content?.Headers.ContentType?.MediaType;
                                    if (media != "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" && media != "application/octet-stream")
                                        throw new ApiException("EXPORT_DOWNLOAD_TYPE", "导出没有返回Excel文件，原文件未被替换。");
                                    if (!sink.Completed)
                                    {
                                        var content = response.Content;
                                        if (content == null || content.Headers.ContentRange != null || content.Headers.ContentEncoding.Any()
                                            || !content.Headers.ContentLength.HasValue || content.Headers.ContentLength < 1
                                            || content.Headers.ContentLength > 512L * 1024 * 1024)
                                            throw new ApiException("EXPORT_DOWNLOAD_LENGTH", "导出缺少完整且有界的文件长度。");
                                        long expected = content.Headers.ContentLength.Value;
                                        using (var input = await content.ReadAsStreamAsync().ConfigureAwait(false))
                                        {
                                            byte[] bytes = new byte[65536]; int count;
                                            while ((count = await input.ReadAsync(bytes, 0, bytes.Length, token).ConfigureAwait(false)) != 0) bounded.Write(bytes, 0, count);
                                        }
                                        if (bounded.Written != expected) throw new ApiException("EXPORT_DOWNLOAD_LENGTH", "导出读取不完整，原文件未被替换。");
                                        sink.Complete(bounded.Written);
                                    }
                                    string sha = bounded.Finish(); require(); file.Flush(true);
                                    var result = new UnitExportFile(path, bounded.Written, sha);
                                    // Close owned handles before atomic publication; a finally removes only this GUID on failure.
                                    bounded.Flush();
                                    file.Close();
                                    lock (gate)
                                    {
                                        RequireMutationOwnerLocked(owner); RequireMutationPermissionsLocked(new[] { "unit:export" }); token.ThrowIfCancellationRequested();
                                        ValidateDownloadDestination(path);
                                        if (File.Exists(path)) File.Replace(temporary, path, null); else File.Move(temporary, path);
                                        temporary = null;
                                    }
                                    return result;
                                }
                            }
                        }
                    }
                }
                catch (OperationCanceledException)
                {
                    if (caller.IsCancellationRequested) throw;
                    lock (gate) RequireMutationOwnerLocked(owner);
                    throw new ApiException("EXPORT_DOWNLOAD_STOPPED", "导出下载超时或读取范围变化，原导出任务保留；未保存部分文件。");
                }
                catch (HttpRequestException)
                { throw new ApiException("EXPORT_DOWNLOAD_NETWORK", "导出下载中断或响应异常，原导出任务保留；未保存部分文件。"); }
                catch (Exception error) when (error is IOException || error is UnauthorizedAccessException || error is CryptographicException)
                { throw new ApiException("EXPORT_DOWNLOAD_IO", "导出未能完整保存，请检查磁盘和目标目录；原文件未被替换。"); }
                finally
                {
                    if (created && temporary != null && File.Exists(temporary)) File.Delete(temporary);
                }
            }
        }
        private static string ValidateExportPassword(string password)
        { if (password != null && password.Length > 128) throw new ApiException("EXPORT_PASSWORD_INVALID", "导出密码不能超过128位。"); return password; }
        public static string UnitExportQuery(IDictionary<string, string> parameters)
        {
            if (parameters == null || parameters.Count == 0) return "";
            var parts = new List<string>();
            foreach (var key in parameters.Keys.OrderBy(value => value, StringComparer.Ordinal))
            {
                if (key != "keyword" && key != "code" && key != "name" && key != "status" && key != "dimension" && key != "nullFields")
                    throw new ApiException("EXPORT_QUERY_INVALID", "导出查询包含不支持的字段。");
                string value = parameters[key];
                if (value == null || value.Length > 2000 || value.Any(Char.IsControl)) throw new ApiException("EXPORT_QUERY_INVALID", "导出筛选值无效。");
                if (key == "nullFields" && value.Split(',').Any(field => field != "code" && field != "name" && field != "status" && field != "dimension"))
                    throw new ApiException("EXPORT_QUERY_INVALID", "导出空值筛选无效。");
                parts.Add(key + "=" + Uri.EscapeDataString(value));
            }
            return "?" + String.Join("&", parts);
        }
        private sealed class ExportWriteStream : Stream
        {
            private readonly Stream destination; private readonly Action require; private readonly IProgress<long> progress;
            private readonly SHA256 hash = SHA256.Create(); private readonly byte[] prefix = new byte[8];
            private readonly Stopwatch reportTime = Stopwatch.StartNew(); private int prefixCount; private bool finished;
            internal long Written { get; private set; }
            internal ExportWriteStream(Stream destination, Action require, IProgress<long> progress)
            { this.destination = destination; this.require = require; this.progress = progress; }
            public override void Write(byte[] buffer, int offset, int count)
            {
                require();
                if (finished || count < 0 || count > 512L * 1024 * 1024 - Written) throw new IOException("Export response exceeded its bound.");
                int take = Math.Min(count, prefix.Length - prefixCount);
                if (take > 0) { Buffer.BlockCopy(buffer, offset, prefix, prefixCount, take); prefixCount += take; }
                destination.Write(buffer, offset, count); hash.TransformBlock(buffer, offset, count, buffer, offset); Written += count;
                if (reportTime.ElapsedMilliseconds >= 50) { progress?.Report(Written); reportTime.Restart(); }
            }
            internal string Finish()
            {
                require();
                bool zip = Written >= 22 && prefixCount >= 4 && prefix[0] == 0x50 && prefix[1] == 0x4b && prefix[2] == 3 && prefix[3] == 4;
                byte[] oleMagic = { 0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1 };
                bool ole = Written >= 512 && prefixCount == 8 && prefix.SequenceEqual(oleMagic);
                if (!zip && !ole) throw new ApiException("EXPORT_DOWNLOAD_TYPE", "导出内容不是普通或加密Excel工作簿。");
                hash.TransformFinalBlock(new byte[0], 0, 0); finished = true; progress?.Report(Written);
                return BitConverter.ToString(hash.Hash).Replace("-", "").ToLowerInvariant();
            }
            protected override void Dispose(bool disposing) { if (disposing) hash.Dispose(); base.Dispose(disposing); }
            public override void Flush() { destination.Flush(); }
            public override bool CanRead { get { return false; } } public override bool CanSeek { get { return false; } } public override bool CanWrite { get { return true; } }
            public override long Length { get { return Written; } } public override long Position { get { return Written; } set { throw new NotSupportedException(); } }
            public override int Read(byte[] b, int o, int c) { throw new NotSupportedException(); } public override long Seek(long o, SeekOrigin s) { throw new NotSupportedException(); }
            public override void SetLength(long value) { throw new NotSupportedException(); }
        }
    }
}
