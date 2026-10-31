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
    public static class BusinessStateContractChecks
    {
        private const string UnitId = "22222222-2222-2222-2222-222222222222";
        private const string UnitReply = "{\"id\":\"" + UnitId + "\",\"name\":\"kg\",\"status\":\"使用\"}";
        private const string ValidBody = " { \"name\" : \"kg\", \"measurementDimension\" : null } ";

        public static void Run()
        {
            IncompleteDraftAndExactRoundTrip().GetAwaiter().GetResult();
            DraftCasAndCrossStoreConcurrency().GetAwaiter().GetResult();
            RetiredLeaseAndNamespaceIsolation().GetAwaiter().GetResult();
            RestoredDraftDoesNotRestoreWriteAuthority().GetAwaiter().GetResult();
            NoStoreFailsClosed().GetAwaiter().GetResult();
            SendingIsDurableBeforeHandler().GetAwaiter().GetResult();
            FailedCheckpointNeverSends().GetAwaiter().GetResult();
            KnownOutcomeSurvivesCompletionStorageFailure().GetAwaiter().GetResult();
            CrashedSendingRecoversUnknownAndCannotResend().GetAwaiter().GetResult();
            LiveAttemptsAndConfirmedDraftRevisionCannotReplay().GetAwaiter().GetResult();
            DefiniteNoSendOrRejectionAllowsExplicitNewIntent().GetAwaiter().GetResult();
            AtomicDraftFailurePreservesOriginal().GetAwaiter().GetResult();
            CorruptionFailsClosedAndPreservesBytes().GetAwaiter().GetResult();
            CheckpointOwnerRetirementDoesNotSend().GetAwaiter().GetResult();
            ReviewNoteNeverClaimsReceipt().GetAwaiter().GetResult();
        }

        private static async Task IncompleteDraftAndExactRoundTrip()
        {
            const string original = " { \"name\":\"\", \"status\":\"尚在编辑\", \"code\":null, \"measurementDimension\":null, \"massUnitCode\":\"line\\ninput\" } \n";
            using (var state = new BusinessStateTestFixture())
            using (var fixture = new Fixture(state.Store))
            {
                await fixture.Login(); var owner = fixture.Owner();
                var lease = fixture.Session.CreateDraftLease(MutationAction.UnitCreate, NewId(), owner);
                var saved = await fixture.Session.SaveDraftAsync(lease, 0, original, CancellationToken.None);
                Equal(1L, saved.Revision, "new draft local CAS starts at one");
                Equal(original, (await fixture.Session.LoadDraftAsync(saved.DraftId, owner, CancellationToken.None)).BodyJson, "incomplete raw form survives exactly");
                True(saved.RequiresRevalidation, "loading a draft never authorizes automatic submit");
                await ThrowsApi(() => fixture.Session.PrepareMutationFromDraftAsync(NewId(), saved.DraftId, 1, owner, CancellationToken.None));
                foreach (var bad in new[] { "{\"name\":\"kg\",\"password\":\"secret\"}", "{\"accessToken\":\"secret\"}",
                    "{\"refreshToken\":\"secret\"}", "{\"stepUpToken\":\"secret\"}", "{\"name\":\"a\",\"name\":\"b\"}",
                    "{\"name\":{\"nested\":\"data\"}}", "{\"name\":\"" + new string('x', 65536) + "\"}" })
                    await ThrowsApi(() => fixture.Session.SaveDraftAsync(lease, 1, bad, CancellationToken.None));
                var files = Directory.GetFiles(state.RootDirectory, "*.dpapi", SearchOption.AllDirectories);
                Equal(1, files.Length, "only independent draft file created");
                var rawBytes = File.ReadAllBytes(files[0]);
                True(!Encoding.UTF8.GetString(rawBytes).Contains("尚在编辑"), "disk envelope is DPAPI ciphertext");
                var plain = Unprotect(files[0], "drafts");
                foreach (var key in new[] { "password", "accessToken", "refreshToken", "stepUpToken", "deviceName" })
                    True(!plain.Contains("\"" + key + "\""), "business document contains no auth material key " + key);
                True(!Directory.GetFiles(state.RootDirectory, "*.tmp", SearchOption.AllDirectories).Any(), "no temporary plaintext or orphan output");
                Equal(0, fixture.Writes, "draft work never invokes business network");
            }
        }

        private static async Task DraftCasAndCrossStoreConcurrency()
        {
            using (var state = new BusinessStateTestFixture())
            using (var fixture = new Fixture(state.Store))
            using (var secondStore = new DpapiBusinessStateStore(state.RootDirectory))
            {
                await fixture.Login(); var owner = fixture.Owner(); var lease = fixture.Lease(owner);
                var first = await fixture.Session.SaveDraftAsync(lease, 0, "{\"name\":\"a\"}", CancellationToken.None);
                await ExpectCode("DRAFT_CONFLICT", () => fixture.Session.SaveDraftAsync(lease, 0, "{\"name\":\"b\"}", CancellationToken.None));
                Equal(first.Revision, (await fixture.Session.SaveDraftAsync(lease, 1, first.BodyJson, CancellationToken.None)).Revision, "unchanged autosave cannot invent revision");
                var outcomes = await Task.WhenAll(Task.Run(() => SaveOutcome(state.Store, lease, 1, "{\"name\":\"b\"}")),
                    Task.Run(() => SaveOutcome(secondStore, lease, 1, "{\"name\":\"c\"}")));
                Equal(1, outcomes.Count(value => value == "saved"), "cross-store CAS has exactly one winner");
                Equal(1, outcomes.Count(value => value == "DRAFT_CONFLICT"), "loser is explicit, never overwrites new content");
                var after = secondStore.LoadDraft(owner, lease.DraftId);
                Equal(2L, after.Revision, "one actual edit revision");
                True(after.BodyJson == "{\"name\":\"b\"}" || after.BodyJson == "{\"name\":\"c\"}", "complete winner body retained");
                await ExpectCode("DRAFT_CONFLICT", () => fixture.Session.DeleteDraftAsync(lease.DraftId, 1, owner, CancellationToken.None));
                await fixture.Session.DeleteDraftAsync(lease.DraftId, 2, owner, CancellationToken.None);
                True(await fixture.Session.LoadDraftAsync(lease.DraftId, owner, CancellationToken.None) == null, "explicit matching draft deletion");
            }
        }

        private static async Task RetiredLeaseAndNamespaceIsolation()
        {
            using (var state = new BusinessStateTestFixture())
            using (var fixture = new Fixture(state.Store))
            {
                await fixture.Login(); var originalOwner = fixture.Owner(); var lease = fixture.Lease(originalOwner);
                await fixture.Session.SaveDraftAsync(lease, 0, "{\"name\":\"original\"}", CancellationToken.None);
                fixture.Session.SelectEndpoint("cloud"); fixture.UserId = "user-b"; await fixture.Login();
                var newOwner = fixture.Owner();
                var lateSave = await fixture.Session.SaveDraftAsync(lease, 1, "{\"name\":\"retired-input\"}", CancellationToken.None);
                Equal(originalOwner.UserId, lateSave.UserId, "retired lease never uses replacement account");
                Equal(originalOwner.IssuerApiBaseUrl, lateSave.IssuerApiBaseUrl, "retired lease never changes issuer");
                Equal(0, (await fixture.Session.ListDraftsAsync(newOwner, CancellationToken.None)).Count, "old draft cannot enter new namespace");
                await ThrowsApi(() => fixture.Session.LoadDraftAsync(lease.DraftId, originalOwner, CancellationToken.None));
                await ThrowsApi(() => fixture.Session.DeleteDraftAsync(lease.DraftId, 2, originalOwner, CancellationToken.None));
                using (var restarted = new Fixture(new DpapiBusinessStateStore(state.RootDirectory)))
                {
                    await restarted.Login();
                    var restored = await restarted.Session.LoadDraftAsync(lease.DraftId, restarted.Owner(), CancellationToken.None);
                    Equal(lateSave.BodyJson, restored.BodyJson, "original owner can explicitly recover retired edit after new login");
                    True(restored.RequiresRevalidation, "retired preservation is not a send capability");
                }
                foreach (var variation in new[] { "user", "dataset", "reset", "issuer" })
                using (var isolated = new Fixture(new DpapiBusinessStateStore(state.RootDirectory)))
                {
                    if (variation == "user") isolated.UserId = "user-c";
                    if (variation == "dataset") isolated.DatasetId = "33333333-3333-3333-3333-333333333333";
                    if (variation == "reset") isolated.ResetGeneration = 1;
                    if (variation == "issuer") isolated.Session.SelectEndpoint("cloud");
                    await isolated.Login();
                    Equal(0, (await isolated.Session.ListDraftsAsync(isolated.Owner(), CancellationToken.None)).Count, "namespace isolation " + variation);
                }
                Equal(0, fixture.Writes, "retired save is strictly local");
            }
        }

        private static async Task RestoredDraftDoesNotRestoreWriteAuthority()
        {
            using (var state = new BusinessStateTestFixture())
            {
                string draftId;
                using (var writer = new Fixture(new DpapiBusinessStateStore(state.RootDirectory)))
                {
                    await writer.Login(); var lease = writer.Lease(writer.Owner()); draftId = lease.DraftId;
                    await writer.Session.SaveDraftAsync(lease, 0, ValidBody, CancellationToken.None);
                }
                using (var reader = new Fixture(new DpapiBusinessStateStore(state.RootDirectory)))
                {
                    reader.Permissions = new[] { "unit:view" }; await reader.Login(); var owner = reader.Owner();
                    True((await reader.Session.LoadDraftAsync(draftId, owner, CancellationToken.None)).RequiresRevalidation, "lost write permission preserves authorized read-only review");
                    await ExpectCode("FORBIDDEN", () => reader.Session.PrepareMutationFromDraftAsync(NewId(), draftId, 1, owner, CancellationToken.None));
                    ThrowsCode("FORBIDDEN", () => reader.Session.CreateDraftLease(MutationAction.UnitCreate, draftId, owner));
                    Equal(0, reader.Writes, "read-only recovery never replays");
                }
                using (var denied = new Fixture(new DpapiBusinessStateStore(state.RootDirectory)))
                {
                    denied.Permissions = new string[0]; await denied.Login();
                    await ExpectCode("FORBIDDEN", () => denied.Session.ListDraftsAsync(denied.Owner(), CancellationToken.None));
                }
            }
        }

        private static async Task NoStoreFailsClosed()
        {
            using (var fixture = new Fixture(null))
            {
                await fixture.Login();
                var result = await fixture.Session.MutateAsync(fixture.Command(), CancellationToken.None);
                Equal(MutationOutcome.NotSent, result.Outcome, "unconfigured durable channel cannot write");
                Equal("DURABLE_MUTATION_STORE_REQUIRED", result.Error.Code, "clear durable prerequisite");
                Equal(0, fixture.Writes, "no handler request before durable store");
            }
        }

        private static async Task SendingIsDurableBeforeHandler()
        {
            using (var state = new BusinessStateTestFixture())
            using (var fixture = new Fixture(state.Store))
            {
                await fixture.Login(); var owner = fixture.Owner(); var lease = fixture.Lease(owner);
                var draft = await fixture.Session.SaveDraftAsync(lease, 0, ValidBody, CancellationToken.None);
                var command = await fixture.Session.PrepareMutationFromDraftAsync(NewId(), draft.DraftId, draft.Revision, owner, CancellationToken.None);
                fixture.Business = async (request, ct) =>
                {
                    var checkpoint = state.Store.LoadJournal(owner, command.RequestId);
                    Equal(MutationJournalState.Sending, checkpoint.State, "durable Sending exists before business handler enters");
                    Equal(ValidBody, checkpoint.BodyJson, "original body durably frozen before dispatch");
                    Equal(ValidBody, await request.Content.ReadAsStringAsync(), "the persisted body is the wire body");
                    return Json(UnitReply);
                };
                var result = await fixture.Session.MutateAsync(command, CancellationToken.None);
                Equal(MutationOutcome.Confirmed, result.Outcome, "known business response");
                True(result.IsDurablyRecorded && result.PersistenceError == null, "known outcome durably finalized");
                var record = await fixture.Session.LoadMutationJournalAsync(command.RequestId, owner, CancellationToken.None);
                Equal(MutationJournalState.Confirmed, record.State, "terminal state retained");
                Equal(draft.DraftId, record.OriginDraftId, "journal links exact draft");
                Equal((long?)draft.Revision, record.OriginDraftRevision, "local CAS revision recorded separately");
                Equal(UnitId, record.ConfirmedResourceId, "actual response identity retained, never same-name lookup");
                True(!record.ServerIdempotencyAvailable && !record.EnforcesExpectedVersion, "journal does not invent backend guarantees");
                var plain = Unprotect(Directory.GetFiles(state.RootDirectory, "mutations.dpapi", SearchOption.AllDirectories).Single(), "mutations");
                foreach (var secret in new[] { "password", "accessToken", "refreshToken", "stepUpToken", "access-original", "refresh-fixture" })
                    True(!plain.Contains(secret), "journal excludes auth data " + secret);
                Equal(1, fixture.Writes, "one business dispatch");
            }
        }

        private static async Task FailedCheckpointNeverSends()
        {
            foreach (var phase in new[] { "mutations:before-flush", "mutations:before-replace" })
            {
                var fail = false;
                using (var state = new BusinessStateTestFixture(point => { if (fail && point == phase) throw new IOException("fixture checkpoint failure"); }))
                using (var fixture = new Fixture(state.Store))
                {
                    await fixture.Login(); var owner = fixture.Owner(); var lease = fixture.Lease(owner);
                    var draft = await fixture.Session.SaveDraftAsync(lease, 0, ValidBody, CancellationToken.None);
                    var file = Directory.GetFiles(state.RootDirectory, "drafts.dpapi", SearchOption.AllDirectories).Single(); var before = File.ReadAllBytes(file);
                    var command = await fixture.Session.PrepareMutationFromDraftAsync(NewId(), draft.DraftId, 1, owner, CancellationToken.None);
                    fail = true;
                    var result = await fixture.Session.MutateAsync(command, CancellationToken.None);
                    Equal(MutationOutcome.NotSent, result.Outcome, "failed durable gate never sends " + phase);
                    True(result.PersistenceError != null && !result.IsDurablyRecorded, "failed gate is explicit");
                    Equal(0, fixture.Writes, "zero business handler calls after checkpoint fault");
                    True(before.SequenceEqual(File.ReadAllBytes(file)), "checkpoint failure cannot damage original draft");
                    True(!Directory.GetFiles(state.RootDirectory, "*.tmp", SearchOption.AllDirectories).Any(), "failed gate cleans only its owned temporary output");
                }
            }
        }

        private static async Task KnownOutcomeSurvivesCompletionStorageFailure()
        {
            foreach (var mode in new[] { "confirmed", "rejected", "unknown" })
            {
                var writes = 0;
                using (var state = new BusinessStateTestFixture(point =>
                    { if (point == "mutations:before-replace" && Interlocked.Increment(ref writes) == 2) throw new IOException("fixture terminal persistence failure"); }))
                using (var fixture = new Fixture(state.Store))
                {
                    await fixture.Login(); var owner = fixture.Owner(); var lease = fixture.Lease(owner);
                    await fixture.Session.SaveDraftAsync(lease, 0, ValidBody, CancellationToken.None);
                    var command = await fixture.Session.PrepareMutationFromDraftAsync(NewId(), lease.DraftId, 1, owner, CancellationToken.None);
                    fixture.Business = (request, ct) =>
                    {
                        if (mode == "unknown") throw new HttpRequestException("fixture sent response lost");
                        return Ready(mode == "rejected" ? Error(422, "VALIDATION_FAILED") : Json(UnitReply));
                    };
                    var result = await fixture.Session.MutateAsync(command, CancellationToken.None);
                    Equal(mode == "confirmed" ? MutationOutcome.Confirmed : mode == "rejected" ? MutationOutcome.Rejected : MutationOutcome.Unknown,
                        result.Outcome, "local failure never rewrites known network outcome " + mode);
                    True(!result.IsDurablyRecorded && result.PersistenceError?.Code == "LOCAL_BUSINESS_STORAGE", "terminal persistence failure is separate from business result");
                    if (mode == "confirmed") Equal(UnitReply, result.ResponseJson, "confirmed server response retained despite local error");
                    var recovered = await fixture.Session.LoadMutationJournalAsync(command.RequestId, owner, CancellationToken.None);
                    Equal(MutationJournalState.Unknown, recovered.State, "unfinalized durable Sending conservatively recovers Unknown");
                    Equal(ValidBody, recovered.BodyJson, "original frozen payload never replaced after failed finalization");
                    await ExpectCode("MUTATION_ALREADY_ATTEMPTED", () => fixture.Session.MutateAsync(command, CancellationToken.None));
                    Equal(1, fixture.Writes, "failed local completion never retries business write");
                }
            }
        }

        private static async Task CrashedSendingRecoversUnknownAndCannotResend()
        {
            using (var state = new BusinessStateTestFixture())
            {
                string draftId, requestId;
                using (var crashed = new Fixture(new DpapiBusinessStateStore(state.RootDirectory)))
                {
                    await crashed.Login(); var owner = crashed.Owner(); var lease = crashed.Lease(owner); draftId = lease.DraftId;
                    await crashed.Session.SaveDraftAsync(lease, 0, ValidBody, CancellationToken.None);
                    var command = await crashed.Session.PrepareMutationFromDraftAsync(NewId(), draftId, 1, owner, CancellationToken.None); requestId = command.RequestId;
                    crashed.Store.BeginSending(command); // Simulate process death after checkpoint, before known completion.
                }
                using (var restarted = new Fixture(new DpapiBusinessStateStore(state.RootDirectory)))
                {
                    await restarted.Login(); var owner = restarted.Owner();
                    var record = await restarted.Session.LoadMutationJournalAsync(requestId, owner, CancellationToken.None);
                    Equal(MutationJournalState.Unknown, record.State, "restart converts abandoned Sending to Unknown");
                    Equal(ValidBody, record.BodyJson, "restart preserves original raw JSON");
                    var newId = await restarted.Session.PrepareMutationFromDraftAsync(NewId(), draftId, 1, owner, CancellationToken.None);
                    var blocked = await restarted.Session.MutateAsync(newId, CancellationToken.None);
                    Equal(MutationOutcome.NotSent, blocked.Outcome, "new UUID cannot replay unresolved original draft");
                    Equal("DRAFT_PENDING_SUBMISSION", blocked.Error.Code, "bottom-layer unresolved draft gate");
                    var oldId = await restarted.Session.PrepareMutationFromDraftAsync(requestId, draftId, 1, owner, CancellationToken.None);
                    var oldBlocked = await restarted.Session.MutateAsync(oldId, CancellationToken.None);
                    Equal("MUTATION_ALREADY_RECORDED", oldBlocked.Error.Code, "original ID cannot replay across coordinator restart");
                    var lease = restarted.Session.CreateDraftLease(MutationAction.UnitCreate, draftId, owner);
                    await ExpectCode("DRAFT_PENDING_SUBMISSION", () => restarted.Session.SaveDraftAsync(lease, 1, "{\"name\":\"edited-later\"}", CancellationToken.None));
                    await ExpectCode("DRAFT_PENDING_SUBMISSION", () => restarted.Session.DeleteDraftAsync(draftId, 1, owner, CancellationToken.None));
                    Equal(ValidBody, (await restarted.Session.LoadDraftAsync(draftId, owner, CancellationToken.None)).BodyJson, "unresolved draft cannot be overwritten");
                    Equal(0, restarted.Writes, "no replay after recovery");
                }
            }
        }

        private static async Task LiveAttemptsAndConfirmedDraftRevisionCannotReplay()
        {
            using (var state = new BusinessStateTestFixture())
            using (var first = new Fixture(new DpapiBusinessStateStore(state.RootDirectory)))
            using (var second = new Fixture(new DpapiBusinessStateStore(state.RootDirectory)))
            {
                await first.Login(); await second.Login(); var owner1 = first.Owner(); var owner2 = second.Owner(); var lease = first.Lease(owner1);
                await first.Session.SaveDraftAsync(lease, 0, ValidBody, CancellationToken.None);
                var command = await first.Session.PrepareMutationFromDraftAsync(NewId(), lease.DraftId, 1, owner1, CancellationToken.None);
                first.Store.BeginSending(command);
                Equal(MutationJournalState.Sending, second.Store.LoadJournal(owner2, command.RequestId).State, "held cross-store attempt lease remains live Sending");
                var duplicate = await second.Session.PrepareMutationFromDraftAsync(NewId(), lease.DraftId, 1, owner2, CancellationToken.None);
                var result = await second.Session.MutateAsync(duplicate, CancellationToken.None);
                Equal("DRAFT_PENDING_SUBMISSION", result.Error.Code, "second store cannot dispatch active draft under new UUID");
                first.Store.Complete(new MutationResult(MutationOutcome.Confirmed, command, null, UnitReply));
                var confirmedAgain = await second.Session.PrepareMutationFromDraftAsync(NewId(), lease.DraftId, 1, owner2, CancellationToken.None);
                Equal("DRAFT_ALREADY_CONFIRMED", (await second.Session.MutateAsync(confirmedAgain, CancellationToken.None)).Error.Code, "confirmed draft revision cannot repeat after cleanup failure");
                var lease2 = second.Session.CreateDraftLease(MutationAction.UnitCreate, lease.DraftId, owner2);
                Equal(1L, (await second.Session.SaveDraftAsync(lease2, 1, ValidBody, CancellationToken.None)).Revision, "unchanged autosave cannot bypass confirmed revision");
                Equal(0, second.Writes, "cross-store duplicate checks never reach network");
                var revised = await second.Session.SaveDraftAsync(lease2, 1, "{\"name\":\"new-explicit-unit\"}", CancellationToken.None);
                Equal(2L, revised.Revision, "different explicit edit is a distinct local draft revision");
                Equal(ValidBody, second.Store.LoadJournal(owner2, command.RequestId).BodyJson, "new intent never changes confirmed original journal");
            }
        }

        private static async Task AtomicDraftFailurePreservesOriginal()
        {
            foreach (var phase in new[] { "drafts:before-flush", "drafts:before-replace" })
            {
                var fail = false;
                using (var state = new BusinessStateTestFixture(point => { if (fail && point == phase) throw new IOException("fixture draft atomic failure"); }))
                using (var fixture = new Fixture(state.Store))
                {
                    await fixture.Login(); var owner = fixture.Owner(); var lease = fixture.Lease(owner);
                    await fixture.Session.SaveDraftAsync(lease, 0, ValidBody, CancellationToken.None);
                    var file = Directory.GetFiles(state.RootDirectory, "drafts.dpapi", SearchOption.AllDirectories).Single(); var before = File.ReadAllBytes(file);
                    fail = true;
                    await ExpectCode("LOCAL_BUSINESS_STORAGE", () => fixture.Session.SaveDraftAsync(lease, 1, "{\"name\":\"not-durable\"}", CancellationToken.None));
                    True(before.SequenceEqual(File.ReadAllBytes(file)), "atomic draft failure preserves original encrypted bytes " + phase);
                    Equal(1L, (await fixture.Session.LoadDraftAsync(lease.DraftId, owner, CancellationToken.None)).Revision, "failed save never advances local CAS");
                    True(!Directory.GetFiles(state.RootDirectory, "*.tmp", SearchOption.AllDirectories).Any(), "failed draft save cleans only owned temp");
                }
            }
        }

        private static async Task DefiniteNoSendOrRejectionAllowsExplicitNewIntent()
        {
            foreach (var outcome in new[] { MutationOutcome.NotSent, MutationOutcome.Rejected })
            using (var state = new BusinessStateTestFixture())
            using (var fixture = new Fixture(state.Store))
            {
                await fixture.Login(); var owner = fixture.Owner(); var lease = fixture.Lease(owner);
                await fixture.Session.SaveDraftAsync(lease, 0, ValidBody, CancellationToken.None);
                var old = await fixture.Session.PrepareMutationFromDraftAsync(NewId(), lease.DraftId, 1, owner, CancellationToken.None);
                fixture.Store.BeginSending(old);
                fixture.Store.Complete(new MutationResult(outcome, old, new ApiException("VALIDATION_FAILED", "fixture", 422)));
                var decided = await fixture.Session.PrepareMutationFromDraftAsync(NewId(), lease.DraftId, 1, owner, CancellationToken.None);
                Equal(MutationOutcome.Confirmed, (await fixture.Session.MutateAsync(decided, CancellationToken.None)).Outcome, "definite prior result allows a new explicit user intent " + outcome);
                Equal(1, fixture.Writes, "only the explicit new call dispatches, never automatic replay");
                Equal(outcome == MutationOutcome.NotSent ? MutationJournalState.NotSent : MutationJournalState.Rejected,
                    fixture.Store.LoadJournal(owner, old.RequestId).State, "new decision never rewrites original terminal record");
            }
        }

        private static async Task CorruptionFailsClosedAndPreservesBytes()
        {
            using (var state = new BusinessStateTestFixture())
            using (var fixture = new Fixture(state.Store))
            {
                await fixture.Login(); var owner = fixture.Owner(); var lease = fixture.Lease(owner);
                await fixture.Session.SaveDraftAsync(lease, 0, ValidBody, CancellationToken.None);
                var draftFile = Directory.GetFiles(state.RootDirectory, "drafts.dpapi", SearchOption.AllDirectories).Single();
                var original = File.ReadAllBytes(draftFile); var damaged = new byte[] { 0, 1, 2, 3, 4 };
                File.WriteAllBytes(draftFile, damaged);
                await ExpectCode("LOCAL_BUSINESS_STORAGE", () => fixture.Session.ListDraftsAsync(owner, CancellationToken.None));
                await ExpectCode("LOCAL_BUSINESS_STORAGE", () => fixture.Session.SaveDraftAsync(lease, 1, "{\"name\":\"must-not-overwrite\"}", CancellationToken.None));
                True(damaged.SequenceEqual(File.ReadAllBytes(draftFile)), "corruption is never silently initialized or overwritten");
                File.WriteAllBytes(draftFile, original); // Restore only this private fixture, not production recovery.
                var command = await fixture.Session.PrepareMutationFromDraftAsync(NewId(), lease.DraftId, 1, owner, CancellationToken.None);
                fixture.Store.BeginSending(command); fixture.Store.Complete(new MutationResult(MutationOutcome.Rejected, command, new ApiException("VALIDATION_FAILED", "fixture", 422)));
                var journalFile = Directory.GetFiles(state.RootDirectory, "mutations.dpapi", SearchOption.AllDirectories).Single();
                var validJournal = File.ReadAllBytes(journalFile);
                var unsafeContract = Unprotect(journalFile, "mutations").Replace("\"serverIdempotencyAvailable\":false", "\"serverIdempotencyAvailable\":true");
                Reprotect(journalFile, "mutations", unsafeContract);
                await ExpectCode("LOCAL_BUSINESS_STORAGE", () => fixture.Session.ListMutationJournalAsync(owner, CancellationToken.None));
                File.WriteAllBytes(journalFile, validJournal);
                File.WriteAllBytes(journalFile, damaged);
                var next = fixture.Command(); var blocked = await fixture.Session.MutateAsync(next, CancellationToken.None);
                Equal(MutationOutcome.NotSent, blocked.Outcome, "corrupt journal blocks new network write");
                Equal("LOCAL_BUSINESS_STORAGE", blocked.Error.Code, "corrupt state requires explicit repair");
                True(damaged.SequenceEqual(File.ReadAllBytes(journalFile)), "corrupt journal bytes preserved");
                Equal(0, fixture.Writes, "corrupt journal never reaches handler");
            }
        }

        private static async Task CheckpointOwnerRetirementDoesNotSend()
        {
            using (var reached = new ManualResetEventSlim())
            using (var release = new ManualResetEventSlim())
            {
                var pause = false;
                using (var state = new BusinessStateTestFixture(point =>
                { if (pause && point == "mutations:before-replace") { reached.Set(); if (!release.Wait(5000)) throw new IOException("fixture gate timeout"); } }))
                using (var fixture = new Fixture(state.Store))
                {
                    await fixture.Login(); var owner = fixture.Owner(); var command = fixture.Command();
                    pause = true; var pending = fixture.Session.MutateAsync(command, CancellationToken.None);
                    True(reached.Wait(5000), "durable gate entered before sender");
                    fixture.Session.SelectEndpoint("cloud"); pause = false; release.Set();
                    var result = await pending;
                    Equal(MutationOutcome.NotSent, result.Outcome, "retired owner after durable gate does not dispatch");
                    True(result.IsDurablyRecorded, "original namespace records known no-send cancellation");
                    Equal(0, fixture.Writes, "owner change while checkpointing never sends old body");
                    Equal(MutationJournalState.NotSent, state.Store.LoadJournal(owner, command.RequestId).State, "local cleanup uses original namespace only");
                }
            }
        }

        private static async Task ReviewNoteNeverClaimsReceipt()
        {
            using (var state = new BusinessStateTestFixture())
            using (var fixture = new Fixture(state.Store))
            {
                await fixture.Login(); var owner = fixture.Owner(); var command = fixture.Command();
                fixture.Business = (request, ct) => { throw new HttpRequestException("fixture uncertain"); };
                var result = await fixture.Session.MutateAsync(command, CancellationToken.None);
                Equal(MutationOutcome.Unknown, result.Outcome, "unknown original");
                var note = await fixture.Session.AppendMutationReviewNoteAsync(command.RequestId, "人工核对中；同名记录不能认领为原提交。", owner, CancellationToken.None);
                Equal(MutationJournalState.Unknown, note.State, "review note cannot invent confirmed outcome");
                True(note.ConfirmedResourceId == null && !note.ServerIdempotencyAvailable, "note supplies neither receipt nor row ownership");
                Equal(ValidBody, note.BodyJson, "review never rewrites original body");
                Equal(1, fixture.Writes, "review is strictly local");
            }
        }

        private static string SaveOutcome(IBusinessStateStore store, DraftWriteLease lease, long revision, string body)
        { try { store.SaveDraft(lease, revision, body); return "saved"; } catch (ApiException error) { return error.Code; } }
        private static string Unprotect(string file, string kind)
        {
            var hash = Path.GetFileName(Path.GetDirectoryName(file));
            var plain = ProtectedData.Unprotect(File.ReadAllBytes(file), Encoding.UTF8.GetBytes("Uten/UIMP-Win7-WPF/business-state/v1/" + kind + "/" + hash), DataProtectionScope.CurrentUser);
            try { return new UTF8Encoding(false, true).GetString(plain); } finally { Array.Clear(plain, 0, plain.Length); }
        }
        private static void Reprotect(string file, string kind, string content)
        {
            var hash = Path.GetFileName(Path.GetDirectoryName(file));
            var bytes = Encoding.UTF8.GetBytes(content);
            try { File.WriteAllBytes(file, ProtectedData.Protect(bytes, Encoding.UTF8.GetBytes("Uten/UIMP-Win7-WPF/business-state/v1/" + kind + "/" + hash), DataProtectionScope.CurrentUser)); }
            finally { Array.Clear(bytes, 0, bytes.Length); }
        }
        private static string NewId() { return Guid.NewGuid().ToString("D"); }
        private static HttpResponseMessage Json(string body, int status = 200) { return new HttpResponseMessage((HttpStatusCode)status) { Content = new StringContent(body, Encoding.UTF8, "application/json") }; }
        private static HttpResponseMessage Error(int status, string code) { return Json("{\"code\":\"" + code + "\",\"message\":\"fixture rejected\"}", status); }
        private static Task<HttpResponseMessage> Ready(HttpResponseMessage response) { return Task.FromResult(response); }
        private static void True(bool value, string message) { if (!value) throw new InvalidOperationException("Business state contract: " + message); }
        private static void Equal<T>(T expected, T actual, string message) { True(EqualityComparer<T>.Default.Equals(expected, actual), message); }
        private static async Task<ApiException> ThrowsApi(Func<Task> action)
        { try { await action(); } catch (ApiException error) { return error; } throw new InvalidOperationException("Expected API rejection."); }
        private static async Task ExpectCode(string code, Func<Task> action) { Equal(code, (await ThrowsApi(action)).Code, "expected API rejection"); }
        private static void ThrowsCode(string code, Action action)
        { try { action(); } catch (ApiException error) { Equal(code, error.Code, "expected local API rejection"); return; } throw new InvalidOperationException("Expected " + code); }

        private sealed class Fixture : IDisposable
        {
            internal readonly SessionCoordinator Session;
            internal readonly IBusinessStateStore Store;
            internal string UserId = "user-fixture";
            internal string DatasetId = "11111111-1111-1111-1111-111111111111";
            internal long ResetGeneration;
            internal string[] Permissions = { "unit:view", "unit:create", "unit:edit", "unit:status" };
            internal int Writes;
            internal Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> Business;
            internal Fixture(IBusinessStateStore store)
            {
                Store = store;
                var config = new ClientConfiguration(new[] { new ServerEndpoint("company", "private company fixture", "https://company.example.test/api"),
                    new ServerEndpoint("cloud", "private cloud fixture", "https://cloud.example.test/api") }, "company", 5);
                Session = new SessionCoordinator(config, new Handler((request, ct) =>
                {
                    True(request.RequestUri.Host.EndsWith(".example.test", StringComparison.Ordinal), "fake HTTPS handler only");
                    if (request.RequestUri.AbsolutePath == "/api/auth/login") return Ready(Json(Token()));
                    if (request.RequestUri.AbsolutePath == "/api/auth/logout") return Ready(Json("", 204));
                    if (request.Method != HttpMethod.Get) Interlocked.Increment(ref Writes);
                    return Business == null ? Ready(Json(UnitReply)) : Business(request, ct);
                }), new MemoryAuthStore(), store);
            }
            internal Task Login() { return Session.LoginAsync("UT0001", "fixture-password", CancellationToken.None); }
            internal MutationOwnerSnapshot Owner() { return Session.CaptureMutationOwner(); }
            internal DraftWriteLease Lease(MutationOwnerSnapshot owner) { return Session.CreateDraftLease(MutationAction.UnitCreate, NewId(), owner); }
            internal MutationRequest Command() { return Session.PrepareMutation(MutationAction.UnitCreate, NewId(), ValidBody, Owner()); }
            private string Token()
            { return "{\"accessToken\":\"access-original\",\"refreshToken\":\"refresh-fixture\",\"expiresIn\":900,\"user\":{\"id\":\"" + UserId
                + "\",\"loginAccount\":\"UT0001\",\"name\":\"fixture\",\"superAdmin\":false,\"mustChangePassword\":false,\"permissions\":" + JsonValue.Serialize(Permissions)
                + ",\"businessDatasetId\":\"" + DatasetId + "\",\"businessResetGeneration\":" + ResetGeneration + "}}"; }
            public void Dispose() { Session.Dispose(); }
        }
        private sealed class Handler : HttpMessageHandler
        {
            private readonly Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action;
            internal Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> action) { this.action = action; }
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) { return action(request, cancellationToken); }
        }
        private sealed class MemoryAuthStore : ISessionStore
        {
            private StoredSession active;
            private readonly List<StoredSession> pending = new List<StoredSession>();
            public StoredSession Load() { return active; } public void Save(StoredSession session) { active = session; } public void Clear() { active = null; }
            public void EndSession(StoredSession session) { EnqueueRevocation(session ?? active); active = null; }
            public void EnqueueRevocation(StoredSession session) { if (session != null && !pending.Any(value => value.Id == session.Id)) pending.Add(session); }
            public IList<StoredSession> PendingRevocations() { return pending.ToList(); } public void AcknowledgeRevocation(string id) { pending.RemoveAll(value => value.Id == id); }
        }
    }
}
