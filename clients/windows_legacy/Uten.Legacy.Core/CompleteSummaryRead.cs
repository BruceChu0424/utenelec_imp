using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core
{
    public sealed class CompleteSummaryResponse
    {
        // Same complete-result text budget as the native complete-page collector.
        public const int MaximumTextBytes = 64 * 1024 * 1024;
        public IReadOnlyList<string> Pages { get; internal set; }
        public string CompletionJson { get; internal set; }
        public string ErrorCode { get; internal set; }
    }

    public sealed partial class SessionCoordinator
    {
        public Task<CompleteSummaryResponse> ReadCompleteGoodsSummariesAsync(string categoryId, string keyword, CancellationToken token)
        {
            Guid id;
            if (!String.IsNullOrWhiteSpace(categoryId) && (!Guid.TryParseExact(categoryId, "D", out id) || id == Guid.Empty))
                throw new ArgumentException("分类关系必须是 UUID。", nameof(categoryId));
            var filter = new Dictionary<string, object>();
            if (!String.IsNullOrWhiteSpace(categoryId)) filter.Add("categoryId", categoryId);
            if (!String.IsNullOrWhiteSpace(keyword)) filter.Add("keyword", keyword.Trim());
            return ReadCompleteMasterAsync("goods", filter, "goods:view", token);
        }

        public Task<CompleteSummaryResponse> ReadCompleteUnitSummariesAsync(string keyword, IDictionary<string, string> exact,
            IReadOnlyList<string> nullFields, CancellationToken token)
        {
            var allowed = new[] { "code", "name", "status", "dimension" };
            var filter = new Dictionary<string, object>();
            if (!String.IsNullOrWhiteSpace(keyword)) filter.Add("keyword", keyword.Trim());
            foreach (var entry in exact ?? new Dictionary<string, string>())
            {
                if (!allowed.Contains(entry.Key) || entry.Value == null) throw new ArgumentException("单位筛选无效。");
                filter.Add(entry.Key, entry.Value);
            }
            if (nullFields != null && nullFields.Count > 0)
            {
                var fields = nullFields.ToArray();
                if (fields.Any(field => !allowed.Contains(field) || filter.ContainsKey(field)) || fields.Distinct().Count() != fields.Length)
                    throw new ArgumentException("单位空值筛选无效。");
                filter.Add("nullFields", fields);
            }
            return ReadCompleteMasterAsync("units", filter, "unit:view", token);
        }

        private async Task<CompleteSummaryResponse> ReadCompleteMasterAsync(string kind, object filter, string permission, CancellationToken token)
        {
            // Reuses the one session owner, credential refresh, TLS/HTTP codec,
            // cancellation and publication fence; never enters the mutation journal.
            var reply = await ReadReplyAsync(HttpMethod.Post, "master/" + kind + "/summaries?complete=true",
                new Dictionary<string, object> { { "filter", filter }, { "page", 1 }, { "size", 100 } }, token,
                permission, completeSummary: true).ConfigureAwait(false);
            return reply.CompleteSummary ?? throw new ApiException("INCOMPLETE_READ_PROTOCOL", "完整资料流未完成，请重试。");
        }
    }

    // The existing managed HTTP codec pushes verified framing bytes into this
    // owned sink. Only one bounded line is decoded at a time, off the UI thread.
    internal sealed class CompleteSummaryStream : Stream
    {
        private readonly int maximumFrameBytes;
        private readonly CancellationToken token;
        private readonly MemoryStream line = new MemoryStream();
        private readonly List<string> pages = new List<string>();
        private long bytes;
        private string completion, error;
        internal CompleteSummaryStream(int maximumFrameBytes, CancellationToken token)
        { this.maximumFrameBytes = maximumFrameBytes; this.token = token; }
        public override void Write(byte[] buffer, int offset, int count)
        {
            token.ThrowIfCancellationRequested();
            if (count < 0 || bytes > CompleteSummaryResponse.MaximumTextBytes - count)
                throw new ApiException("SNAPSHOT_TOO_LARGE", "完整结果文字过多，请缩小筛选范围；不会返回截断结果。");
            bytes += count;
            int end = offset + count, start = offset;
            for (int i = offset; i < end; i++)
                if (buffer[i] == 10)
                {
                    Append(buffer, start, i - start); ReadLine(); start = i + 1;
                }
            Append(buffer, start, end - start);
        }
        private void Append(byte[] buffer, int offset, int count)
        {
            if (line.Length > maximumFrameBytes - count) throw Invalid();
            line.Write(buffer, offset, count);
        }
        private void ReadLine()
        {
            token.ThrowIfCancellationRequested();
            string text = new UTF8Encoding(false, true).GetString(line.ToArray()); line.SetLength(0);
            if (String.IsNullOrWhiteSpace(text)) return;
            if (completion != null) throw Invalid();
            Dictionary<string, object> frame;
            try { frame = JsonValue.ParseObject(ExactJsonNumberText.Quote(text), maximumFrameBytes * 2); }
            catch (Exception exception) when (exception is ArgumentException || exception is InvalidOperationException || exception is FormatException)
            { throw Invalid(); }
            string type = JsonValue.RequiredString(frame, "type", 32);
            if (type == "page")
            {
                object value;
                if (!frame.TryGetValue("value", out value) || !(value is Dictionary<string, object>)) throw Invalid();
                // Retain original numeric tokens; no deserialize/serialize pass
                // may round prices, quantities or trailing zeroes in the payload.
                pages.Add(text);
            }
            else if (type == "complete")
            { if (pages.Count == 0) throw Invalid(); completion = text; }
            else if (type == "error")
            { error = JsonValue.RequiredString(frame, "code", 128); JsonValue.RequiredString(frame, "message", 4096); completion = text; }
            else throw Invalid();
        }
        internal CompleteSummaryResponse Finish()
        {
            token.ThrowIfCancellationRequested();
            if (line.Length > 0) ReadLine();
            if (completion == null) throw Invalid();
            return new CompleteSummaryResponse { Pages = new ReadOnlyCollection<string>(pages), CompletionJson = completion, ErrorCode = error };
        }
        private static ApiException Invalid() { return new ApiException("INCOMPLETE_READ_PROTOCOL", "完整资料流中断或格式异常，请重新读取。"); }
        protected override void Dispose(bool disposing) { if (disposing) line.Dispose(); base.Dispose(disposing); }
        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => bytes;
        public override long Position { get => bytes; set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
        public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
        public override void SetLength(long value) { throw new NotSupportedException(); }
    }

    public static class ExactJsonNumberText
    {
        public static string Quote(string json)
        {
            if (json == null) throw new ArgumentNullException(nameof(json));
            var text = new StringBuilder(json.Length); bool inString = false, escaped = false;
            for (int i = 0; i < json.Length; i++)
            {
                char current = json[i];
                if (inString)
                {
                    text.Append(current);
                    if (escaped) escaped = false; else if (current == '\\') escaped = true; else if (current == '"') inString = false;
                    continue;
                }
                if (current == '"') { inString = true; text.Append(current); continue; }
                if (current == '-' || current >= '0' && current <= '9')
                {
                    int end = i + 1;
                    while (end < json.Length && (json[end] == '-' || json[end] == '+' || json[end] == '.' || json[end] == 'e'
                        || json[end] == 'E' || json[end] >= '0' && json[end] <= '9')) end++;
                    string number = json.Substring(i, end - i);
                    if (!System.Text.RegularExpressions.Regex.IsMatch(number, @"\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z", System.Text.RegularExpressions.RegexOptions.CultureInvariant))
                        throw new FormatException("服务端数值字段不是有效 JSON 数字。");
                    text.Append('"').Append(number).Append('"'); i = end - 1;
                }
                else text.Append(current);
            }
            return text.ToString();
        }
    }
}
