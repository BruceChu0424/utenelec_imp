using System;
using System.Net.Http;
using System.Threading;

namespace Uten.Legacy.Core
{
    /// <summary>Internal capability carried through the one TLS/HTTP stack. It permits only the
    /// prepared unit method/path/body; all validation completes before the first request byte.
    /// Fake handlers lack a wire signal and are conservatively considered sent after dispatch.</summary>
    internal sealed class MutationWirePermit
    {
        private const string PropertyName = "Uten.Legacy.Core.FrozenMutation";
        private readonly MutationRequest command;
        private readonly bool wireSignalRequired;
        private readonly Action validateOwner;
        private int dispatched;
        private int wireStarted;
        internal int MaximumRequestBytes { get { return command.MaximumBodyBytes; } }
        internal MutationWirePermit(MutationRequest command, bool wireSignalRequired, Action validateOwner)
        { this.command = command; this.wireSignalRequired = wireSignalRequired; this.validateOwner = validateOwner; }
        internal bool MayHaveBeenSubmitted { get { return Volatile.Read(ref wireStarted) != 0
            || (!wireSignalRequired && Volatile.Read(ref dispatched) != 0); } }
        internal void ValidateBeforeDispatch() { validateOwner(); }
        internal void MarkDispatch() { ValidateBeforeDispatch(); Volatile.Write(ref dispatched, 1); }
        internal void Attach(HttpRequestMessage request)
        {
            if (!Owns(request)) throw new HttpRequestException("提交请求离开了冻结的接口合同。");
            request.Properties.Add(PropertyName, this);
        }
        internal bool Owns(HttpRequestMessage request)
        {
            return request != null && request.Method.Method == command.Method && request.RequestUri != null
                && request.RequestUri.AbsoluteUri == command.Owner.IssuerApiBaseUrl.TrimEnd('/') + "/" + command.RelativePath;
        }
        internal void ValidateEncoded(HttpRequestMessage request, byte[] bytes)
        {
            if (!Owns(request) || MutationRequest.Hash(bytes) != command.BodySha256)
                throw new HttpRequestException("提交内容或目标不再符合冻结请求。");
            // These routes have no server request-id, version or step-up header contract.
            foreach (var name in new[] { "Idempotency-Key", "X-Request-ID", "If-Match", StepUpGrant.HeaderName })
                if (request.Headers.Contains(name)) throw new HttpRequestException("单位提交包含未审核的请求头。");
        }
        internal static MutationWirePermit From(HttpRequestMessage request)
        {
            object value;
            return request != null && request.Properties.TryGetValue(PropertyName, out value) ? value as MutationWirePermit : null;
        }
        internal static bool AllowsExtendedMethod(HttpRequestMessage request)
        {
            var permit = From(request);
            return permit != null && permit.Owns(request) && (request.Method.Method == "PUT" || request.Method.Method == "PATCH"
                || request.Method.Method == "DELETE" && permit.command.Action == MutationAction.UnitPlatformDefinitionDelete);
        }
        internal static void BeforeWireWrite(HttpRequestMessage request, byte[] bytes)
        {
            var permit = From(request);
            if (permit == null) return;
            permit.ValidateEncoded(request, bytes);
            permit.ValidateBeforeDispatch();
            // Mark BEFORE the first Write: a partial write which throws is still uncertain.
            Volatile.Write(ref permit.wireStarted, 1);
        }
    }
}
