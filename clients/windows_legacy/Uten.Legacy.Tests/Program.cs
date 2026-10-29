using System;
using System.Linq;
using System.Reflection;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Features.Goods;
using Uten.Legacy.Desktop.Features.Downloads;

namespace Uten.Legacy.Tests
{
    internal static class Program
    {
        [STAThread]
        private static int Main()
        {
            try
            {
                var checks = typeof(SessionCoordinator).Assembly.GetTypes().Single(type => type.Name == "CoreContractChecks");
                checks.GetMethod("Run", BindingFlags.Public | BindingFlags.Static).Invoke(null, null);
                int goods = GoodsReadContractChecks.Run();
                int downloads = DownloadsContractChecks.Run();
                int updater = UpdaterContractChecks.Run();
                UiContractChecks.Run();
                Console.WriteLine("PASS native core contracts; goods assertions=" + goods + "; downloads assertions=" + downloads + "; updater assertions=" + updater + "; process=" + (Environment.Is64BitProcess ? "x64" : "x86"));
                return 0;
            }
            catch (Exception error)
            {
                var inner = (error as TargetInvocationException)?.InnerException ?? error;
                // Test exception messages contain fixture names only, never live credentials.
                Console.Error.WriteLine("FAIL " + inner.GetType().Name + ": " + inner.Message);
                Console.Error.WriteLine(inner.StackTrace);
                return 1;
            }
        }
    }
}
