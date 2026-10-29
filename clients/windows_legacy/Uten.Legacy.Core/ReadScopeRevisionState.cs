using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text.RegularExpressions;
using System.Threading;

namespace Uten.Legacy.Core
{
    internal sealed class ReadRequest
    {
        internal readonly long Revision;
        internal readonly long Sequence;
        internal readonly CancellationToken Cancellation;
        internal ReadRequest(long revision, long sequence, CancellationToken cancellation)
        { Revision = revision; Sequence = sequence; Cancellation = cancellation; }
    }

    internal sealed class ReadScopeHeaders
    {
        internal string Version;
        internal string Domain;
        internal bool Invalid;
        internal static ReadScopeHeaders Capture(HttpResponseMessage response)
        {
            var result = new ReadScopeHeaders();
            result.Version = Single(response, "X-Uten-Read-Scope-Version", result);
            result.Domain = Single(response, "X-Uten-Read-Scope-Domain", result);
            return result;
        }
        private static string Single(HttpResponseMessage response, string name, ReadScopeHeaders result)
        {
            IEnumerable<string> values;
            if (!response.Headers.TryGetValues(name, out values)) return null;
            var entries = values.Take(2).ToArray();
            if (entries.Length != 1) { result.Invalid = true; return null; }
            return entries[0];
        }
    }

    internal sealed class ReadScopeProof
    {
        internal ReadScopeHeaders Headers;
        internal object BodyVersion;
        internal bool MalformedObject;
        internal static ReadScopeProof Read(string originalBody, ReadScopeHeaders headers)
        {
            var result = new ReadScopeProof { Headers = headers ?? new ReadScopeHeaders() };
            // Observe just the root proof. Never serialize the object or replace the numeric body.
            if (String.IsNullOrWhiteSpace(originalBody) || !originalBody.TrimStart().StartsWith("{", StringComparison.Ordinal)) return result;
            try
            {
                var root = JsonValue.ParseObject(originalBody);
                object version;
                if (root.TryGetValue("readScopeVersion", out version)) result.BodyVersion = version;
            }
            catch (Exception error) when (error is FormatException || error is ArgumentException || error is InvalidOperationException)
            { result.MalformedObject = true; }
            return result;
        }
    }

    internal enum ReadProofDisposition { Accepted, Rejected, Retired }

    /// <summary>
    /// Mirrors ReadScopeRevisionInterceptor: proofs are opaque, scoped to an auth identity,
    /// domain and request sequence. Call only under SessionCoordinator's gate.
    /// </summary>
    internal sealed class ReadScopeRevisionState
    {
        private readonly Dictionary<string, Observation> versions = new Dictionary<string, Observation>(StringComparer.Ordinal);
        private static readonly Regex NativeDomain = new Regex(
            "^native_(sales_owner|purchase_owner|subcontract_owner|production_owner|fqc_records|workshop_tasks|warehouse_tasks|feature):(task|browse)$",
            RegexOptions.CultureInvariant);
        private static readonly Regex ReportPath = new Regex("^/(?:api/)?(sales|purchase|subcontract|production|stock|finance)/reports(?:/|$)", RegexOptions.CultureInvariant);
        private static readonly Regex MasterPath = new Regex("^/(?:api/)?master/(clients|suppliers|goods|accounts|currencies|colors|units|moulds|warehouses)(?:/|$)", RegexOptions.CultureInvariant);
        private static readonly Regex SettlementPath = new Regex("^/(?:api/)?master/reference-methods/settlement-admin(?:/page)?$", RegexOptions.CultureInvariant);
        private static readonly Dictionary<string, string> MasterDomains = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            { "clients", "client" }, { "suppliers", "supplier" }, { "goods", "master_goods" },
            { "accounts", "master_account" }, { "currencies", "master_currency" }, { "colors", "master_color" },
            { "units", "master_unit" }, { "moulds", "master_mould" }, { "warehouses", "master_warehouse" }
        };
        internal long Revision { get; private set; }
        internal void ResetIdentity() { versions.Clear(); }
        internal void Retire() { Revision++; }

        internal ReadProofDisposition Observe(ReadRequest request, string path, ReadScopeProof proof)
        {
            if (request.Revision != Revision) return ReadProofDisposition.Rejected;
            var header = proof.Headers;
            if (header.Invalid || (header.Version != null && !ValidVersion(header.Version))
                || (header.Domain != null && (header.Domain.Length > 128 || header.Domain.Any(Char.IsControl)))
                || (proof.BodyVersion != null && (!(proof.BodyVersion is string) || !ValidVersion((string)proof.BodyVersion)))
                || (header.Version != null && (proof.MalformedObject
                    || (proof.BodyVersion != null && !header.Version.Equals(proof.BodyVersion)))))
                return Retired();
            var native = header.Domain != null && NativeDomain.IsMatch(header.Domain) ? header.Domain : null;
            // An unrecognized native domain cannot establish a fallback master proof or
            // retire another valid reader. Reject it without mutating the current revision.
            if (header.Domain?.StartsWith("native_", StringComparison.Ordinal) == true && native == null)
                return ReadProofDisposition.Rejected;
            var version = header.Version ?? proof.BodyVersion as string;
            var domain = native ?? DomainFromPath(path);
            if (version == null || domain == null) return ReadProofDisposition.Accepted;
            Observation prior;
            versions.TryGetValue(domain, out prior);
            if (prior != null && request.Sequence < prior.Sequence)
                return version == prior.Version ? ReadProofDisposition.Accepted : ReadProofDisposition.Rejected;
            if (versions.Count >= 128 && prior == null)
            {
                versions.Clear();
                versions[domain] = new Observation(request.Sequence, version);
                return Retired();
            }
            versions[domain] = new Observation(request.Sequence, version);
            return prior != null && prior.Version != version ? Retired() : ReadProofDisposition.Accepted;
        }

        private ReadProofDisposition Retired() { Retire(); return ReadProofDisposition.Retired; }
        private static bool ValidVersion(string value)
        { return !String.IsNullOrEmpty(value) && value.Length <= 256 && !value.Any(Char.IsControl); }
        private static string DomainFromPath(string path)
        {
            if (SettlementPath.IsMatch(path)) return "master_settlement_method";
            var report = ReportPath.Match(path);
            if (report.Success) return report.Groups[1].Value;
            var master = MasterPath.Match(path);
            return master.Success ? MasterDomains[master.Groups[1].Value] : null;
        }
        private sealed class Observation
        {
            internal readonly long Sequence;
            internal readonly string Version;
            internal Observation(long sequence, string version) { Sequence = sequence; Version = version; }
        }
    }
}
