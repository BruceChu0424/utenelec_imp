using System;
using System.Runtime.CompilerServices;
using System.Diagnostics;
using System.Reflection;
using Uten.Legacy.Updater.Diagnostics;

[assembly: InternalsVisibleTo("Uten.Legacy.Tests")]

namespace Uten.Legacy.Updater
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length != 1) return 2;
            DiagnosticsLog.Start(FileVersionInfo.GetVersionInfo(Assembly.GetExecutingAssembly().Location).ProductVersion);
            try
            {
                DiagnosticsLog.Record("update.start");
                bool succeeded = new UpdateExecutor(args[0]).Execute().Succeeded;
                DiagnosticsLog.Record("update.end", succeeded ? "success" : "failed");
                return succeeded ? 0 : 1;
            }
            catch (Exception error) { DiagnosticsLog.Current?.Fatal("update.exception", error); return 2; }
            finally { DiagnosticsLog.Current?.Dispose(); }
        }
    }
}
