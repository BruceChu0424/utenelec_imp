using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace Uten.Legacy.Updater
{
    internal static class SafeFiles
    {
        private const uint Read = 0x80000000, Write = 0x40000000, OpenReparse = 0x00200000, BackupSemantics = 0x02000000;
        private const uint Reparse = 0x400, DirectoryAttribute = 0x10;

        internal static string Full(string path)
        {
            if (String.IsNullOrWhiteSpace(path) || !Path.IsPathRooted(path) || path.IndexOf('\0') >= 0
                || path.StartsWith("\\\\", StringComparison.Ordinal) || path.IndexOf(':', 2) >= 0)
                throw new InvalidDataException("Only ordinary absolute local paths are supported.");
            foreach (var part in path.Replace('/', '\\').Split('\\'))
                if (part == "." || part == ".." || part.EndsWith(" ", StringComparison.Ordinal) || part.EndsWith(".", StringComparison.Ordinal))
                    throw new InvalidDataException("Noncanonical update path.");
            return Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);
        }
        internal static bool Same(string left, string right) { return String.Equals(Full(left), Full(right), StringComparison.OrdinalIgnoreCase); }
        internal static string Child(string root, string relative)
        {
            if (String.IsNullOrEmpty(relative) || relative.IndexOfAny(new[] { '/', '\\', ':' }) >= 0 || relative == "." || relative == "..")
                throw new InvalidDataException("Expected one approved path leaf.");
            var value = Full(Path.Combine(root, relative));
            if (!value.StartsWith(Full(root) + "\\", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Path leaves the owned root.");
            return value;
        }
        internal static FileStream Open(string path, FileAccess access, bool create = false, bool lockFile = false)
        {
            path = Full(path);
            var handle = CreateFile(path, access == FileAccess.Read ? Read : Read | Write,
                access == FileAccess.Read ? 1u : 0u, IntPtr.Zero, create ? 1u : lockFile ? 4u : 3u,
                OpenReparse, IntPtr.Zero);
            if (handle.IsInvalid) { var error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new IOException("Cannot exclusively access an approved file.", new Win32Exception(error)); }
            try
            {
                NativeInformation information;
                if (!GetFileInformationByHandle(handle, out information)
                    || (information.Attributes & (Reparse | DirectoryAttribute)) != 0 || information.LinkCount != 1)
                    throw new IOException("Links, directories and multiply linked files are forbidden.");
                return new FileStream(handle, access, 65536, false);
            }
            catch { handle.Dispose(); throw; }
        }
        internal static void NewBytes(string path, byte[] bytes)
        { using (var file = Open(path, FileAccess.ReadWrite, true)) { file.Write(bytes, 0, bytes.Length); file.Flush(true); } }
        internal static void NewJson(string root, string name, object value)
        {
            var target = Child(root, name); var temporary = Child(root, ".status-" + Guid.NewGuid().ToString("N") + ".tmp");
            NewBytes(temporary, StrictJson.Write(value));
            // Both file leaves are checked children of the pinned private job. Never move a directory.
            if (File.Exists(target) || Directory.Exists(target)) throw new IOException("Status already exists; preserve existing evidence.");
            File.Move(temporary, target);
        }
        internal static byte[] Bytes(string path, int limit)
        {
            using (var file = Open(path, FileAccess.Read))
            {
                if (file.Length > limit) throw new InvalidDataException("Metadata exceeds its limit.");
                using (var output = new MemoryStream()) { Copy(file, output, limit); return output.ToArray(); }
            }
        }
        internal static string Hash(Stream stream)
        {
            stream.Position = 0;
            using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        }
        internal static string Hash(string path) { using (var file = Open(path, FileAccess.Read)) return Hash(file); }
        internal static long Copy(Stream input, Stream output, long maximum)
        {
            var buffer = new byte[65536]; long total = 0; int read;
            while ((read = input.Read(buffer, 0, buffer.Length)) != 0)
            {
                total += read;
                if (total > maximum) throw new InvalidDataException("File exceeds its declared or aggregate size limit.");
                output.Write(buffer, 0, read);
            }
            return total;
        }
        internal static IDisposable GuardDirectories(params string[] paths) { return new DirectoryGuards(paths); }

        private sealed class DirectoryGuards : IDisposable
        {
            private readonly List<SafeFileHandle> handles = new List<SafeFileHandle>();
            internal DirectoryGuards(IEnumerable<string> paths)
            {
                var opened = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                try
                {
                    foreach (var path in paths)
                    {
                        var parents = new Stack<string>(); var current = Full(path);
                        while (!String.IsNullOrEmpty(current)) { parents.Push(current); current = Path.GetDirectoryName(current); }
                        while (parents.Count != 0)
                        {
                            current = parents.Pop(); if (!opened.Add(current)) continue;
                            var handle = CreateFile(current, 0x80, 3, IntPtr.Zero, 3, OpenReparse | BackupSemantics, IntPtr.Zero);
                            if (handle.IsInvalid) { handle.Dispose(); throw new IOException("An owned directory cannot be pinned."); }
                            NativeInformation information;
                            if (!GetFileInformationByHandle(handle, out information) || (information.Attributes & Reparse) != 0
                                || (information.Attributes & DirectoryAttribute) == 0)
                            { handle.Dispose(); throw new IOException("Directory links and reparse points are forbidden."); }
                            handles.Add(handle);
                        }
                    }
                }
                catch { Dispose(); throw; }
            }
            public void Dispose() { for (var index = handles.Count - 1; index >= 0; index--) handles[index].Dispose(); handles.Clear(); }
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct NativeInformation
        {
            internal uint Attributes, CreatedLow, CreatedHigh, AccessedLow, AccessedHigh, WrittenLow, WrittenHigh;
            internal uint Volume, SizeHigh, SizeLow, LinkCount, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out NativeInformation information);
    }
}
