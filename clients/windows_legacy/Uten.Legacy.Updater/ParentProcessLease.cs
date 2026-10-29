using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Uten.Legacy.Updater
{
    /// <summary>One pinned minimal-rights Win7 process handle from identity verification through normal exit.</summary>
    internal sealed class ParentProcessLease : IDisposable
    {
        private readonly ParentHandle handle;
        private ParentProcessLease(ParentHandle handle) { this.handle = handle; }
        internal static ParentProcessLease Open(UpdatePlan plan)
        {
            var held = OpenProcess(0x00100000 | 0x00001000, false, plan.ParentPid); // SYNCHRONIZE | QUERY_LIMITED_INFORMATION
            if (held.IsInvalid) { int error = Marshal.GetLastWin32Error(); held.Dispose(); throw Failure("Cannot pin parent process.", error); }
            try
            {
                NativeTime created, exited, kernel, user;
                if (!GetProcessTimes(held, out created, out exited, out kernel, out user)) throw Failure("Cannot verify parent start time.");
                long ticks = DateTime.FromFileTimeUtc(((long)created.High << 32) | created.Low).Ticks;
                var image = new StringBuilder(32768); uint count = (uint)image.Capacity;
                if (!QueryFullProcessImageName(held, 0, image, ref count)) throw Failure("Cannot verify parent image.");
                if (ticks != plan.ParentStartTimeUtcTicks
                    || !SafeFiles.Same(image.ToString(), SafeFiles.Child(plan.AppRoot, UpdateContract.MainExecutable))
                    || WaitForSingleObject(held, 0) != 258)
                    throw new IOException("Parent PID/start time/image identity differs or the parent already exited.");
                return new ParentProcessLease(held);
            }
            catch { held.Dispose(); throw; }
        }
        internal bool WaitForExit(int milliseconds)
        {
            uint result = WaitForSingleObject(handle, (uint)milliseconds);
            if (result == 0) return true;
            if (result == 258) return false;
            throw Failure("Cannot wait for the pinned parent.");
        }
        internal int ExitCode
        {
            get
            {
                uint code;
                if (WaitForSingleObject(handle, 0) != 0 || !GetExitCodeProcess(handle, out code))
                    throw Failure("Cannot read the pinned parent's exit code.");
                return unchecked((int)code);
            }
        }
        public void Dispose() { handle.Dispose(); }
        private static IOException Failure(string message, int error = 0)
        { return new IOException(message, new Win32Exception(error == 0 ? Marshal.GetLastWin32Error() : error)); }
        [StructLayout(LayoutKind.Sequential)]
        private struct NativeTime { internal uint Low, High; }
        private sealed class ParentHandle : SafeHandleZeroOrMinusOneIsInvalid
        {
            private ParentHandle() : base(true) { }
            protected override bool ReleaseHandle() { return CloseHandle(handle); }
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern ParentHandle OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(ParentHandle process, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(ParentHandle process, out uint code);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(ParentHandle process, out NativeTime creation, out NativeTime exit, out NativeTime kernel, out NativeTime user);
        [DllImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool QueryFullProcessImageName(ParentHandle process, uint flags, StringBuilder name, ref uint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);
    }
}
