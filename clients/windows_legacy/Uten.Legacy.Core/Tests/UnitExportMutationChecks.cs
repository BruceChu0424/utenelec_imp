using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Uten.Legacy.Core.Tests
{
    public static class UnitExportMutationChecks
    {
        private const string Job = "77777777-7777-7777-7777-777777777777";
        private const string Other = "88888888-8888-8888-8888-888888888888";
        private const string Filter = " { \"keyword\":\"kg\", \"nullFields\":[\"code\"] } ";
        public static void Run()
        {
            RunSharedSelectionFixture();
            RunSharedCapabilityFixture();
            ExactSubmitAndCredentialBoundary().GetAwaiter().GetResult();
            CancelNoBodyAndActualJobState().GetAwaiter().GetResult();
            KnownJobAcceptanceIsNotFileDelivery().GetAwaiter().GetResult();
            ServerKeyCannotChangeFrozenBody().GetAwaiter().GetResult();
            VerifiedGetRequestProofSettlesOnlyOriginalSubmit().GetAwaiter().GetResult();
            MissingOrDifferentProofStaysUnknown().GetAwaiter().GetResult();
            ExplicitSameKeyRetryNeverCreatesNewIdentity().GetAwaiter().GetResult();
            ReceiptPersistenceFailureKeepsKnownOutcome().GetAwaiter().GetResult();
            LateReceiptCannotEnterNewOwner().GetAwaiter().GetResult();
            CorruptReceiptMetadataFailsClosed().GetAwaiter().GetResult();
            PureMetadataParserDoesNotTreatPresenceAsProof();
            SelectedProofCannotExpandToAll().GetAwaiter().GetResult();
        }
        public static int RunLargeSelection()
        {
            int checks=0;var failures=new List<string>();
            foreach(int count in new[]{1000,1001,50001})
            {
                try { LargeSelectionRoundTrip(count).GetAwaiter().GetResult();checks++; }
                catch(Exception error) { Console.WriteLine("FAIL unit export complete original ticket; selected="+count+"; type="+error.GetType().Name+"; code="+(error as ApiException)?.Code);failures.Add(count.ToString()); }
            }
            if(failures.Count!=0)throw new InvalidOperationException("Large output request/receipt/recovery failed for selected="+String.Join(",",failures));
            LargeSelectionRoundTrip(50001, true).GetAwaiter().GetResult(); checks++;
            LargeProofAndOrdinaryBudgetIsolation().GetAwaiter().GetResult(); checks++;
            LegacyOriginalEnvelopeStaysOriginal().GetAwaiter().GetResult(); checks++;
            RequestByteBoundaryAndRetentionQuota().GetAwaiter().GetResult(); checks++;
            ManagedHttp11Checks.Run();
            return checks;
        }
        private static string LargeSubmitBody(int count, bool expandedReceipt = false)
        {
            var ids=Enumerable.Range(1,count).Select(number=>new Guid(number,0,0,new byte[8]).ToString("D")).ToArray();
            string selected = JsonValue.Serialize(ids);
            // Legal original whitespace crosses 2MiB and must survive exact receipt matching.
            if (expandedReceipt) selected = selected.Replace(",", ", ");
            return SubmitBody().Replace("\"parameters\":{","\"parameters\":{\"selectedIds\":"+JsonValue.Serialize(selected)+",");
        }
        private static async Task LargeSelectionRoundTrip(int count, bool expandedReceipt = false)
        {
            string body=LargeSubmitBody(count,expandedReceipt),accepted=null,localId;bool failComplete=false;int creations=0;
            var evidence=Environment.GetEnvironmentVariable("UTEN_EXPORT_BUDGET_EVIDENCE");
            if(!String.IsNullOrEmpty(evidence)) { Directory.CreateDirectory(evidence);File.WriteAllText(Path.Combine(evidence,"selected-"+count+(expandedReceipt?"-spaced":"")+"-original.json"),body,new UTF8Encoding(false)); }
            using(var state=new BusinessStateTestFixture(point=> { if(failComplete&&point.EndsWith(":before-replace",StringComparison.Ordinal))throw new IOException("fixture interruption after accepted output"); }))
            {
                using(var first=new Fixture(new DpapiBusinessStateStore(state.RootDirectory,point=> { if(failComplete&&point.EndsWith(":before-replace",StringComparison.Ordinal))throw new IOException("fixture interruption after accepted output"); })))
                {
                    await first.Login();var request=first.Submit(body);localId=request.RequestId;
                    first.Post=async(message,ct)=> { accepted=await message.Content.ReadAsStringAsync();Equal(body,accepted,"wire keeps exact large output body"); using(var response=WireRoundTrip(message,View(body))) { Equal(View(body),await response.Content.ReadAsStringAsync(),"managed HTTP complete creation receipt"); } creations++;failComplete=true;throw new HttpRequestException("fixture accepted, reply lost"); };
                    var unknown=await first.Session.MutateAsync(request,CancellationToken.None);
                    True(unknown.Outcome==MutationOutcome.Unknown,"lost output response remains unknown");
                    Equal(1,first.Posts,"one actual controlled handler submit");
                    True(!unknown.IsDurablyRecorded,"interrupted completion does not claim durable terminal state");
                    first.Store.Dispose();
                }
                failComplete=false;
                using(var resumed=new Fixture(new DpapiBusinessStateStore(state.RootDirectory)))
                {
                    await resumed.Login();var owner=resumed.Owner();
                    var original=await resumed.Session.LoadMutationJournalAsync(localId,owner,CancellationToken.None);
                    True(original.State==MutationJournalState.Unknown,"abandoned sending recovers as unknown");Equal(body,original.BodyJson,"restart keeps exact original large selection");
                    resumed.Get=(message,ct)=>Ready(WireRoundTrip(message,View(accepted,"RUNNING")));
                    var result=await resumed.Session.ReconcileUnitExportAsync(localId,owner,CancellationToken.None);
                    True(result.Outcome==MutationOutcome.Confirmed&&result.ConfirmedByReceiptQuery&&result.IsDurablyRecorded,"verified large receipt persists without resubmission");
                    Equal(0,resumed.Posts,"receipt recovery performs no write replay");Equal(1,creations,"one controlled server acceptance");
                    Equal(body,(await resumed.Session.LoadMutationJournalAsync(localId,owner,CancellationToken.None)).BodyJson,"receipt never replaces original raw body");
                    resumed.Store.Dispose();
                }
                Console.WriteLine("PASS large unit export request/DPAPI interruption/original receipt; selected="+count+"; requestBytes="+Encoding.UTF8.GetByteCount(body)+"; actualCreations="+creations+"; not real database IDs");
            }
        }
        private static async Task LargeProofAndOrdinaryBudgetIsolation()
        {
            var body = LargeSubmitBody(50001,true);
            using (var f = new Fixture())
            {
                await f.Login(); var request = f.Submit(body);
                f.Post = (message, ct) => { throw new HttpRequestException("fixture lost after accept"); };
                await f.Session.MutateAsync(request, CancellationToken.None);
                f.Get = (message, ct) => Ready(Json(View(body.Replace("0000c351-", "0000c352-"))));
                Equal(MutationOutcome.Unknown, (await f.Session.ReconcileUnitExportAsync(request.RequestId, f.Owner(), CancellationToken.None)).Outcome, "large altered selection cannot settle original");
                Equal(body, f.Store.LoadJournal(f.Owner(), request.RequestId).BodyJson, "large altered proof keeps exact original");
                f.Get = (message, ct) => Ready(Json(View(body)));
                Equal(MutationOutcome.Confirmed, (await f.Session.ReconcileUnitExportAsync(request.RequestId, f.Owner(), CancellationToken.None)).Outcome, "matching large proof later confirms only original");
                await ExpectCode("RESPONSE_TOO_LARGE", () => f.Session.GetAsync("report-export-jobs/" + Job, CancellationToken.None));
                Equal(Job, SessionCoordinator.ParseUnitExportJob(await f.Session.GetUnitExportJobJsonAsync(Job, CancellationToken.None), Job).Id, "only reviewed job read receives proof budget");
                var metadata = View(null).TrimEnd('}') + ",\"attempt\":1,\"precisionRequirement\":null,\"precisionChoices\":null,\"totalRows\":9007199254740993}";
                True(SessionCoordinator.ParseRecentUnitExportJobs("[" + metadata + "]").Count == 1, "current optional server metadata remains readable");
                ThrowsFormat(() => SessionCoordinator.ParseRecentUnitExportJobs("[" + View(body) + "]"));
                Equal(1, f.Posts, "changed/read-only proof never repeats creation");
            }
            Console.WriteLine("PASS large changed proof/current View/Recent2MiB/ordinary response2MiB isolation; selected=50001");
        }
        private static async Task LegacyOriginalEnvelopeStaysOriginal()
        {
            using (var f = new Fixture())
            {
                await f.Login(); var body = LargeSubmitBody(1000); var request = f.Submit(body);
                f.Post = (message, ct) => { throw new HttpRequestException("fixture accepted reply lost"); };
                await f.Session.MutateAsync(request, CancellationToken.None);
                var output = Directory.GetFiles(f.State.RootDirectory, "unit-export-mutations.dpapi", SearchOption.AllDirectories).Single();
                var plain = Unprotect(output); var old = Path.Combine(Path.GetDirectoryName(output), "mutations.dpapi");
                Protect(old, plain); File.Delete(output); // only this disposable synthetic fixture
                f.Get = (message, ct) => Ready(Json(View(body)));
                var result = await f.Session.ReconcileUnitExportAsync(request.RequestId, f.Owner(), CancellationToken.None);
                True(result.Outcome == MutationOutcome.Confirmed && result.IsDurablyRecorded && File.Exists(old) && !File.Exists(output), "legacy original remains its original envelope");
                Equal(body, f.Store.LoadJournal(f.Owner(), request.RequestId).BodyJson, "legacy upgrade retains raw original body");
            }
            Console.WriteLine("PASS existing mutations.dpapi original export ticket is read and settled in original document");
        }
        private static async Task RequestByteBoundaryAndRetentionQuota()
        {
            using (var f = new Fixture())
            {
                await f.Login(); string small = SubmitBody();
                string maximum = new string(' ', UnitExportBudget.RequestBytes - Encoding.UTF8.GetByteCount(small)) + small;
                var first = f.Submit(maximum);
                Equal(UnitExportBudget.RequestBytes, Encoding.UTF8.GetByteCount(first.BodyJson), "16MiB exact output byte budget");
                var second = f.Submit(maximum);
                ThrowsCode("MUTATION_JOURNAL_FULL", () => f.Submit(maximum));
                ThrowsCode("MUTATION_BODY_INVALID", () => f.Submit(" " + maximum));
                foreach (var action in new[] { MutationAction.UnitCreate, MutationAction.UnitBatchStatus, MutationAction.UnitBatchDelete })
                    ThrowsApi(() => SessionCoordinator.BuildMutationRequest(action, NewId(), new string(' ', 65537) + "{}", f.Owner()));
                Equal(0, f.Posts, "byte/quota refusal never reaches transport");
                Equal(0, f.Store.ListJournal(f.Owner()).Count, "prepare budget refusal cannot manufacture durable/sent entries");
                f.Post = (message, ct) => { throw new HttpRequestException("fixture accepted original maximum request then disconnected"); };
                var unknown = await f.Session.MutateAsync(first, CancellationToken.None);
                True(unknown.Outcome == MutationOutcome.Unknown && unknown.IsDurablyRecorded, "maximum request is durably kept without guessed outcome");
                var path = Directory.GetFiles(f.State.RootDirectory,"unit-export-mutations.dpapi",SearchOption.AllDirectories).Single();
                var originalEncrypted = File.ReadAllBytes(path);
                var refused = await f.Session.MutateAsync(second, CancellationToken.None);
                True(refused.Outcome == MutationOutcome.NotSent && f.Posts == 1, "journal reserves original-receipt capacity before dispatch, no hidden retry");
                True(originalEncrypted.SequenceEqual(File.ReadAllBytes(path)), "output quota never evicts or rewrites the original unknown envelope");
                Equal(maximum, f.Store.LoadJournal(f.Owner(), first.RequestId).BodyJson, "maximum original body survives quota refusal");
            }
            Console.WriteLine("PASS exact16MiB/>16MiB output bytes,32MiB retained budget,64MiB receipt reservation and original ordinary-write bounds; quota refusal before second send");
        }
        private static HttpResponseMessage WireRoundTrip(HttpRequestMessage message, string json)
        {
            byte[] payload = Encoding.UTF8.GetBytes(json);
            byte[] header = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + payload.Length + "\r\n\r\n");
            using (var wire = new WireFixture(header.Concat(payload).ToArray()))
            {
                var response = ManagedHttp11.SendAndReceive(wire, message, UnitExportReplyPermit.ResponseLimit(message, 2097152), CancellationToken.None);
                string expected = message.Content == null ? "" : message.Content.ReadAsStringAsync().GetAwaiter().GetResult();
                True(Encoding.UTF8.GetString(wire.Written.ToArray()).EndsWith("\r\n\r\n" + expected, StringComparison.Ordinal), "same managed HTTP codec emits every original request byte");
                return response;
            }
        }
        private sealed class WireFixture : Stream
        {
            private readonly MemoryStream input;
            internal readonly MemoryStream Written = new MemoryStream();
            internal WireFixture(byte[] bytes) { input = new MemoryStream(bytes, false); }
            public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => true;
            public override long Length => throw new NotSupportedException(); public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
            public override int Read(byte[] buffer,int offset,int count) { return input.Read(buffer,offset,count); }
            public override void Write(byte[] buffer,int offset,int count) { Written.Write(buffer,offset,count); }
            public override void Flush() { } public override long Seek(long offset,SeekOrigin origin) { throw new NotSupportedException(); }
            public override void SetLength(long value) { throw new NotSupportedException(); }
            protected override void Dispose(bool disposing) { if(disposing) { input.Dispose(); Written.Dispose(); } base.Dispose(disposing); }
        }
        public static int RunSharedSelectionFixture()
        {
            var json = new System.Web.Script.Serialization.JavaScriptSerializer();
            using (var stream = typeof(SessionCoordinator).Assembly.GetManifestResourceStream("Uten.Legacy.Core.TableOutputSelectionFixture.json"))
            using (var reader = new StreamReader(stream ?? throw new InvalidOperationException("Missing shared table output fixture."), Encoding.UTF8))
            {
                var fixture = (Dictionary<string, object>)json.DeserializeObject(reader.ReadToEnd()); int count = 0;
                foreach (Dictionary<string, object> sample in (object[])fixture["cases"])
                {
                    string raw = sample["raw"] as string;
                    string body = raw == null ? SubmitBody() : SubmitBody().Replace("\"parameters\":{", "\"parameters\":{\"selectedIds\":" + json.Serialize(raw) + ",");
                    bool valid = true;
                    try { UnitExportMutationContract.SubmitObject(MutationJsonTree.Parse(body, 65536, false, 4096, false, true).Object); }
                    catch (FormatException) { valid = false; }
                    True(valid == (bool)sample["valid"], "shared selection fixture " + sample["name"]); count++;
                }
                string projection = "{\"tableKey\":\"master.unit\",\"scope\":\"master_unit\",\"columns\":[{\"key\":\"code\",\"label\":\"Code\",\"type\":\"text\"},{\"key\":\"name\",\"label\":\"Name\",\"type\":\"text\"},{\"key\":\"status\",\"label\":\"Status\",\"type\":\"text\"}]}";
                var original = MutationJsonTree.Parse(projection,65536,false,4096,false,true);
                var serverNull = MutationJsonTree.Parse(projection.Insert(1,"\"rowSelection\":null,"),65536,false,4096,false,true);
                True(UnitColumnProjectionContract.Equivalent(original,serverNull), "optional server null rowSelection cannot block original native GET proof");
                ThrowsFormat(()=>UnitColumnProjectionContract.Validate(MutationJsonTree.Parse(projection.Insert(1,"\"rowSelection\":[],"),65536,false,4096,false,true)));
                return count;
            }
        }
        public static int RunSharedCapabilityFixture()
        {
            var json=new System.Web.Script.Serialization.JavaScriptSerializer();
            using(var stream=typeof(SessionCoordinator).Assembly.GetManifestResourceStream("Uten.Legacy.Core.TableOutputSelectionFixture.json"))
            using(var reader=new StreamReader(stream??throw new InvalidOperationException("Missing shared table output fixture."),Encoding.UTF8))
            {
                var fixture=(Dictionary<string,object>)json.DeserializeObject(reader.ReadToEnd());int count=0;
                foreach(Dictionary<string,object> sample in (object[])fixture["handshakeCases"])
                {
                    var value=(int)sample["status"]==404?new UnitExportCapabilities(false,0):SessionCoordinator.ParseUnitExportCapabilities(json.Serialize(sample["body"]));
                    True(value.Available==(bool)sample["available"],"shared capability availability "+sample["name"]);
                    True(value.SupportsSelection==(bool)sample["selectionAllowed"],"shared selected output gate "+sample["name"]);count++;
                }
                return count;
            }
        }
        private static async Task SelectedProofCannotExpandToAll()
        {
            using (var f = new Fixture())
            {
                await f.Login();
                var body = SubmitBody().Replace("\"parameters\":{", "\"parameters\":{\"selectedIds\":\"[\\\"" + Other + "\\\"]\",");
                var original = f.Submit(body);
                f.Post = (message, ct) => { throw new HttpRequestException("fixture lost selected submit"); };
                await f.Session.MutateAsync(original, CancellationToken.None);
                f.Get = (message, ct) => Ready(Json(View(SubmitBody())));
                try { await f.Session.ReconcileUnitExportAsync(original.RequestId, f.Owner(), CancellationToken.None); }
                catch (ApiException) { }
                Equal(MutationJournalState.Unknown, (await f.Session.LoadMutationJournalAsync(original.RequestId, f.Owner(), CancellationToken.None)).State,
                    "all-row proof cannot settle the original selected export");
                f.Get = (message, ct) => Ready(Json(View(body)));
                Equal(MutationOutcome.Confirmed, (await f.Session.ReconcileUnitExportAsync(original.RequestId, f.Owner(), CancellationToken.None)).Outcome,
                    "exact frozen selected UUID proof settles only that original job");
                Equal(1, f.Posts, "selection reconciliation never replays job submission");
            }
        }
        private static async Task ExactSubmitAndCredentialBoundary()
        {
            using (var f = new Fixture())
            {
                await f.Login(); var body = SubmitBody(); var request = f.Submit(body);
                Equal("report-export-jobs", request.RelativePath, "fixed creation route"); Equal("POST", request.Method, "fixed creation method");
                True(request.ResourceId == Job && request.ServerIdempotencyKey == Job && request.ServerIdempotencyBodyField == "id"
                    && request.RequestIdBodyField == null && request.RequestId != Job, "server job ID is distinct from local correlation UUID");
                True(request.ServerIdempotencyAvailable && request.ReceiptStrategy == MutationReceiptStrategy.ExportJobCreation && request.ContractVersion == 3, "real server idempotency is action-specific");
                f.Post = async (message, ct) => { Equal(body, await message.Content.ReadAsStringAsync(), "filter JSON string and request original remain exact"); return Json(View(body)); };
                var result = await f.Session.MutateAsync(request, CancellationToken.None);
                True(result.Outcome == MutationOutcome.Confirmed && result.IsDurablyRecorded && result.ExportJob.Id == Job, "known submit result");
                foreach (var bad in new[] { body.Replace("\"master\"", "\"sales\""), body.Replace("\"unit\"", "\"goods\""), body.Replace("\"xlsx\"", "\"pdf\""),
                    body.Replace("\"columnProjection\":null", "\"columnProjection\":{}"), body.Replace("\"sort\":null", "\"sort\":\"name\""),
                    body.Replace("\"parameters\":{", "\"password\":\"secret\",\"parameters\":{") }) ThrowsApi(() => f.Submit(bad));
                ThrowsApi(() => f.Submit(SubmitBody("{\"password\":\"secret\"}")));
                ThrowsApi(() => f.Submit(SubmitBody("{\"token\":\"secret\"}")));
                ThrowsApi(() => f.Submit(SubmitBody("{\"nullFields\":[\"legacyId\"]}")));
                ThrowsApi(() => f.Session.PrepareMutation(MutationAction.UnitExportSubmit, NewId(), body, f.Owner(), Other));
                var path = Directory.GetFiles(f.State.RootDirectory, "unit-export-mutations.dpapi", SearchOption.AllDirectories).Single();
                var plain = Unprotect(path);
                foreach (var forbidden in new[] { "\"password\"", "fixture-password", "access-fixture", "refresh-fixture" })
                    True(!plain.Contains(forbidden), "no auth material in durable export command");
            }
            using (var f = new Fixture()) { f.Permissions = new[] { "unit:view" }; await f.Login(); ThrowsCode("FORBIDDEN", () => f.Submit(SubmitBody())); }
        }
        private static async Task CancelNoBodyAndActualJobState()
        {
            foreach (var body in new[] { null, "", "{}" })
            using (var f = new Fixture())
            {
                await f.Login(); var request = f.Session.PrepareMutation(MutationAction.UnitExportCancel, NewId(), body, f.Owner(), Job);
                True(!request.ServerIdempotencyAvailable && request.ReceiptStrategy == MutationReceiptStrategy.ExportJobStateQuery, "cancel is a state query, not a creation receipt");
                f.Post = async (message, ct) =>
                {
                    if (body == null) True(message.Content == null, "no-body caller remains a genuinely body-free request");
                    else Equal(body, await message.Content.ReadAsStringAsync(), "explicit empty/object body retains presence");
                    return Json(View(null, "SUCCEEDED"));
                };
                var result = await f.Session.MutateAsync(request, CancellationToken.None);
                True(result.Outcome == MutationOutcome.Confirmed && result.ExportJob.Status == "SUCCEEDED" && !result.ExportJob.CancelRequested,
                    "known cancel response can report already-finished job, never fake cancelled");
                Equal(body, (await f.Session.LoadMutationJournalAsync(request.RequestId, f.Owner(), CancellationToken.None)).BodyJson, "no body is not converted into JSON null/object");
                await ExpectCode("EXPORT_RECEIPT_NOT_APPLICABLE", () => f.Session.ReconcileUnitExportAsync(request.RequestId, f.Owner(), CancellationToken.None));
                Equal(0, f.Gets, "creation-only receipt helper rejects cancel without HTTP");
            }
        }
        private static async Task KnownJobAcceptanceIsNotFileDelivery()
        {
            foreach (var state in new[] { "PENDING", "RUNNING", "SUCCEEDED", "FAILED", "CANCELLED", "EXPIRED" })
            using (var f = new Fixture())
            {
                await f.Login(); f.Post = (message, ct) => Ready(Json(View(null, state)));
                var result = await f.Session.MutateAsync(f.Submit(SubmitBody()), CancellationToken.None);
                True(result.Outcome == MutationOutcome.Confirmed && result.ExportJob.Status == state && !result.ExportJob.HasCreationRequestProof,
                    "accepted command and current worker/file state are separate " + state);
                Equal(1, f.Posts, "one creation request");
            }
            foreach (var bad in new[] { View(null).Replace(Job, Other), View(null).Replace("\"unit\"", "\"goods\""),
                View(null).Replace("\"rows\":0", "\"rows\":0.0"), View(null).Replace("\"cancelRequested\":false", "\"cancelRequested\":\"false\"") })
            using (var f = new Fixture())
            { await f.Login(); f.Post = (message, ct) => Ready(Json(bad)); Equal(MutationOutcome.Unknown, (await f.Session.MutateAsync(f.Submit(SubmitBody()), CancellationToken.None)).Outcome, "bad JobView is not a receipt"); }
        }
        private static async Task ServerKeyCannotChangeFrozenBody()
        {
            using (var f = new Fixture())
            {
                await f.Login(); f.Post = (message, ct) => { throw new HttpRequestException("fixture reply lost"); };
                var original = f.Submit(SubmitBody()); await f.Session.MutateAsync(original, CancellationToken.None);
                var edited = await f.Session.MutateAsync(f.Submit(SubmitBody("{\"keyword\":\"new\"}")), CancellationToken.None);
                True(edited.Outcome == MutationOutcome.NotSent && edited.Error.Code == "MUTATION_SERVER_KEY_CHANGED", "new local UUID cannot change existing server key intent");
                Equal(1, f.Posts, "changed key payload never reaches server");
                Equal(original.BodyJson, (await f.Session.LoadMutationJournalAsync(original.RequestId, f.Owner(), CancellationToken.None)).BodyJson, "original frozen payload survives");
            }
        }
        private static async Task VerifiedGetRequestProofSettlesOnlyOriginalSubmit()
        {
            using (var f = new Fixture())
            {
                await f.Login(); var body = SubmitBody(); f.Post = (message, ct) => { throw new HttpRequestException("fixture accepted but reply lost"); };
                var original = f.Submit(body); var uncertain = await f.Session.MutateAsync(original, CancellationToken.None);
                True(uncertain.Outcome == MutationOutcome.Unknown && uncertain.NeedsReceiptQuery, "lookup supported without automatic write replay");
                // The server normalizes absent/null optional DTO fields. The filter STRING
                // itself stays exact: parsed object equality is intentionally insufficient.
                var proof = body.Replace(",\"format\":\"xlsx\"", "").Replace(",\"sort\":null", "").Replace(",\"order\":null", "").Replace(",\"columnProjection\":null", "");
                f.Get = (message, ct) => Ready(Json(View(proof, "RUNNING", 9007199254740993L)));
                var confirmed = await f.Session.ReconcileUnitExportAsync(original.RequestId, f.Owner(), CancellationToken.None);
                True(confirmed.Outcome == MutationOutcome.Confirmed && confirmed.ConfirmedByReceiptQuery && confirmed.IsDurablyRecorded,
                    "server-owned original request proves the matching logical creation");
                Equal(9007199254740993L, confirmed.ExportJob.Bytes, "Int64 metadata not rounded");
                var saved = await f.Session.LoadMutationJournalAsync(original.RequestId, f.Owner(), CancellationToken.None);
                True(saved.State == MutationJournalState.Confirmed && saved.ConfirmedByReceiptQuery && saved.ReceiptStrategy == MutationReceiptStrategy.ExportJobCreation,
                    "only original matching journal settled by receipt");
                Equal(body, saved.BodyJson, "proof never replaces original raw request"); Equal(1, f.Posts, "receipt lookup emits no POST"); Equal(1, f.Gets, "one fixed GET");
                var again = await f.Session.ReconcileUnitExportAsync(original.RequestId, f.Owner(), CancellationToken.None);
                True(again.Outcome == MutationOutcome.Confirmed && f.Gets == 1, "durable known result does not query/replay again");
            }
        }
        private static async Task MissingOrDifferentProofStaysUnknown()
        {
            foreach (var mode in new[] { "absent", "null", "filter", "id", "404" })
            using (var f = new Fixture())
            {
                await f.Login(); var body = SubmitBody(); f.Post = (message, ct) => { throw new HttpRequestException("fixture lost"); };
                var original = f.Submit(body); await f.Session.MutateAsync(original, CancellationToken.None);
                f.Get = (message, ct) => Ready(mode == "404" ? Json("{\"code\":\"NOT_FOUND\",\"message\":\"fixture\"}", 404)
                    : Json(mode == "absent" ? View(null) : mode == "null" ? View(null).TrimEnd('}') + ",\"request\":null}"
                    : View(mode == "id" ? body.Replace(Job, Other) : SubmitBody("{\"keyword\":\"other\"}"))));
                var result = await f.Session.ReconcileUnitExportAsync(original.RequestId, f.Owner(), CancellationToken.None);
                True(result.Outcome == MutationOutcome.Unknown && result.ResponseJson == null && result.IsDurablyRecorded, "unverified proof stays durably unknown " + mode);
                Equal(MutationJournalState.Unknown, (await f.Session.LoadMutationJournalAsync(original.RequestId, f.Owner(), CancellationToken.None)).State, "GET metadata alone cannot claim accepted original");
                Equal(1, f.Posts, "no hidden re-submit");
            }
        }
        private static async Task ExplicitSameKeyRetryNeverCreatesNewIdentity()
        {
            using (var f = new Fixture())
            {
                await f.Login(); var body = SubmitBody(); var created = false; var actualCreations = 0;
                f.Post = async (message, ct) =>
                {
                    Equal(body, await message.Content.ReadAsStringAsync(), "explicit idempotent retry is the complete same frozen payload");
                    if (!created) { created = true; actualCreations++; throw new HttpRequestException("fixture committed then disconnected"); }
                    return Json(View(null));
                };
                var original = f.Submit(body); await f.Session.MutateAsync(original, CancellationToken.None);
                var retry = f.Submit(original.BodyJson);
                True(retry.RequestId != original.RequestId && retry.ServerIdempotencyKey == original.ServerIdempotencyKey, "new explicit attempt keeps original server command identity");
                Equal(MutationOutcome.Confirmed, (await f.Session.MutateAsync(retry, CancellationToken.None)).Outcome, "explicit old-server retry verifies via submit body equality");
                Equal(1, actualCreations, "true server idempotency creates one job"); Equal(2, f.Posts, "exactly two human-controlled calls, no automatic loop");
            }
        }
        private static async Task ReceiptPersistenceFailureKeepsKnownOutcome()
        {
            var fail = false;
            using (var state = new BusinessStateTestFixture(point => { if (fail && point.EndsWith(":before-replace", StringComparison.Ordinal)) throw new IOException("fixture receipt storage failure"); }))
            using (var f = new Fixture(state.Store))
            {
                await f.Login(); var body = SubmitBody(); f.Post = (message, ct) => { throw new HttpRequestException("fixture lost"); };
                var original = f.Submit(body); await f.Session.MutateAsync(original, CancellationToken.None);
                f.Get = (message, ct) => Ready(Json(View(body))); fail = true;
                var known = await f.Session.ReconcileUnitExportAsync(original.RequestId, f.Owner(), CancellationToken.None);
                True(known.Outcome == MutationOutcome.Confirmed && !known.IsDurablyRecorded && known.PersistenceError != null && known.ExportJob.Id == Job,
                    "valid remote proof stays known when local commit fails");
                fail = false;
                Equal(MutationJournalState.Unknown, (await f.Session.LoadMutationJournalAsync(original.RequestId, f.Owner(), CancellationToken.None)).State, "failed local receipt commit preserves original unknown bytes");
                Equal(1, f.Posts, "local failure never replays creation");
            }
        }
        private static async Task LateReceiptCannotEnterNewOwner()
        {
            using (var f = new Fixture())
            {
                await f.Login(); var body = SubmitBody(); f.Post = (message, ct) => { throw new HttpRequestException("fixture lost"); };
                var original = f.Submit(body); await f.Session.MutateAsync(original, CancellationToken.None); var owner = f.Owner();
                var entered = new TaskCompletionSource<bool>(); var release = new TaskCompletionSource<HttpResponseMessage>();
                f.Get = (message, ct) => { entered.SetResult(true); return release.Task; };
                var pending = f.Session.ReconcileUnitExportAsync(original.RequestId, owner, CancellationToken.None); await entered.Task;
                f.Session.SelectEndpoint("cloud"); release.SetResult(Json(View(body)));
                await ExpectAnyApi(() => pending);
                Equal(MutationJournalState.Unknown, f.Store.LoadJournal(owner, original.RequestId).State, "old proof does not settle into replacement context");
                Equal(1, f.Posts, "no late cross-origin write");
            }
        }
        private static async Task CorruptReceiptMetadataFailsClosed()
        {
            using (var f = new Fixture())
            {
                await f.Login(); var body = SubmitBody(); f.Post = (message, ct) => Ready(Json(View(body)));
                await f.Session.MutateAsync(f.Submit(body), CancellationToken.None);
                var file = Directory.GetFiles(f.State.RootDirectory, "unit-export-mutations.dpapi", SearchOption.AllDirectories).Single();
                var document = JsonValue.ParseObject(Unprotect(file)); var entry = (Dictionary<string, object>)((object[])document["entries"])[0];
                entry["serverIdempotencyKey"] = Other;
                Protect(file, JsonValue.Serialize(document)); var before = File.ReadAllBytes(file);
                await ExpectCode("LOCAL_BUSINESS_STORAGE", () => f.Session.ListMutationJournalAsync(f.Owner(), CancellationToken.None));
                True(before.SequenceEqual(File.ReadAllBytes(file)), "tampered server key is not silently repaired"); Equal(1, f.Posts, "corruption never triggers POST");
            }
        }
        private static void PureMetadataParserDoesNotTreatPresenceAsProof()
        {
            var unit = View(SubmitBody(), "RUNNING", 9007199254740993L);
            var metadata = SessionCoordinator.ParseUnitExportJob(unit, Job);
            True(metadata.Id == Job && metadata.Bytes == 9007199254740993L && !metadata.HasCreationRequestProof,
                "metadata-only parser preserves Int64 without treating request presence as verified receipt");
            var foreign = View(null).Replace("\"master\"", "\"sales\"").Replace(Job, Other);
            var recent = SessionCoordinator.ParseRecentUnitExportJobs("[" + foreign + "," + unit + "]");
            True(recent.Count == 1 && recent[0].Id == Job && !recent[0].HasCreationRequestProof, "recent filters other reports and never fabricates proof");
            ThrowsFormat(() => SessionCoordinator.ParseUnitExportJob(unit, Other));
            ThrowsFormat(() => SessionCoordinator.ParseRecentUnitExportJobs("[" + unit + "," + unit + "]"));
            ThrowsFormat(() => SessionCoordinator.ParseUnitExportJob(unit.Replace(Job, "not-a-uuid"), Job));
        }
        private static string SubmitBody(string filter = Filter)
        { return "{\"id\":\"" + Job + "\",\"domain\":\"master\",\"report\":\"unit\",\"format\":\"xlsx\",\"parameters\":{\"filter\":" + JsonValue.Serialize(filter) + "},\"sort\":null,\"order\":null,\"columnProjection\":null}"; }
        private static string View(string proof, string status = "PENDING", long bytes = 0)
        { return "{\"id\":\"" + Job + "\",\"domain\":\"master\",\"report\":\"unit\",\"format\":\"xlsx\",\"status\":\"" + status + "\",\"cancelRequested\":false,\"rows\":0,\"bytes\":" + bytes
            + ",\"snapshotAt\":null,\"error\":null,\"createdAt\":\"2026-10-28T12:00:00+08:00\",\"finishedAt\":null" + (proof == null ? "" : ",\"request\":" + proof) + "}"; }
        private static string NewId() { return Guid.NewGuid().ToString("D"); }
        private static HttpResponseMessage Json(string json, int status = 200) { return new HttpResponseMessage((HttpStatusCode)status) { Content = new StringContent(json, Encoding.UTF8, "application/json") }; }
        private static Task<HttpResponseMessage> Ready(HttpResponseMessage value) { return Task.FromResult(value); }
        private static byte[] Entropy(string file) { return Encoding.UTF8.GetBytes("Uten/UIMP-Win7-WPF/business-state/v1/" + Path.GetFileNameWithoutExtension(file) + "/" + Path.GetFileName(Path.GetDirectoryName(file))); }
        private static string Unprotect(string file) { var plain = ProtectedData.Unprotect(File.ReadAllBytes(file), Entropy(file), DataProtectionScope.CurrentUser); try { return Encoding.UTF8.GetString(plain); } finally { Array.Clear(plain, 0, plain.Length); } }
        private static void Protect(string file, string value) { var plain = Encoding.UTF8.GetBytes(value); try { File.WriteAllBytes(file, ProtectedData.Protect(plain, Entropy(file), DataProtectionScope.CurrentUser)); } finally { Array.Clear(plain, 0, plain.Length); } }
        private static void True(bool condition, string label) { if (!condition) throw new InvalidOperationException("Unit export mutation: " + label); }
        private static void Equal<T>(T expected, T actual, string label) { True(EqualityComparer<T>.Default.Equals(expected, actual), label); }
        private static void ThrowsApi(Action action) { try { action(); } catch (ApiException) { return; } throw new InvalidOperationException("Expected API failure"); }
        private static void ThrowsFormat(Action action) { try { action(); } catch (FormatException) { return; } throw new InvalidOperationException("Expected malformed metadata rejection"); }
        private static void ThrowsCode(string code, Action action) { try { action(); } catch (ApiException e) { Equal(code, e.Code, "expected failure"); return; } throw new InvalidOperationException("Expected " + code); }
        private static async Task ExpectCode(string code, Func<Task> action) { try { await action(); } catch (ApiException e) { Equal(code, e.Code, "expected failure"); return; } throw new InvalidOperationException("Expected " + code); }
        private static async Task ExpectAnyApi(Func<Task> action) { try { await action(); } catch (ApiException) { return; } throw new InvalidOperationException("Expected API failure"); }
        private sealed class Fixture : IDisposable
        {
            internal readonly BusinessStateTestFixture State;
            internal readonly IBusinessStateStore Store;
            internal readonly SessionCoordinator Session;
            internal string[] Permissions = { "unit:view", "unit:export" };
            internal int Posts, Gets;
            internal Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> Post, Get;
            internal Fixture() : this(null, true) { }
            internal Fixture(IBusinessStateStore store) : this(store, false) { }
            private Fixture(IBusinessStateStore store, bool owned)
            {
                if (owned) { State = new BusinessStateTestFixture(); store = State.Store; } Store = store;
                var config = new ClientConfiguration(new[] { new ServerEndpoint("company", "private fixture", "https://company.example.test/api"),
                    new ServerEndpoint("cloud", "private cloud fixture", "https://cloud.example.test/api") }, "company", 5);
                Session = new SessionCoordinator(config, new Handler((message, ct) =>
                {
                    if (message.RequestUri.AbsolutePath == "/api/auth/login" || message.RequestUri.AbsolutePath == "/api/auth/refresh")
                        return Ready(Json("{\"accessToken\":\"access-fixture\",\"refreshToken\":\"refresh-fixture\",\"expiresIn\":900,\"user\":{\"id\":\"unit-export-core-owner\",\"loginAccount\":\"UT0001\",\"superAdmin\":false,\"mustChangePassword\":false,\"permissions\":"
                            + JsonValue.Serialize(Permissions) + ",\"businessDatasetId\":\"11111111-1111-1111-1111-111111111111\",\"businessResetGeneration\":0}}"));
                    if (message.RequestUri.AbsolutePath == "/api/auth/logout") return Ready(Json("", 204));
                    True(message.RequestUri.Host == "company.example.test" && !message.Headers.Contains(StepUpGrant.HeaderName), "only original fixed issuer, no password/token headers");
                    if (message.Method == HttpMethod.Get)
                    { Interlocked.Increment(ref Gets); Equal("/api/report-export-jobs/" + Job, message.RequestUri.AbsolutePath, "fixed receipt GET"); return Get == null ? Ready(Json(View(null))) : Get(message, ct); }
                    Interlocked.Increment(ref Posts);
                    True(message.Method == HttpMethod.Post && (message.RequestUri.AbsolutePath == "/api/report-export-jobs" || message.RequestUri.AbsolutePath == "/api/report-export-jobs/" + Job + "/cancel"), "fixed creation/cancel routes only");
                    return Post == null ? Ready(Json(View(null))) : Post(message, ct);
                }), new AuthStore(), store);
            }
            internal Task Login() { return Session.LoginAsync("fixture", "fixture-password", CancellationToken.None); }
            internal MutationOwnerSnapshot Owner() { return Session.CaptureMutationOwner(); }
            internal MutationRequest Submit(string body) { return Session.PrepareMutation(MutationAction.UnitExportSubmit, NewId(), body, Owner()); }
            public void Dispose() { Session.Dispose(); State?.Dispose(); }
        }
        private sealed class Handler : HttpMessageHandler
        {
            private readonly Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action;
            internal Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action) { this.action = action; }
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) { return action(request, ct); }
        }
        private sealed class AuthStore : ISessionStore
        {
            private StoredSession active; private readonly List<StoredSession> pending = new List<StoredSession>();
            public StoredSession Load() { return active; } public void Save(StoredSession value) { active = value; } public void Clear() { active = null; }
            public void EndSession(StoredSession value) { EnqueueRevocation(value ?? active); active = null; }
            public void EnqueueRevocation(StoredSession value) { if (value != null && !pending.Any(item => item.Id == value.Id)) pending.Add(value); }
            public IList<StoredSession> PendingRevocations() { return pending.ToList(); } public void AcknowledgeRevocation(string id) { pending.RemoveAll(value => value.Id == id); }
        }
    }
}
