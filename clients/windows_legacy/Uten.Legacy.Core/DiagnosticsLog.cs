using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Reflection;

#if UTEN_UPDATER_DIAGNOSTICS
namespace Uten.Legacy.Updater.Diagnostics
#else
namespace Uten.Legacy.Core
#endif
{
    // Operational log v1. Never write exception messages, bodies, headers,
    // authentication values, business records or user-entered text.
    public sealed class DiagnosticsLog : IDisposable
    {
        public static DiagnosticsLog Current { get; private set; }
        public string DirectoryPath { get; private set; }
        private readonly string version;
        private readonly int processId = Process.GetCurrentProcess().Id;
        private readonly string architecture = Environment.Is64BitProcess ? "x64" : "x86";
        private readonly BlockingCollection<string> pending = new BlockingCollection<string>(256);
        private readonly ConcurrentQueue<string> recent = new ConcurrentQueue<string>();
        private readonly Task writer;
        private volatile bool disposed;
        private int dropped;
        private int part;
        private string file;
        private long bytes;
        private readonly string stem;
        private static readonly Regex Owned = new Regex(@"^(app|fatal)-[a-zA-Z0-9_.+\-]+\.log$", RegexOptions.CultureInvariant);

        public DiagnosticsLog(string directory, string version)
        {
            DirectoryPath = Path.GetFullPath(directory);
            this.version = version;
            stem = "app-" + Regex.Replace(version, @"[^a-zA-Z0-9_.+\-]", "_") + "-" + DateTime.UtcNow.Ticks + "-" + Process.GetCurrentProcess().Id;
            file = Path.Combine(DirectoryPath, stem + ".log");
            writer = Task.Factory.StartNew(Drain, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
            Write("app.start");
        }

        public static void Start(string version)
        {
            var debug = Assembly.GetEntryAssembly()?.GetCustomAttributes(typeof(DebuggableAttribute), false).OfType<DebuggableAttribute>().FirstOrDefault();
            string kind = debug != null && debug.IsJITOptimizerDisabled ? "Debug" : "Release";
            string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "com.uten.uten_imp", "client-logs", "wpf_legacy", Environment.Is64BitProcess ? "x64" : "x86", kind);
            Current = new DiagnosticsLog(root, version);
        }

        public static string SafePath(string path)
        {
            if (path == null) return "/:unknown";
            if (path.Length > 2048) return "/:oversize";
            Uri uri;
            if (Uri.TryCreate(path, UriKind.Absolute, out uri) && (uri.Scheme == "https" || uri.Scheme == "http")) path = uri.AbsolutePath;
            return "/" + String.Join("/", path.Split('?')[0].Split('/').Where(x => x.Length > 0)
                .Select(x => Regex.IsMatch(x, @"^[a-z][a-z_-]{0,31}$", RegexOptions.CultureInvariant) ? x : ":id"));
        }

        public static void Record(string name, string code = null, string method = null, string path = null, long? elapsed = null, int? status = null)
        { Current?.Write(name, code, method, path, elapsed, status); }

        public bool OpenDirectory()
        {
            try
            {
                if (!Directory.Exists(DirectoryPath)) return false;
                Process.Start(new ProcessStartInfo(DirectoryPath) { UseShellExecute = true });
                return true;
            }
            catch (System.ComponentModel.Win32Exception) { return false; }
            catch (IOException) { return false; }
        }

        public void Write(string name, string code = null, string method = null, string path = null, long? elapsed = null, int? status = null)
        {
            if (disposed) return;
            var record = new Dictionary<string, object> { {"schemaVersion",1}, {"atUtc",DateTime.UtcNow.ToString("o")},
                {"event",Regex.IsMatch(name ?? "", @"^[a-z0-9_.-]{1,80}$") ? name : "diagnostic.invalid_event"},
                {"runtime","wpf_legacy"}, {"version",version}, {"architecture",architecture}, {"processId",processId}, {"level","info"} };
            if (code != null && Regex.IsMatch(code, @"^[A-Za-z0-9_.\-]{1,128}$")) record["code"] = code;
            if (method != null && Regex.IsMatch(method, @"^[A-Z]{1,12}$")) record["method"] = method;
            if (path != null) record["path"] = SafePath(path);
            if (elapsed.HasValue) record["durationMs"] = elapsed.Value;
            if (status.HasValue) record["status"] = status.Value;
            string line = new JavaScriptSerializer().Serialize(record) + Environment.NewLine;
            recent.Enqueue(line);
            while (recent.Count > 256) { string ignored; recent.TryDequeue(out ignored); }
            try { if (!pending.TryAdd(line)) Interlocked.Increment(ref dropped); }
            catch (InvalidOperationException) { }
        }

        public void Fatal(string name, Exception error)
        {
            // Independent file: do not wait for a writer lock during termination.
            try
            {
                Directory.CreateDirectory(DirectoryPath);
                var record = new Dictionary<string, object> { {"schemaVersion",1}, {"atUtc",DateTime.UtcNow.ToString("o")},
                    {"event",name}, {"version",version}, {"runtime","wpf_legacy"}, {"architecture",architecture}, {"processId",processId}, {"level","error"},
                    {"exceptionType",error == null ? "unknown" : error.GetType().FullName},
                    {"stack", error == null ? "" : String.Join("\n", (new StackTrace(error, true).GetFrames() ?? new StackFrame[0]).Take(10)
                        .Select(frame => (frame.GetMethod()?.DeclaringType?.FullName ?? "unknown") + "." + frame.GetMethod()?.Name
                            + " " + Path.GetFileName(frame.GetFileName()) + ":" + frame.GetFileLineNumber()))} };
                File.WriteAllText(Path.Combine(DirectoryPath, "fatal-" + DateTime.UtcNow.Ticks + ".log"),
                    new JavaScriptSerializer().Serialize(record) + Environment.NewLine, new UTF8Encoding(false));
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        private void Expire()
        {
            foreach (var old in new DirectoryInfo(DirectoryPath).EnumerateFiles("*.log")
                .Where(x => Owned.IsMatch(x.Name) && (x.Attributes & FileAttributes.ReparsePoint) == 0)
                .OrderByDescending(x => x.LastWriteTimeUtc).Skip(16))
            {
                if (String.Equals(old.FullName, file, StringComparison.OrdinalIgnoreCase)) continue;
                try { old.Delete(); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
        }

        private void Drain()
        {
            try
            {
                Directory.CreateDirectory(DirectoryPath);
                Expire();
                foreach (string line in pending.GetConsumingEnumerable())
                {
                    byte[] data = Encoding.UTF8.GetBytes(line);
                    if (bytes + data.Length > 2 * 1024 * 1024)
                    { file = Path.Combine(DirectoryPath, stem + "-part" + (++part) + ".log"); bytes = 0; }
                    using (var output = new FileStream(file, FileMode.Append, FileAccess.Write, FileShare.Read))
                    { output.Write(data, 0, data.Length); output.Flush(); }
                    bytes += data.Length;
                    if (bytes == data.Length) Expire();
                    int lost = Interlocked.Exchange(ref dropped, 0);
                    if (lost > 0) Write("diagnostic.dropped", elapsed: lost);
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        public void Dispose()
        {
            if (disposed) return;
            Write("app.stop");
            disposed = true;
            pending.CompleteAdding();
            // A stuck disk must not hold the UI/exit thread indefinitely.
            try { writer.Wait(100); } catch (AggregateException) { }
        }
    }
}
