using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Uten.Legacy.Core;

namespace Uten.Legacy.Desktop.Features.Downloads
{
    public static class SoftwareDownloadsContract
    {
        public static string CatalogPath(string architecture)
        {
            if (architecture != "x86" && architecture != "x64") throw new ArgumentException("请选择 32 位或 64 位架构。", nameof(architecture));
            return "/client-updates/downloads?platform=windows&architecture=" + architecture + "&allRuntimeFamilies=true";
        }
        public static IReadOnlyList<ClientPackageDescriptor> ParseCatalog(string json)
        {
            var serializer = new JavaScriptSerializer { MaxJsonLength = 1048576, RecursionLimit = 32 };
            var values = serializer.DeserializeObject(json) as object[];
            if (values == null || values.Length > 64) throw new FormatException("软件下载目录格式无效。");
            var packages = new List<ClientPackageDescriptor>();
            foreach (object value in values)
            {
                try
                {
                    var package = ClientPackageDescriptor.Parse(value as Dictionary<string, object>);
                    if (package.PackageKind == "installer") packages.Add(package);
                }
                catch (FormatException) { /* Invalid, unknown and unpublished entries are never offered. */ }
            }
            return new ReadOnlyCollection<ClientPackageDescriptor>(packages);
        }
        public static ClientPackageDescriptor SelectInstaller(IEnumerable<ClientPackageDescriptor> packages, string family, string architecture)
        {
            return packages.Where(package => package.IsInstallerFor(family, architecture))
                .OrderByDescending(package => package.BuildNumber).FirstOrDefault();
        }
    }

    public sealed class SoftwareDownloadsService
    {
        private readonly SessionCoordinator session;
        public SoftwareDownloadsService(SessionCoordinator session)
        {
            this.session = session ?? throw new ArgumentNullException(nameof(session));
        }
        private void DemandDownloadAccess()
        {
            var user = session.CurrentUser;
            if (!session.IsAuthenticated || user == null || user.MustChangePassword || (!user.SuperAdmin && String.IsNullOrEmpty(user.EmployeeId)))
                throw new UnauthorizedAccessException("请使用具有软件下载资格的本人账号登录。");
        }
        public async Task<IReadOnlyList<ClientPackageDescriptor>> LoadAsync(string architecture, CancellationToken cancellationToken)
        {
            DemandDownloadAccess();
            string json = await session.GetAsync(SoftwareDownloadsContract.CatalogPath(architecture), cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            return await Task.Run(() => SoftwareDownloadsContract.ParseCatalog(json), cancellationToken).ConfigureAwait(false);
        }
        public Task<string> DownloadAsync(ClientPackageDescriptor package, string family, string architecture,
            string outputPath, CancellationToken cancellationToken, IProgress<long> progress)
        {
            DemandDownloadAccess();
            if (package == null || !package.IsInstallerFor(family, architecture))
                throw new InvalidOperationException("请重新选择对应系统与架构的已发布安装包。");
            // The transport constructs the approved API path from identity and family.
            // A manifest's downloadUrl is never launched or trusted as a transport target.
            return session.DownloadClientPackageAsync(package.Id, package.Sha256, package.SizeBytes,
                package.RuntimeFamily, outputPath, cancellationToken, progress);
        }
    }
}
