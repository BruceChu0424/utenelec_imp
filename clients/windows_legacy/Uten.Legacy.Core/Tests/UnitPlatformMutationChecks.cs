using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core.Tests
{
    public static class UnitPlatformMutationChecks
    {
        private const string R = "22222222-2222-2222-2222-222222222222";
        private const string A = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
        private const string B = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
        private const string Created = "cccccccc-cccc-cccc-cccc-cccccccccccc";
        private const string Layout = "{\"order\":[\"code\",\"name\",\"status\"],\"hidden\":[],\"pinned\":[\"code\",\"name\",\"status\"],\"widths\":{\"name\":288.5},\"added\":[],\"sortColumn\":null,\"sortAscending\":true,\"hasQueryPreferences\":false}";
        private const string Create = "{\"name\":\"数字展示\",\"type\":\"CALCULATED\",\"priceProtected\":false,\"formula\":{\"base\":{\"constant\":\"0.123456789012345678901234567890\"},\"steps\":[]}}";
        public static void Run()
        {
            FixedContractsAndBodyPresence().GetAwaiter().GetResult();
            LayoutNeedsCurrentCompletePreferences().GetAwaiter().GetResult();
            DefinitionCommandsUseAuthoritativeCapabilities().GetAwaiter().GetResult();
            CompleteHiddenRowAndExactVersion().GetAwaiter().GetResult();
            MissingOrMaskedPersistedCellsNeverWrite().GetAwaiter().GetResult();
            CalculatedMarkersAndRelatedAreNotEditableValues().GetAwaiter().GetResult();
            ChangedOrUnreadableRowNeverSends().GetAwaiter().GetResult();
            InvalidSuccessAndNewUuidRemainUnknown().GetAwaiter().GetResult();
            Full32CellCapacityRoundTripsAndUsesSameCodec().GetAwaiter().GetResult();
            KnownSuccessLocalFailureCannotReplay().GetAwaiter().GetResult();
            IncompleteDraftAndRetiredOwnerArePreserved().GetAwaiter().GetResult();
        }
        private static async Task FixedContractsAndBodyPresence()
        {
            using (var f = new Fixture())
            {
                await f.Login();
                var layout = f.Prepare(MutationAction.UnitColumnLayoutSave, Layout);
                Equal("user/preferences/platform.table.19e439ed14e5af7509dbe9fd5a998194", layout.RelativePath, "only owning preference hash");
                var create = f.Prepare(MutationAction.UnitPlatformDefinitionCreate, Create);
                True(create.ContractVersion == 4 && !create.ServerIdempotencyAvailable && create.ResponseKind == MutationResponseKind.PlatformDefinition, "new contract has actual definition success shape, no receipt");
                var delete = f.Prepare(MutationAction.UnitPlatformDefinitionDelete, null, A);
                True(delete.Method == "DELETE" && delete.BodyJson == null, "actual body-free DELETE");
                var used = f.Prepare(MutationAction.UnitPlatformDefinitionUse, null, A);
                True(used.Method == "POST" && used.BodyJson == null, "usage is a real typed write, not GET or fake mutation body");
                ThrowsApi(() => f.Prepare(MutationAction.UnitPlatformDefinitionDelete, "{}", A));
                ThrowsApi(() => f.Prepare(MutationAction.UnitColumnLayoutSave, Layout, A));
                ThrowsApi(() => f.Prepare(MutationAction.UnitPlatformDefinitionCreate, Create.Replace("CALCULATED", "RELATED")));
                ThrowsApi(() => f.Prepare(MutationAction.UnitPlatformDefinitionCreate, Create.Replace("\"constant\":\"0.123456789012345678901234567890\"", "\"fact\":\"amount\"")));
            }
        }
        private static async Task LayoutNeedsCurrentCompletePreferences()
        {
            using (var f = new Fixture())
            {
                f.Permissions = new[] { "unit:view" }; await f.Login(); f.PreferencesPresent = false;
                var failed = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitColumnLayoutSave, Layout), CancellationToken.None);
                True(failed.Outcome == MutationOutcome.NotSent && failed.Error.Code == "PREFERENCES_UNCONFIRMED" && f.Writes == 0, "cannot overwrite unconfirmed preferences");
                f.PreferencesPresent = true;
                var result = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitColumnLayoutSave, Layout), CancellationToken.None);
                True(result.Outcome == MutationOutcome.Confirmed && result.IsDurablyRecorded && f.Writes == 1, "layout needs view, not invented business edit");
                Equal(Layout, f.LastBody, "pixel original JSON never rewritten");
            }
        }
        private static async Task DefinitionCommandsUseAuthoritativeCapabilities()
        {
            using (var f = new Fixture())
            {
                await f.Login(); f.CanDefine = false;
                var denied = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitPlatformDefinitionCreate, Create), CancellationToken.None);
                True(denied.Outcome == MutationOutcome.NotSent && f.Writes == 0, "canDefine false never writes");
                f.CanDefine = true; var created = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitPlatformDefinitionCreate, Create), CancellationToken.None);
                True(created.Outcome == MutationOutcome.Confirmed && created.IsDurablyRecorded, "definition returned and journaled");
                Equal(Create, f.LastBody, "arbitrary precision literal remains string, no calculation/rounding");
                var stored = await f.Session.LoadMutationJournalAsync(created.Request.RequestId, f.Owner(), CancellationToken.None);
                Equal(Created, stored.ConfirmedResourceId, "server returned immutable definition UUID retained");
                f.CanDelete = false; var delete = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitPlatformDefinitionDelete, null, A), CancellationToken.None);
                True(delete.Outcome == MutationOutcome.NotSent && f.Writes == 1, "fresh canDelete false blocks stale capability");
                f.CanDelete = true; var deleted = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitPlatformDefinitionDelete, null, A), CancellationToken.None);
                True(deleted.Outcome == MutationOutcome.Confirmed && deleted.IsDurablyRecorded && f.LastBody == null, "body-free deletion uses same journal");
                var used = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitPlatformDefinitionUse, null, A), CancellationToken.None);
                True(used.Outcome == MutationOutcome.Confirmed && f.LastBody == null, "usage selection explicitly tracked once");
            }
        }
        private static async Task CompleteHiddenRowAndExactVersion()
        {
            using (var f = new Fixture())
            {
                await f.Login(); f.Version = 9007199254740993L;
                f.Cells[A] = new Cell("visible"); f.Cells[B] = new Cell("隐藏原值 0.123456789012345678901234567890");
                var body = f.Values(new Dictionary<string, string> { [A] = "edited", [B] = f.Cells[B].Value });
                var request = f.Prepare(MutationAction.UnitPlatformValuesWrite, body, R);
                True(request.EnforcesExpectedVersion && request.VersionStrategy == MutationVersionStrategy.PlatformRowVersion && !request.ServerIdempotencyAvailable, "row CAS is not an operation version or receipt");
                var result = await f.Session.MutateAsync(request, CancellationToken.None);
                True(result.Outcome == MutationOutcome.Confirmed && result.IsDurablyRecorded && f.Reads == 1 && f.Writes == 1, "fresh full-row prerequisite precedes one write");
                Equal(body, f.LastBody, "entire row exact original string body");
                Equal("隐藏原值 0.123456789012345678901234567890", f.Cells[B].Value, "non-visible persisted cell not dropped or converted");
                var saved = await f.Session.LoadMutationJournalAsync(request.RequestId, f.Owner(), CancellationToken.None);
                True(saved.ContractVersion == 4 && saved.ResultJson.Contains("9007199254740994") && saved.ConfirmedResourceId == R, "actual full row outcome retained");
            }
        }
        private static async Task MissingOrMaskedPersistedCellsNeverWrite()
        {
            using (var f = new Fixture())
            {
                await f.Login(); f.Cells[A] = new Cell("visible"); f.Cells[B] = new Cell("hidden");
                var missing = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitPlatformValuesWrite, f.Values(new Dictionary<string, string> { [A] = "change" }), R), CancellationToken.None);
                True(missing.Outcome == MutationOutcome.NotSent && missing.Error.Code == "PLATFORM_FIELDS_NOT_PRESERVED", "partial row replacement prevented");
                f.Cells[B].Masked = true;
                var masked = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitPlatformValuesWrite, f.Values(new Dictionary<string, string> { [A] = "change", [B] = null }), R), CancellationToken.None);
                True(masked.Outcome == MutationOutcome.NotSent && masked.Error.Code == "PLATFORM_HIDDEN_FIELDS_UNVERIFIED" && f.Writes == 0,
                    "masked null cannot be mistaken for true old value even with matching version");
                Equal("hidden", f.Cells[B].Value, "no hidden value cleared");
            }
        }
        private static async Task CalculatedMarkersAndRelatedAreNotEditableValues()
        {
            using (var f = new Fixture())
            {
                await f.Login(); f.Cells[A] = new Cell("visible"); f.Cells[B] = new Cell(null, "CALCULATED");
                var bad = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitPlatformValuesWrite, f.Values(new Dictionary<string, string> { [A] = "change", [B] = "2" }), R), CancellationToken.None);
                True(bad.Outcome == MutationOutcome.NotSent && f.Writes == 0, "computed display text never written back");
                var good = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitPlatformValuesWrite, f.Values(new Dictionary<string, string> { [A] = "change", [B] = null }), R), CancellationToken.None);
                True(good.Outcome == MutationOutcome.Confirmed && f.Cells[B].Value == null, "calculated persisted marker stays null");
                f.Cells[B].Type = "RELATED";
                var related = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitPlatformValuesWrite, f.Values(new Dictionary<string, string> { [A] = "again", [B] = null }), R), CancellationToken.None);
                True(related.Outcome == MutationOutcome.NotSent && f.Writes == 1, "related never participates in replacement row");
            }
        }
        private static async Task ChangedOrUnreadableRowNeverSends()
        {
            using (var f = new Fixture())
            {
                await f.Login(); f.Cells[A] = new Cell("old"); var body = f.Values(new Dictionary<string, string> { [A] = "new" }); f.Version++;
                var stale = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitPlatformValuesWrite, body, R), CancellationToken.None);
                Equal("PLATFORM_ROW_CHANGED", stale.Error.Code, "fresh prerequisite rejects old CAS snapshot");
                f.CanWrite = false;
                var readOnly = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitPlatformValuesWrite, f.Values(new Dictionary<string, string> { [A] = "new" }), R), CancellationToken.None);
                True(readOnly.Outcome == MutationOutcome.NotSent && f.Writes == 0, "row read-only guard is below UI");
            }
        }
        private static async Task InvalidSuccessAndNewUuidRemainUnknown()
        {
            using (var f = new Fixture())
            {
                await f.Login(); f.Cells[A] = new Cell("old"); f.BadSuccessVersion = true;
                var original = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitPlatformValuesWrite, f.Values(new Dictionary<string, string> { [A] = "new" }), R), CancellationToken.None);
                True(original.Outcome == MutationOutcome.Unknown && original.ResponseJson == null && original.IsDurablyRecorded, "malformed row success is not accepted");
                var other = f.Session.PrepareMutation(MutationAction.UnitInlineEdit, Guid.NewGuid().ToString("D"), "{\"expected\":{\"name\":\"kg\"},\"changes\":{\"name\":\"g\"}}", f.Owner(), R);
                var blocked = await f.Session.MutateAsync(other, CancellationToken.None);
                True(blocked.Outcome == MutationOutcome.NotSent && blocked.NeedsManualReconciliation && f.Writes == 1, "new UUID/endpoint cannot bypass overlapping row uncertainty");
            }
        }
        private static async Task Full32CellCapacityRoundTripsAndUsesSameCodec()
        {
            foreach (var text in new[] { new string('汉', 2000), new string('\u0001', 2000) })
            using (var f = new Fixture())
            {
                await f.Login(); var input = new Dictionary<string, string>();
                foreach (var id in Enumerable.Range(0, 32).Select(i => Guid.NewGuid().ToString("D"))) { f.Cells[id] = new Cell(text); input[id] = text; }
                var body = f.Values(input); True(Encoding.UTF8.GetByteCount(body) > 65536, "full legal row exceeds old generic limit");
                var lease = f.Session.CreateDraftLease(MutationAction.UnitPlatformValuesWrite, Guid.NewGuid().ToString("D"), f.Owner(), R);
                var draft = await f.Session.SaveDraftAsync(lease, 0, body, CancellationToken.None);
                Equal(body, (await f.Session.LoadDraftAsync(draft.DraftId, f.Owner(), CancellationToken.None)).BodyJson, "all 32 values retained, no truncation");
                var request = await f.Session.PrepareMutationFromDraftAsync(Guid.NewGuid().ToString("D"), draft.DraftId, draft.Revision, f.Owner(), CancellationToken.None);
                using (var message = new HttpRequestMessage(HttpMethod.Put, request.Owner.IssuerApiBaseUrl + "/" + request.RelativePath))
                using (var stream = new WireStream())
                {
                    message.Content = new StringContent(body, Encoding.UTF8, "application/json"); new MutationWirePermit(request, true, () => { }).Attach(message);
                    using (ManagedHttp11.SendAndReceive(stream, message, 1024, CancellationToken.None)) { }
                    True(stream.Written > Encoding.UTF8.GetByteCount(body), "same codec transmits bounded 512KiB capability, not auth global expansion");
                }
                var result = await f.Session.MutateAsync(request, CancellationToken.None);
                True(result.Outcome == MutationOutcome.Confirmed && result.IsDurablyRecorded && f.Cells.Count == 32, "complete large row journal and response roundtrip");
            }
        }
        private static async Task KnownSuccessLocalFailureCannotReplay()
        {
            var writes = 0;
            using (var state = new BusinessStateTestFixture(point => { if (point == "mutations:before-replace" && ++writes == 2) throw new IOException("fixture terminal failure"); }))
            using (var f = new Fixture(state.Store))
            {
                await f.Login(); f.Cells[A] = new Cell("old");
                var result = await f.Session.MutateAsync(f.Prepare(MutationAction.UnitPlatformValuesWrite, f.Values(new Dictionary<string, string> { [A] = "new" }), R), CancellationToken.None);
                True(result.Outcome == MutationOutcome.Confirmed && !result.IsDurablyRecorded && result.PersistenceError != null && f.Writes == 1, "remote success remains known despite local failure");
            }
        }
        private static async Task IncompleteDraftAndRetiredOwnerArePreserved()
        {
            using (var f = new Fixture())
            {
                await f.Login(); var owner = f.Owner(); var lease = f.Session.CreateDraftLease(MutationAction.UnitColumnLayoutSave, Guid.NewGuid().ToString("D"), owner);
                var incomplete = Layout.Replace("288.5", "\"120.\"");
                var saved = await f.Session.SaveDraftAsync(lease, 0, incomplete, CancellationToken.None);
                Equal(incomplete, saved.BodyJson, "unfinished pixel input is not defaulted or rounded");
                ThrowsApi(() => f.Prepare(MutationAction.UnitColumnLayoutSave, incomplete));
                var definition = f.Session.CreateDraftLease(MutationAction.UnitPlatformDefinitionCreate, Guid.NewGuid().ToString("D"), owner);
                var unfinished = Create.Replace("数字展示", "").Replace("0.123456789012345678901234567890", "");
                await f.Session.SaveDraftAsync(definition, 0, unfinished, CancellationToken.None);
                f.Session.SelectEndpoint("cloud"); var late = await f.Session.SaveDraftAsync(lease, 1, Layout, CancellationToken.None);
                Equal(owner.IssuerApiBaseUrl, late.IssuerApiBaseUrl, "retired platform model preserved in original namespace only"); Equal(0, f.Writes, "drafts never write remote preferences or definitions");
            }
        }
        private static void True(bool value, string label) { if (!value) throw new InvalidOperationException("Unit platform mutation: " + label); }
        private static void Equal<T>(T expected, T actual, string label) { True(EqualityComparer<T>.Default.Equals(expected, actual), label); }
        private static void ThrowsApi(Action action) { try { action(); } catch (ApiException) { return; } throw new InvalidOperationException("Expected platform action rejection"); }
        private static HttpResponseMessage Json(object value) { return Raw(JsonValue.Serialize(value)); }
        private static HttpResponseMessage Raw(string value) { return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(value, Encoding.UTF8, "application/json") }; }
        private sealed class Cell
        { internal string Value, Type; internal bool Masked; internal Cell(string value, string type = "TEXT") { Value = value; Type = type; } }
        private sealed class Fixture : IDisposable
        {
            internal readonly BusinessStateTestFixture State;
            internal readonly SessionCoordinator Session;
            internal readonly Dictionary<string, Cell> Cells = new Dictionary<string, Cell>();
            internal string[] Permissions = { "unit:view", "unit:edit", "unit:status" };
            internal bool PreferencesPresent = true, CanDefine = true, CanDelete = true, CanWrite = true, BadSuccessVersion;
            internal long Version;
            internal int Writes, Reads;
            internal string LastBody;
            internal Fixture() : this(null, true) { }
            internal Fixture(IBusinessStateStore store) : this(store, false) { }
            private Fixture(IBusinessStateStore store, bool owned)
            {
                if (owned) { State = new BusinessStateTestFixture(); store = State.Store; }
                var cfg = new ClientConfiguration(new[] { new ServerEndpoint("company", "fixture", "https://company.example.test/api"), new ServerEndpoint("cloud", "fixture", "https://cloud.example.test/api") }, "company", 5);
                Session = new SessionCoordinator(cfg, new Handler(async (message, ct) =>
                {
                    var path = message.RequestUri.AbsolutePath;
                    if (path == "/api/auth/login" || path == "/api/auth/refresh") return Raw("{\"accessToken\":\"fixture-access\",\"refreshToken\":\"fixture-refresh\",\"expiresIn\":900,\"user\":{\"id\":\"platform-core-owner\",\"loginAccount\":\"fixture\",\"superAdmin\":false,\"mustChangePassword\":false,\"permissions\":"
                        + JsonValue.Serialize(Permissions) + ",\"businessDatasetId\":\"11111111-1111-1111-1111-111111111111\",\"businessResetGeneration\":0}}");
                    if (path == "/api/auth/logout") return Raw("");
                    if (path == "/api/auth/me") return Raw("{\"id\":\"platform-core-owner\",\"session\":{\"preferences\":" + (PreferencesPresent ? "{}" : "null") + "}}");
                    if (path == "/api/platform-columns/scopes") return Raw("[{\"scope\":\"master_unit\",\"canDefine\":" + (CanDefine ? "true" : "false") + ",\"priceVisible\":true}]");
                    if (message.Method == HttpMethod.Get && path == "/api/platform-columns/master_unit/definitions")
                    {
                        var ids = Uri.UnescapeDataString(message.RequestUri.Query.TrimStart('?').Split('&')[0].Substring(4)).Split(',');
                        return Json(ids.Select(id => Definition(id, Cells.ContainsKey(id) ? Cells[id].Type : "TEXT")).ToArray());
                    }
                    if (path.EndsWith("values:batch", StringComparison.Ordinal))
                    {
                        Reads++; var body = JsonValue.ParseObject(await message.Content.ReadAsStringAsync());
                        var selected = ((object[])body["columnIds"]).Cast<string>().ToArray(); return Json(new[] { Row(selected) });
                    }
                    Writes++; LastBody = message.Content == null ? null : await message.Content.ReadAsStringAsync();
                    if (path.StartsWith("/api/user/preferences/", StringComparison.Ordinal)) return Raw("");
                    if (path == "/api/platform-columns/master_unit/definitions")
                    {
                        var source = JsonValue.ParseObject(LastBody); var result = Definition(Created, (string)source["type"]); result["name"] = source["name"]; result["formula"] = source["formula"]; return Json(result);
                    }
                    if (path.EndsWith("/values/" + R, StringComparison.Ordinal))
                    {
                        var body = JsonValue.ParseObject(LastBody); var types = Cells.ToDictionary(value => value.Key, value => value.Value.Type); Cells.Clear();
                        foreach (var raw in (object[])body["cells"]) { var cell = (Dictionary<string, object>)raw; string type; var id = (string)cell["columnId"];
                            Cells.Add(id, new Cell(cell["value"] as string, types.TryGetValue(id, out type) ? type : "TEXT")); }
                        Version++; var row = Row(new string[0]); if (BadSuccessVersion) row["version"] = Version - 1; return Json(row);
                    }
                    True(message.Content == null, "DELETE/use have no fabricated request body"); return Raw("");
                }), new AuthStore(), store);
            }
            private Dictionary<string, object> Definition(string id, string type)
            { return new Dictionary<string, object> { ["id"] = id, ["scope"] = "master_unit", ["name"] = "字段", ["type"] = type, ["priceProtected"] = false,
                ["formula"] = type == "CALCULATED" ? JsonValue.ParseObject("{\"base\":{\"constant\":\"2\"},\"steps\":[]}") : null, ["usageCount"] = 0, ["personalUsageCount"] = 0, ["relationKey"] = null, ["canDelete"] = CanDelete }; }
            private Dictionary<string, object> Row(string[] selected)
            {
                return new Dictionary<string, object> { ["recordId"] = R, ["version"] = Version, ["canWrite"] = CanWrite,
                    ["cells"] = Cells.Keys.Concat(selected).Distinct().Select(id => { Cell cell; var persisted = Cells.TryGetValue(id, out cell); cell = cell ?? new Cell(null);
                        return new Dictionary<string, object> { ["columnId"] = id, ["value"] = cell.Masked ? null : cell.Type == "CALCULATED" ? "2" : cell.Value, ["definition"] = Definition(id, cell.Type), ["masked"] = cell.Masked, ["persisted"] = persisted, ["error"] = null }; }).ToArray() };
            }
            internal string Values(IDictionary<string, string> input) { return JsonValue.Serialize(new Dictionary<string, object> { ["expectedVersion"] = Version, ["cells"] = input.Select(pair => new Dictionary<string, object> { ["columnId"] = pair.Key, ["value"] = pair.Value }).ToArray() }); }
            internal MutationOwnerSnapshot Owner() { return Session.CaptureMutationOwner(); }
            internal Task Login() { return Session.LoginAsync("fixture", "fixture-password", null, CancellationToken.None); }
            internal MutationRequest Prepare(MutationAction action, string body, string resource = null) { return Session.PrepareMutation(action, Guid.NewGuid().ToString("D"), body, Owner(), resource); }
            public void Dispose() { Session.Dispose(); State?.Dispose(); }
        }
        private sealed class Handler : HttpMessageHandler
        {
            private readonly Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action;
            internal Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action) { this.action = action; }
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage message, CancellationToken ct) { return action(message, ct); }
        }
        private sealed class AuthStore : ISessionStore
        {
            private StoredSession active; private readonly List<StoredSession> pending = new List<StoredSession>();
            public StoredSession Load() { return active; } public void Save(StoredSession value) { active = value; } public void Clear() { active = null; }
            public void EndSession(StoredSession value) { EnqueueRevocation(value ?? active); active = null; } public void EnqueueRevocation(StoredSession value) { if (value != null) pending.Add(value); }
            public IList<StoredSession> PendingRevocations() { return pending.ToList(); } public void AcknowledgeRevocation(string id) { pending.RemoveAll(value => value.Id == id); }
        }
        private sealed class WireStream : Stream
        {
            private readonly MemoryStream input = new MemoryStream(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")); internal long Written;
            public override int Read(byte[] b, int o, int c) { return input.Read(b, o, c); } public override void Write(byte[] b, int o, int c) { Written += c; }
            public override void Flush() { } public override bool CanRead { get { return true; } } public override bool CanWrite { get { return true; } } public override bool CanSeek { get { return false; } }
            public override long Length { get { return input.Length; } } public override long Position { get { return input.Position; } set { throw new NotSupportedException(); } }
            public override long Seek(long o, SeekOrigin s) { throw new NotSupportedException(); } public override void SetLength(long v) { throw new NotSupportedException(); }
            protected override void Dispose(bool disposing) { if (disposing) input.Dispose(); base.Dispose(disposing); }
        }
    }
}
