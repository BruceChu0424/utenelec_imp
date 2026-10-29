using System;
using System.Collections.Generic;

namespace Uten.Legacy.Core
{
    /// <summary>Local-only preservation capability issued while this editor was authorized.
    /// Retirement never changes its namespace. It cannot authorize network writes or reads.</summary>
    public sealed class DraftWriteLease
    {
        internal readonly object CoordinatorIdentity;
        public MutationOwnerSnapshot Owner { get; private set; }
        public MutationAction Action { get; private set; }
        public string DraftId { get; private set; }
        public string ResourceId { get; private set; }
        public string ObservedStatus { get; private set; }
        internal DraftWriteLease(object identity, MutationAction action, string id, MutationOwnerSnapshot owner,
            string resource, string observedStatus)
        { CoordinatorIdentity = identity; Action = action; DraftId = id; Owner = owner; ResourceId = resource; ObservedStatus = observedStatus; }
    }

    /// <summary>Revision is a LOCAL draft CAS counter, never a server row version. Restoration
    /// always requires new authorization and fresh business detail before an explicit submission.</summary>
    public sealed class BusinessDraft
    {
        public int ContractVersion { get { return MutationRequest.ContractVersionFor(Action); } }
        public string DraftId { get; private set; }
        public long Revision { get; private set; }
        public MutationAction Action { get; private set; }
        public string ResourceId { get; private set; }
        public string BodyJson { get; private set; }
        public string BodySha256 { get; private set; }
        public string ObservedStatus { get; private set; }
        public DateTime UpdatedAtUtc { get; private set; }
        public string IssuerApiBaseUrl { get; private set; }
        public string UserId { get; private set; }
        public string BusinessDatasetId { get; private set; }
        public long BusinessResetGeneration { get; private set; }
        public bool RequiresRevalidation { get { return true; } }
        public BusinessDraft(string draftId, long revision, MutationAction action, string resourceId, string bodyJson,
            string observedStatus, DateTime updatedAtUtc, MutationOwnerSnapshot owner)
        {
            DraftId = draftId; Revision = revision; Action = action; ResourceId = resourceId; BodyJson = bodyJson;
            BodySha256 = MutationRequest.Hash(new System.Text.UTF8Encoding(false, true).GetBytes(bodyJson));
            ObservedStatus = observedStatus; UpdatedAtUtc = updatedAtUtc; IssuerApiBaseUrl = owner.IssuerApiBaseUrl;
            UserId = owner.UserId; BusinessDatasetId = owner.BusinessDatasetId; BusinessResetGeneration = owner.BusinessResetGeneration;
        }
    }

    public enum MutationJournalState { Sending = 1, NotSent = 2, Confirmed = 3, Rejected = 4, Unknown = 5 }

    /// <summary>A durable original intent, never a replayable MutationRequest or server receipt.
    /// Review notes do not change Unknown into success and never identify a row by equal values.</summary>
    public sealed class MutationJournalRecord
    {
        public int ContractVersion { get; private set; }
        public string RequestId { get; private set; }
        public MutationAction Action { get; private set; }
        public string Method { get; private set; }
        public string RelativePath { get; private set; }
        public string ResourceId { get; private set; }
        public string BodyJson { get; private set; }
        public string BodySha256 { get; private set; }
        public MutationJournalState State { get; private set; }
        public string OriginDraftId { get; private set; }
        public long? OriginDraftRevision { get; private set; }
        public DateTime CreatedAtUtc { get; private set; }
        public DateTime UpdatedAtUtc { get; private set; }
        public int? StatusCode { get; private set; }
        public string ErrorCode { get; private set; }
        public string ConfirmedResourceId { get; private set; }
        public string ReviewNote { get; private set; }
        public string IssuerApiBaseUrl { get; private set; }
        public string UserId { get; private set; }
        public string BusinessDatasetId { get; private set; }
        public long BusinessResetGeneration { get; private set; }
        public bool ServerIdempotencyAvailable { get { return Action == MutationAction.UnitExportSubmit; } }
        public string ServerIdempotencyKey { get { return ServerIdempotencyAvailable ? ResourceId : null; } }
        public string ServerIdempotencyBodyField { get { return ServerIdempotencyAvailable ? "id" : null; } }
        public string ReceiptPath { get { return Action == MutationAction.UnitExportSubmit || Action == MutationAction.UnitExportCancel ? "report-export-jobs/" + ResourceId : null; } }
        public bool EnforcesExpectedVersion { get { return VersionStrategy == MutationVersionStrategy.OperationVersion || VersionStrategy == MutationVersionStrategy.PlatformRowVersion; } }
        public MutationVersionStrategy VersionStrategy { get; private set; }
        public string ExpectedVersionJson { get; private set; }
        public string ExpectedHead { get; private set; }
        public MutationResponseKind ResponseKind { get; private set; }
        public string ResultJson { get; private set; }
        public MutationBatchResult BatchResult { get; private set; }
        public MutationExportJob ExportJob { get; private set; }
        public bool ConfirmedByReceiptQuery { get; private set; }
        public System.Collections.ObjectModel.ReadOnlyCollection<string> BatchResourceIds { get; private set; }
        public MutationReceiptStrategy ReceiptStrategy { get { return Action == MutationAction.UnitExportSubmit ? MutationReceiptStrategy.ExportJobCreation
            : Action == MutationAction.UnitExportCancel ? MutationReceiptStrategy.ExportJobStateQuery : MutationReceiptStrategy.NoReceiptManualReconciliation; } }
        public bool MayNeedManualReconciliation { get { return State == MutationJournalState.Sending || State == MutationJournalState.Unknown; } }
        internal string ObservedStatus;
        public MutationJournalRecord(MutationRequest request, MutationJournalState state, DateTime createdAtUtc,
            DateTime updatedAtUtc, int? statusCode = null, string errorCode = null, string confirmedResourceId = null, string reviewNote = null, string resultJson = null,
            bool confirmedByReceiptQuery = false)
        {
            ContractVersion = request.ContractVersion; ResponseKind = request.ResponseKind; BatchResourceIds = request.BatchResourceIds;
            RequestId = request.RequestId; Action = request.Action; Method = request.Method; RelativePath = request.RelativePath;
            ResourceId = request.ResourceId; BodyJson = request.BodyJson; BodySha256 = request.BodySha256; State = state;
            OriginDraftId = request.OriginDraftId; OriginDraftRevision = request.OriginDraftRevision; VersionStrategy = request.VersionStrategy;
            ExpectedVersionJson = request.ExpectedVersionJson;
            ExpectedHead = request.ExpectedHead;
            ResultJson = resultJson;
            if (resultJson != null)
            {
                var assessment = MutationResponseContract.Assess(request, resultJson);
                BatchResult = assessment.Batch; ExportJob = assessment.ExportJob;
                if (confirmedByReceiptQuery) UnitExportMutationContract.RequireCreationProof(request, resultJson);
            }
            ConfirmedByReceiptQuery = confirmedByReceiptQuery;
            CreatedAtUtc = createdAtUtc; UpdatedAtUtc = updatedAtUtc; StatusCode = statusCode; ErrorCode = errorCode;
            ConfirmedResourceId = confirmedResourceId; ReviewNote = reviewNote; ObservedStatus = request.ObservedStatus;
            IssuerApiBaseUrl = request.Owner.IssuerApiBaseUrl; UserId = request.Owner.UserId;
            BusinessDatasetId = request.Owner.BusinessDatasetId; BusinessResetGeneration = request.Owner.BusinessResetGeneration;
        }
    }

    /// <summary>Production uses CurrentUser DPAPI. The injectable boundary is for private fake and
    /// storage-fault checks; callers must not provide a memory store to a production coordinator.</summary>
    public interface IBusinessStateStore : IDisposable
    {
        BusinessDraft SaveDraft(DraftWriteLease lease, long expectedRevision, string bodyJson);
        IReadOnlyList<BusinessDraft> ListDrafts(MutationOwnerSnapshot owner);
        BusinessDraft LoadDraft(MutationOwnerSnapshot owner, string draftId);
        void DeleteDraft(MutationOwnerSnapshot owner, string draftId, long expectedRevision);
        void BeginSending(MutationRequest request);
        void Complete(MutationResult result);
        IReadOnlyList<MutationJournalRecord> ListJournal(MutationOwnerSnapshot owner);
        MutationJournalRecord LoadJournal(MutationOwnerSnapshot owner, string requestId);
        MutationJournalRecord AppendReviewNote(MutationOwnerSnapshot owner, string requestId, string note);
    }

    /// <summary>Only a verified, server-owned unit export creation receipt can settle its
    /// matching Unknown. Ordinary unit/history writes never use this optional extension.</summary>
    public interface IUnitExportReceiptStore
    {
        void ConfirmUnitExportReceipt(MutationRequest original, string verifiedJobJson);
    }
}
