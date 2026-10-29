using System;
using System.Runtime.CompilerServices;

[assembly: InternalsVisibleTo("Uten.Legacy.Tests")]

namespace Uten.Legacy.Updater
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length != 1) return 2;
            try { return new UpdateExecutor(args[0]).Execute().Succeeded ? 0 : 1; }
            catch (Exception) { return 2; } // Never execute arbitrary commands or leak package/configuration contents.
        }
    }
}
