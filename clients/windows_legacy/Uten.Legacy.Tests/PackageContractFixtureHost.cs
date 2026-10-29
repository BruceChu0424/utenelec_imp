// Explicit offline Csc harness only; intentionally not a Compile item in the main test project.
// It never calls product Main, updater Execute or a package executable.
using System;
using Uten.Legacy.Tests;

internal static class PackageContractFixtureHost
{
    private static int Main(string[] arguments)
    {
        try
        {
            if (arguments.Length != 2) throw new ArgumentException("Expected emit/verify and the exact temporary root.");
            string architecture = Environment.Is64BitProcess ? "x64" : "x86";
            if (arguments[0] == "emit")
            {
                UpdaterContractChecks.EmitProducerInputs(arguments[1]);
                Console.WriteLine("{\"architecture\":\"" + architecture + "\",\"fixtureOnly\":true}");
            }
            else if (arguments[0] == "emit-execute")
            {
                UpdaterContractChecks.EmitExecuteInputs(arguments[1]);
                Console.WriteLine("{\"architecture\":\"" + architecture + "\",\"fixtureOnly\":true}");
            }
            else if (arguments[0] == "verify")
            {
                int count = UpdaterContractChecks.RunProducerPackageChecks(arguments[1]);
                Console.WriteLine("{\"architecture\":\"" + architecture + "\",\"assertions\":" + count + "}");
            }
            else if (arguments[0] == "contracts")
            {
                int count = UpdaterContractChecks.Run();
                Console.WriteLine("{\"architecture\":\"" + architecture + "\",\"assertions\":" + count + ",\"fixtureOnly\":true}");
            }
            else throw new ArgumentException("Unknown fixture-only operation.");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error.GetType().Name + ": " + error.Message);
            return 1;
        }
    }
}
