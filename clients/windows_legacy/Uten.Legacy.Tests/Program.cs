using System;
using System.Linq;
using System.Reflection;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Features.Goods;
using Uten.Legacy.Desktop.Features.Downloads;
using Uten.Legacy.Desktop.Features.Publish;
using Uten.Legacy.Desktop.Features.Units;
using Uten.Legacy.Desktop.Shared;
using Uten.Legacy.Desktop.Features.Columns;
using Uten.Legacy.Desktop.Updates;

namespace Uten.Legacy.Tests
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            try
            {
                if (args.Length == 1 && args[0] == "--ui-contracts-only")
                {
                    UiContractChecks.Run();
                    Console.WriteLine("PASS UI shell/draft/review fixtures");
                    int historyUi = UnitHistoryContractChecks.RunUi();
                    int printUi = NativePrintContractChecks.Run();
                    int drafts = DurableDraftDialogChecks.Run();
                    int exports = UnitExportUiChecks.Run();
                    Console.WriteLine("PASS UI history/print/draft/export fixtures");
                    int inline = UnitInlineWorkspaceChecks.Run();
                    Console.WriteLine("PASS UI inline fixtures");
                    int columnUi = ColumnUiContractChecks.Run();
                    Console.WriteLine("PASS native UI contracts only; history=" + historyUi + "; print=" + printUi + "; common drafts=" + drafts + "; exports=" + exports + "; inline=" + inline + "; column UI=" + columnUi
                        + "; process=" + (Environment.Is64BitProcess ? "x64" : "x86"));
                    return 0;
                }
                if (args.Length != 0) throw new ArgumentException("Unknown native test group.");
                var checks = typeof(SessionCoordinator).Assembly.GetTypes().Single(type => type.Name == "CoreContractChecks");
                checks.GetMethod("Run", BindingFlags.Public | BindingFlags.Static).Invoke(null, null);
                Console.WriteLine("PASS native Core contracts");
                int goods = GoodsReadContractChecks.Run();
                int downloads = DownloadsContractChecks.Run();
                int publish = PublishContractChecks.Run();
                int units = UnitContractChecks.Run();
                int history = UnitHistoryContractChecks.Run();
                int columns = ColumnModelContractChecks.Run() + ColumnServiceContractChecks.RunRead() + ColumnUiContractChecks.RunWrites();
                int updater = UpdaterContractChecks.Run();
                int outcomes = UpdateOutcomeContractChecks.Run();
                Console.WriteLine("PASS goods/downloads/publish/units/updater contracts");
                UiContractChecks.Run();
                int historyUiAssertions = UnitHistoryContractChecks.RunUi();
                int printAssertions = NativePrintContractChecks.Run();
                int draftAssertions = DurableDraftDialogChecks.Run();
                int exportAssertions = UnitExportUiChecks.Run();
                int inlineAssertions = UnitInlineWorkspaceChecks.Run();
                int columnUiAssertions = ColumnUiContractChecks.Run();
                Console.WriteLine("PASS native core contracts; goods assertions=" + goods + "; downloads assertions=" + downloads
                    + "; publish assertions=" + publish + "; units assertions=" + units
                    + "; history assertions=" + history + "; history UI=" + historyUiAssertions + "; print assertions=" + printAssertions
                    + "; columns=" + columns + "; column UI=" + columnUiAssertions + "; common drafts=" + draftAssertions + "; exports=" + exportAssertions + "; inline=" + inlineAssertions
                    + "; updater assertions=" + updater + "; update outcomes=" + outcomes + "; process=" + (Environment.Is64BitProcess ? "x64" : "x86"));
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
