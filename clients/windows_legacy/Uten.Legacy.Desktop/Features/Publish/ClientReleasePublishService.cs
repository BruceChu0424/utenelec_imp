using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Controls;

namespace Uten.Legacy.Desktop.Features.Publish
{
    /// <summary>Real publish gateway over the one Core transport. Step-up is transparent to the
    /// queue: a 403 REAUTH_REQUIRED obtains a fresh grant through the shared password dialog and
    /// retries the exact same frozen request once; cancelling surfaces the original rejection.</summary>
    public sealed class ClientReleasePublishService : IClientReleaseGateway
    {
        private readonly SessionCoordinator session;
        private readonly Func<string> requestStepUp;
        private MutationOwnerSnapshot owner;

        public ClientReleasePublishService(SessionCoordinator session, Window stepUpOwner)
        {
            if (session == null) throw new ArgumentNullException("session");
            this.session = session;
            requestStepUp = delegate
            {
                var token = StepUpPasswordDialog.Request(stepUpOwner, "发布客户端", session);
                return token;
            };
        }

        /// <summary>Freezes the publish identity for the whole queue session. Call again on a
        /// queue retry page reload; identity changes are reported by the coordinator itself.</summary>
        public void Begin()
        {
            session.DemandClientReleasePublishAccess();
            owner = session.CaptureMutationOwner();
        }

        public Task<string> ReadAsync(string relativePath)
        {
            RequireOwner();
            return session.ReadClientReleaseAsync(relativePath, owner, CancellationToken.None);
        }

        public Task<string> SendAsync(string relativePath, string bodyJson, bool requireStepUp)
        {
            RequireOwner();
            if (!requireStepUp) return session.SendClientReleaseCommandAsync(relativePath, bodyJson, owner, null, CancellationToken.None);
            return SendWithStepUpAsync(relativePath, bodyJson);
        }

        private async Task<string> SendWithStepUpAsync(string relativePath, string bodyJson)
        {
            var existing = session.CurrentStepUpGrant;
            var token = existing == null ? null : existing.StepUpToken;
            ApiException rejection = null;
            for (var attempt = 0; attempt < 2; attempt++)
            {
                try
                {
                    return await session.SendClientReleaseCommandAsync(relativePath, bodyJson, owner, token, CancellationToken.None)
                        .ConfigureAwait(true);
                }
                catch (ApiException error)
                {
                    // Only the server's own re-auth demand triggers the password dialog; other
                    // 403/4xx rejections are definite failures for the queue to classify.
                    if (error.HasResponseCode && error.StatusCode == 403 && error.Code == "REAUTH_REQUIRED")
                    {
                        rejection = error;
                        token = requestStepUp();
                        if (token == null) throw;
                        continue;
                    }
                    throw;
                }
            }
            throw rejection ?? new ApiException("REAUTH_REQUIRED", "这一步需要先重新输入登录密码确认。", 403, false, true);
        }

        public Task<string> UploadAsync(string releaseId, string sourcePath, long expectedBytes,
            string expectedSha256, IProgress<long> progress)
        {
            RequireOwner();
            return session.UploadClientPackageAsync(releaseId, sourcePath, expectedBytes, expectedSha256,
                owner, CancellationToken.None, progress);
        }

        private void RequireOwner()
        {
            if (owner == null) throw new ApiException("PUBLISH_IDENTITY_NOT_BOUND", "尚未绑定本次发布身份。");
        }
    }
}
