using System;
using System.IO;

namespace Uten.Legacy.Core.Tests
{
    /// <summary>Debug-only private CurrentUser DPAPI fixture. Never touches the real profile store.</summary>
    public sealed class BusinessStateTestFixture : IDisposable
    {
        private readonly string parent;
        private readonly string id;
        public string RootDirectory { get; private set; }
        public IBusinessStateStore Store { get; private set; }
        public BusinessStateTestFixture() : this(null) { }
        internal BusinessStateTestFixture(Action<string> writeFault)
        {
            parent = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "Uten-Wpf-Private-BusinessState-Checks"));
            id = Guid.NewGuid().ToString("D");
            RootDirectory = Path.GetFullPath(Path.Combine(parent, id));
            Directory.CreateDirectory(parent); RejectLinks(parent);
            Directory.CreateDirectory(RootDirectory); RejectLinks(RootDirectory);
            Store = new DpapiBusinessStateStore(RootDirectory, writeFault);
        }
        public void Dispose()
        {
            Store.Dispose();
            // Verify the exact generated absolute target before any recursive cleanup.
            if (Path.GetDirectoryName(RootDirectory) != parent || Path.GetFileName(RootDirectory) != id)
                throw new IOException("Private fixture cleanup target is invalid.");
            if (!Directory.Exists(RootDirectory)) return;
            RejectTreeLinks(RootDirectory);
            Directory.Delete(RootDirectory, true);
        }
        private static void RejectLinks(string path)
        { if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("Private fixture cannot follow links."); }
        private static void RejectTreeLinks(string path)
        {
            RejectLinks(path);
            foreach (var child in Directory.EnumerateFileSystemEntries(path))
            { RejectLinks(child); if (Directory.Exists(child)) RejectTreeLinks(child); }
        }
    }
}
