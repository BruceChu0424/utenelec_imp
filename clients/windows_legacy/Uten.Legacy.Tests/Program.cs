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
                if (args.Length == 1 && args[0] == "--goods-currency-contracts")
                {
                    int currencyGoods = GoodsReadContractChecks.Run();
                    RunUi(UiContractChecks.RunGoodsCurrency);
                    Console.WriteLine("PASS goods currency model/shared fixture/native UI contracts; assertions=" + currencyGoods
                        + "; process=" + (Environment.Is64BitProcess ? "x64" : "x86"));
                    return 0;
                }
                if (args.Length == 1 && args[0] == "--permission-readonly-contracts")
                {
                    var readChecks = typeof(SessionCoordinator).Assembly.GetTypes().Single(type => type.Name == "ReadScopeRevisionChecks");
                    readChecks.GetMethod("Run", BindingFlags.Public | BindingFlags.Static).Invoke(null, null);
                    int drafts = DurableDraftDialogChecks.Run();
                    int inline = RunUi(UnitInlineWorkspaceChecks.Run);
                    Console.WriteLine("PASS permission readonly contracts; read scope transitions; durable drafts=" + drafts
                        + "; inline preservation=" + inline + "; process=" + (Environment.Is64BitProcess ? "x64" : "x86"));
                    return 0;
                }
                if (args.Length == 1 && args[0] == "--ui-contracts-only")
                {
                    RunUi(UiContractChecks.Run);
                    Console.WriteLine("PASS UI shell/draft/review fixtures");
                    int historyUi = RunUi(UnitHistoryContractChecks.RunUi);
                    int printUi = RunUi(NativePrintContractChecks.Run);
                    int drafts = RunUi(DurableDraftDialogChecks.Run);
                    int exports = RunUi(UnitExportUiChecks.Run);
                    Console.WriteLine("PASS UI history/print/draft/export fixtures");
                    int inline = RunUi(UnitInlineWorkspaceChecks.Run);
                    Console.WriteLine("PASS UI inline fixtures");
                    int columnUi = RunUi(ColumnUiContractChecks.Run);
                    Console.WriteLine("PASS native UI contracts only; history=" + historyUi + "; print=" + printUi + "; common drafts=" + drafts + "; exports=" + exports + "; inline=" + inline + "; column UI=" + columnUi
                        + "; process=" + (Environment.Is64BitProcess ? "x64" : "x86"));
                    return 0;
                }
                if (args.Length != 0) throw new ArgumentException("Unknown native test group.");
                DiagnosticsLogChecks.Run();
                var checks = typeof(SessionCoordinator).Assembly.GetTypes().Single(type => type.Name == "CoreContractChecks");
                checks.GetMethod("Run", BindingFlags.Public | BindingFlags.Static).Invoke(null, null);
                typeof(SessionCoordinator).Assembly.GetTypes().Single(type => type.Name == "PageReadPriorityChecks")
                    .GetMethod("Run", BindingFlags.Public | BindingFlags.Static).Invoke(null, null);
                Console.WriteLine("PASS native Core contracts");
                int goods = GoodsReadContractChecks.Run();
                int downloads = DownloadsContractChecks.Run();
                int publish = PublishContractChecks.Run();
                int units = UnitContractChecks.Run();
                int history = UnitHistoryContractChecks.Run();
                int columns = ColumnModelContractChecks.Run() + ColumnServiceContractChecks.RunRead() + RunUi(ColumnUiContractChecks.RunWrites);
                int updater = UpdaterContractChecks.Run();
                int outcomes = UpdateOutcomeContractChecks.Run();
                Console.WriteLine("PASS goods/downloads/publish/units/updater contracts");
                RunUi(UiContractChecks.Run);
                int historyUiAssertions = RunUi(UnitHistoryContractChecks.RunUi);
                int printAssertions = RunUi(NativePrintContractChecks.Run);
                int draftAssertions = RunUi(DurableDraftDialogChecks.Run);
                int exportAssertions = RunUi(UnitExportUiChecks.Run);
                int inlineAssertions = RunUi(UnitInlineWorkspaceChecks.Run);
                int columnUiAssertions = RunUi(ColumnUiContractChecks.Run);
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

        private static T RunUi<T>(Func<T> check)
        {
            // STA alone does not install the context supplied by a real WPF
            // application. Awaited preservation failures must return to the UI
            // dispatcher before showing their owned guard, in every test group.
            var previous = System.Threading.SynchronizationContext.Current;
            System.Threading.SynchronizationContext.SetSynchronizationContext(
                new System.Windows.Threading.DispatcherSynchronizationContext(System.Windows.Threading.Dispatcher.CurrentDispatcher));
            try { return check(); }
            finally { System.Threading.SynchronizationContext.SetSynchronizationContext(previous); }
        }

        private static void RunUi(Action check)
        {
            RunUi(() => { check(); return true; });
        }
    }
}
