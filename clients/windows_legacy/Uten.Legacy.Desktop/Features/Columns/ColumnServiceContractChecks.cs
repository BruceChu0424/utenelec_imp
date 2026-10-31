using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Uten.Legacy.Core;
using Uten.Legacy.Core.Tests;

namespace Uten.Legacy.Desktop.Features.Columns
{
    public static class ColumnServiceContractChecks
    {
        internal const string NumberId = "00000000-0000-0000-0000-000000000081", TextId = "00000000-0000-0000-0000-000000000082";
        internal const string RecordId = "00000000-0000-0000-0000-000000000083";
        public static int RunRead()
        { return Task.Run(ReadContracts).GetAwaiter().GetResult(); }
        private static async Task<int> ReadContracts()
        {
            int count = 0; Action<bool, string> check = (condition, label) => { if (!condition) throw new InvalidOperationException("Columns read: " + label); count++; };
            using (var fixture = new Fixture())
            {
                await fixture.Login(); var service = new UnitColumnsService(fixture.Session);
                var snapshot = await service.LoadAsync(new[] { RecordId }, CancellationToken.None);
                check(snapshot.Projection.TableKey == "master.unit" && snapshot.Projection.Scope == "master_unit", "canonical domain identity survives host callsite changes");
                check(snapshot.Projection.Columns[3].Label == "记录数字" && snapshot.Projection.Columns[3].Type == "number", "cached preference labels and types never become authority");
                check(snapshot.Rows[RecordId].Version == 9007199254740993L && snapshot.DisplayText(RecordId, "platform:" + NumberId) == "0.123456789012345678901234567890", "raw field version and decimal display survive real Core POST reader");
                check(fixture.Handler.LastReadBody.Contains("\"recordIds\":[\"" + RecordId + "\"]") && fixture.Handler.LastReadBody.Contains(NumberId), "read uses approved values batch body and selected definition IDs");
                var journal = await fixture.Session.ListMutationJournalAsync(fixture.Session.CaptureMutationOwner(), CancellationToken.None);
                check(journal.Count == 0 && fixture.Handler.BusinessWrites == 0, "read-only POST never becomes a business mutation or write journal entry");
                var frozen = await service.LoadRowsAsync(new[] { RecordId }, snapshot, CancellationToken.None);
                check(frozen.Projection.ToJson() == snapshot.Projection.ToJson() && frozen.DefinitionFingerprint == snapshot.DefinitionFingerprint, "full-result consumers retain exact frozen header evidence");
                fixture.Handler.Mask = true;
                await RejectAsync<ApiException>(() => service.LoadRowsAsync(new[] { RecordId }, snapshot, CancellationToken.None), check, "masked field cannot be delivered as a print or export zero");
                fixture.Handler.Mask = false; fixture.Handler.CellError = "fixture formula unavailable";
                await RejectAsync<ApiException>(() => service.LoadRowsAsync(new[] { RecordId }, snapshot, CancellationToken.None), check, "errored field stops whole-result delivery");
                fixture.Handler.CellError = null; fixture.Handler.SkipRows = true;
                await RejectAsync<FormatException>(() => service.LoadAsync(new[] { RecordId }, CancellationToken.None), check, "missing row rejects complete snapshot publication");
                fixture.Handler.SkipRows = false; fixture.Handler.ForeignRow = true;
                await RejectAsync<FormatException>(() => service.LoadAsync(new[] { RecordId }, CancellationToken.None), check, "foreign record cannot enter the page snapshot");
                fixture.Handler.ForeignRow = false; fixture.Handler.Name = "新目录定义";
                await RejectAsync<ApiException>(() => service.LoadRowsAsync(new[] { RecordId }, snapshot, CancellationToken.None), check, "immutable definition mismatch retires frozen delivery");
            }
            using (var fixture = new Fixture())
            {
                await fixture.Login(); fixture.Handler.PendingRows = new TaskCompletionSource<HttpResponseMessage>();
                var pending = new UnitColumnsService(fixture.Session).LoadAsync(new[] { RecordId }, CancellationToken.None);
                while (!fixture.Handler.RowStarted) await Task.Delay(1).ConfigureAwait(false);
                fixture.Session.SelectEndpoint("second"); fixture.Handler.PendingRows.SetResult(Reply("[]"));
                try { await pending; check(false, "late old issuer read rejected"); }
                catch (ApiException) { check(true, "late old issuer read rejected"); }
                catch (OperationCanceledException) { check(true, "late old issuer read cancelled"); }
            }
            using (var fixture = new Fixture())
            {
                await fixture.Login(); fixture.Handler.SessionSnapshotMissing = true;
                var snapshot = await new UnitColumnsService(fixture.Session).LoadAsync(new[] { RecordId }, CancellationToken.None);
                check(!snapshot.PreferencesConfirmed && snapshot.Rows.Count == 1, "missing preference snapshot retains readable fields but cannot authorize preference overwrite");
            }
            using (var fixture = new Fixture())
            {
                await fixture.Login(); fixture.Handler.LimitReadToSingleRow = true;
                var snapshot = await new UnitColumnsService(fixture.Session).LoadAsync(new[] { RecordId, "00000000-0000-0000-0000-000000000084" }, CancellationToken.None);
                check(snapshot.Rows.Count == 2 && fixture.Handler.RowReads == 3 && fixture.Handler.BusinessWrites == 0,
                    "oversize pure read splits records without relaxing shared byte bound or publishing partial rows");
            }
            using (var fixture = new Fixture())
            {
                await fixture.Login(); var handler = fixture.Handler; handler.OverflowColumns = 35;
                for (int index = 0; index < 35; index++) handler.StoredValues[ColumnModelContractChecks.Extra(index)] = "遗留值" + index;
                var service = new UnitColumnsService(fixture.Session);
                var snapshot = await service.LoadAsync(new[] { RecordId }, CancellationToken.None);
                check(snapshot.Projection.Columns.Count == 35 && snapshot.OverflowedDefinitionIds.Count == 4,
                    "legacy data with 36 distinct persisted columns yields the bounded table and explicit overflow instead of a paused page");
                check(snapshot.Rows[RecordId].Cells.Count == 36 && snapshot.ObservedDefinitionIds.Count == 36,
                    "all persisted cells and definitions stay retained for row write preservation");
                check(ColumnJson.Array(ColumnJson.Object(ColumnJson.Parse(handler.LastReadBody))["columnIds"]).Length <= 32,
                    "values batch never exceeds the owning 32-column selection contract while discovering legacy columns");
                var second = await service.LoadAsync(new[] { RecordId }, CancellationToken.None, snapshot);
                check(ColumnJson.Array(ColumnJson.Object(ColumnJson.Parse(handler.LastReadBody))["columnIds"]).Length == 32
                    && second.Projection.ToJson() == snapshot.Projection.ToJson() && second.OverflowedDefinitionIds.Count == 4 && handler.BusinessWrites == 0,
                    "bounded selection stays stable across reloads without any business write");
            }
            return count;
        }
        private static async Task RejectAsync<T>(Func<Task> operation, Action<bool, string> check, string label) where T : Exception
        { try { await operation(); } catch (T) { check(true, label); return; } check(false, label); }
        internal static HttpResponseMessage Reply(string text)
        { return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(text, Encoding.UTF8, "application/json") }; }
        internal sealed class Fixture : IDisposable
        {
            private readonly BusinessStateTestFixture storage = new BusinessStateTestFixture();
            internal readonly Handler Handler = new Handler(); internal readonly SessionCoordinator Session;
            internal Fixture()
            {
                Session = new SessionCoordinator(new ClientConfiguration(new[] { new ServerEndpoint("first", "First", "https://first.columns.test/api"),
                    new ServerEndpoint("second", "Second", "https://second.columns.test/api") }, "first"), Handler, new AuthStore(), storage.Store);
            }
            internal Task Login() { return Session.LoginAsync("fixture", "fixture-secret", CancellationToken.None); }
            public void Dispose() { Session.Dispose(); storage.Dispose(); }
        }
        private sealed class AuthStore : ISessionStore
        {
            private readonly List<StoredSession> pending = new List<StoredSession>();
            public StoredSession Load() { return null; } public void Save(StoredSession value) { } public void Clear() { }
            public void EndSession(StoredSession value) { if (value != null) pending.Add(value); } public void EnqueueRevocation(StoredSession value) { pending.Add(value); }
            public IList<StoredSession> PendingRevocations() { return pending.ToList(); } public void AcknowledgeRevocation(string id) { pending.RemoveAll(value => value.Id == id); }
        }
        internal sealed class Handler : HttpMessageHandler
        {
            internal string Name = "记录数字", CellError, LastReadBody;
            internal bool Mask, SkipRows, ForeignRow, SessionSnapshotMissing, LimitReadToSingleRow;
            internal int OverflowColumns;
            internal volatile bool RowStarted;
            internal int BusinessWrites;
            internal int RowReads;
            internal string LastWriteBody, LastWritePath;
            internal bool LastWriteHadContent, LoseWriteReply, DeleteConfirmed;
            internal long RowVersion = 9007199254740993L;
            internal readonly Dictionary<string, string> StoredValues = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { [NumberId] = "0.123456789012345678901234567890" };
            internal Dictionary<string, object> Created;
            internal object SavedPreference;
            internal const string CreatedId = "00000000-0000-0000-0000-000000000085";
            internal TaskCompletionSource<HttpResponseMessage> PendingRows;
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
            {
                string path = request.RequestUri.AbsolutePath;
                if (path == "/api/auth/login" || path == "/api/auth/refresh") return Reply(ColumnJson.Serialize(new Dictionary<string, object> { ["accessToken"] = "fixture-access", ["refreshToken"] = "fixture-refresh", ["expiresIn"] = 3600, ["user"] = User() }));
                if (path == "/api/auth/me")
                {
                    var me = User(); me["session"] = SessionSnapshotMissing ? null : new Dictionary<string, object> { ["preferences"] = new Dictionary<string, object> { [UnitColumnLayout.PreferenceKey] = SavedPreference ?? Preference() } };
                    return Reply(ColumnJson.Serialize(me));
                }
                if (path == "/api/auth/logout") return Reply("{}");
                if (path == "/api/platform-columns/scopes") return Reply(ColumnJson.Serialize(new object[] { new Dictionary<string, object> { ["scope"] = "master_unit", ["label"] = "单位资料", ["canWrite"] = true,
                    ["priceVisible"] = true, ["supportsValues"] = true, ["canDefine"] = true, ["personalDefinitions"] = false, ["canCreate"] = false, ["canDefineRelated"] = false, ["facts"] = new object[0], ["relations"] = new object[0] } }));
                if (path == "/api/platform-columns/master_unit/definitions" && request.Method == HttpMethod.Get)
                {
                    var result = new List<object>();
                    if (request.RequestUri.Query.Contains("q=") || request.RequestUri.Query.Contains(NumberId)) result.Add(Definition(NumberId));
                    if (request.RequestUri.Query.Contains("q=") || request.RequestUri.Query.Contains(TextId)) result.Add(Definition(TextId));
                    if (Created != null && (request.RequestUri.Query.Contains("q=") || request.RequestUri.Query.Contains(CreatedId))) result.Add(Created);
                    for (int index = 0; index < OverflowColumns; index++)
                    { string extra = ColumnModelContractChecks.Extra(index); if (request.RequestUri.Query.Contains("q=") || request.RequestUri.Query.Contains(extra)) result.Add(Definition(extra)); }
                    return Reply(ColumnJson.Serialize(result));
                }
                if (path == "/api/platform-columns/master_unit/values:batch" && request.Method == HttpMethod.Post)
                {
                    LastReadBody = await request.Content.ReadAsStringAsync(); RowStarted = true; RowReads++;
                    if (PendingRows != null) return await PendingRows.Task;
                    if (SkipRows) return Reply("[]");
                    var body = ColumnJson.Object(ColumnJson.Parse(LastReadBody)); var ids = ColumnJson.Array(body["recordIds"]).Cast<string>().ToArray();
                    if (LimitReadToSingleRow && ids.Length > 1) { var oversize = Reply("{}"); oversize.Content.Headers.ContentLength = 16 * 1024 * 1024; return oversize; }
                    var selected = ColumnJson.Array(body["columnIds"]).Cast<string>().ToArray();
                    return Reply(ColumnJson.Serialize(ids.Select(id => Row(ForeignRow ? TextId : id, selected)).ToArray()));
                }
                if (path == "/api/user/preferences/" + UnitColumnLayout.PreferenceKey && request.Method == HttpMethod.Put)
                { await CaptureWrite(request); SavedPreference = ColumnJson.Parse(LastWriteBody); return WriteReply(""); }
                if (path == "/api/platform-columns/master_unit/definitions" && request.Method == HttpMethod.Post)
                {
                    await CaptureWrite(request); var body = ColumnJson.Object(ColumnJson.Parse(LastWriteBody));
                    Created = Definition(CreatedId); Created["name"] = ((string)body["name"]).Trim(); Created["type"] = body["type"]; Created["priceProtected"] = body["priceProtected"]; Created["formula"] = body["formula"];
                    return WriteReply(ColumnJson.Serialize(Created));
                }
                if (path.StartsWith("/api/platform-columns/master_unit/definitions/", StringComparison.Ordinal)
                    && (request.Method == HttpMethod.Delete || request.Method == HttpMethod.Post && path.EndsWith("/use", StringComparison.Ordinal)))
                { await CaptureWrite(request); if (request.Method == HttpMethod.Delete) DeleteConfirmed = true; return WriteReply(""); }
                if (path == "/api/platform-columns/master_unit/values/" + RecordId && request.Method == HttpMethod.Put)
                {
                    await CaptureWrite(request); var body = ColumnJson.Object(ColumnJson.Parse(LastWriteBody));
                    if (ColumnJson.Integer(body, "expectedVersion") != RowVersion) return new HttpResponseMessage(HttpStatusCode.Conflict)
                    { Content = new StringContent("{\"code\":\"CONFLICT\",\"message\":\"fixture row changed\"}", Encoding.UTF8, "application/json") };
                    var replacement = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    foreach (object raw in ColumnJson.Array(body["cells"])) { var cell = ColumnJson.Object(raw); replacement[(string)cell["columnId"]] = ColumnJson.Text(cell, "value")?.Trim(); }
                    StoredValues.Clear(); foreach (var pair in replacement) StoredValues.Add(pair.Key, pair.Value);
                    RowVersion++; return WriteReply(ColumnJson.Serialize(Row(RecordId, new string[0])));
                }
                throw new InvalidOperationException("Unexpected controlled columns route.");
            }
            private async Task CaptureWrite(HttpRequestMessage request)
            { BusinessWrites++; LastWritePath = request.RequestUri.PathAndQuery; LastWriteHadContent = request.Content != null; LastWriteBody = request.Content == null ? null : await request.Content.ReadAsStringAsync(); }
            private HttpResponseMessage WriteReply(string json)
            { if (LoseWriteReply) throw new HttpRequestException("fixture lost write reply"); return Reply(json); }
            private Dictionary<string, object> Definition(string id)
            {
                if (id == CreatedId && Created != null) return new Dictionary<string, object>(Created);
                return new Dictionary<string, object> { ["id"] = id, ["scope"] = "master_unit", ["name"] = id == NumberId ? Name : "文字说明", ["type"] = id == NumberId ? "NUMBER" : "TEXT", ["priceProtected"] = false,
                    ["formula"] = null, ["usageCount"] = 9007199254740993L, ["personalUsageCount"] = 0, ["relationKey"] = null, ["canDelete"] = !DeleteConfirmed };
            }
            private object Row(string id, string[] selected)
            {
                var ids = StoredValues.Keys.Concat(selected).Distinct(StringComparer.OrdinalIgnoreCase);
                return new Dictionary<string, object> { ["recordId"] = id, ["version"] = RowVersion, ["canWrite"] = true,
                    ["cells"] = ids.Select(columnId => new Dictionary<string, object> { ["columnId"] = columnId,
                        ["value"] = Mask || CellError != null ? null : StoredValues.ContainsKey(columnId) ? StoredValues[columnId] : null,
                        ["definition"] = Definition(columnId), ["masked"] = Mask, ["persisted"] = StoredValues.ContainsKey(columnId), ["error"] = CellError }).ToArray() };
            }
            private static Dictionary<string, object> Preference()
            { return new Dictionary<string, object> { ["order"] = new[] { "status", "platform:" + NumberId, "code", "name" }, ["hidden"] = new[] { "code" }, ["pinned"] = new string[0],
                ["widths"] = new Dictionary<string, object> { ["platform:" + NumberId] = 185 }, ["added"] = new object[] { new Dictionary<string, object> { ["id"] = NumberId, ["scope"] = "master_unit", ["name"] = "不可信的缓存名", ["type"] = "TEXT", ["priceProtected"] = false } } }; }
            private static Dictionary<string, object> User()
            { return new Dictionary<string, object> { ["id"] = "columns-fixture-owner", ["employeeId"] = RecordId, ["loginAccount"] = "fixture", ["superAdmin"] = false, ["mustChangePassword"] = false,
                ["permissions"] = new[] { "unit:view", "unit:edit", "unit:create", "unit:status" }, ["businessDatasetId"] = "00000000-0000-0000-0000-000000000001", ["businessResetGeneration"] = 0 }; }
        }
    }
}
