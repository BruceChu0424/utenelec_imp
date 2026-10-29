using System;
using System.Runtime.InteropServices;

namespace Uten.Legacy.Desktop.Features.Downloads
{
    public sealed class SoftwareDownloadHostInfo
    {
        public string OsLabel { get; private set; }
        public string Architecture { get; private set; }
        public bool IsServer { get; private set; }
        public string SuggestedFamily { get; private set; }
        public string DisplayLabel { get { return OsLabel + (Architecture == null ? " · 架构未确认" : " · " + Architecture.ToUpperInvariant()); } }
        public static SoftwareDownloadHostInfo FromFacts(int major, int minor, int build, int servicePackMajor, bool server, string architecture)
        {
            string label = server ? "Windows Server" : major == 6 && minor == 1 ? servicePackMajor >= 1 ? "Windows 7 SP1" : "Windows 7（需确认SP1）"
                : major == 6 && minor == 3 ? "Windows 8.1" : major == 6 && minor == 2 ? "Windows 8"
                : major == 10 && build >= 22000 ? "Windows 11" : major == 10 ? "Windows 10" : "Windows（版本未确认）";
            return new SoftwareDownloadHostInfo { OsLabel = label, Architecture = architecture == "x86" || architecture == "x64" || architecture == "arm64" ? architecture : null,
                IsServer = server, SuggestedFamily = server ? null : major == 10 ? ClientPackageDescriptor.FlutterRuntime
                    : major == 6 && (minor == 1 && servicePackMajor >= 1 || minor == 3) ? ClientPackageDescriptor.LegacyRuntime : null };
        }
        public static SoftwareDownloadHostInfo Read()
        {
            var version = new VersionInfo { Size = (uint)Marshal.SizeOf(typeof(VersionInfo)), ServicePack = "" };
            string architecture = SystemArchitecture();
            try
            {
                if (RtlGetVersion(ref version) == 0)
                    return FromFacts((int)version.Major, (int)version.Minor, (int)version.Build, version.ServicePackMajor, version.ProductType != 1, architecture);
            }
            catch (EntryPointNotFoundException) { }
            catch (DllNotFoundException) { }
            var fallback = Environment.OSVersion.Version;
            return FromFacts(fallback.Major, fallback.Minor, fallback.Build, 0, false, architecture);
        }
        public static string TargetLabel(string family, string architecture)
        {
            string system = family == ClientPackageDescriptor.LegacyRuntime ? "Windows 7 SP1 / 8.1" : architecture == "x86" ? "Windows 10" : "Windows 10 / 11";
            string arch = architecture == "x86" ? "X86" : architecture == "x64" ? "X64" : architecture == "arm64" ? "ARM64" : "架构未确认";
            return system + " · " + arch + (family == ClientPackageDescriptor.LegacyRuntime ? " 兼容版" : "");
        }
        public static string FileName(ClientPackageDescriptor release)
        {
            string system = release.RuntimeFamily == ClientPackageDescriptor.LegacyRuntime ? "Windows-7SP1-8.1" : release.Architecture == "x86" ? "Windows-10" : "Windows-10-11";
            return "UIMP-" + release.Version + "-" + system + "-" + release.Architecture.ToUpperInvariant() + "-Setup.exe";
        }
        private static string SystemArchitecture()
        {
            try
            {
                ushort process, native;
                if (IsWow64Process2(GetCurrentProcess(), out process, out native))
                    return native == 0xaa64 ? "arm64" : native == 0x8664 ? "x64" : native == 0x014c ? "x86" : null;
            }
            catch (EntryPointNotFoundException) { }
            var system = new SystemInfo(); GetNativeSystemInfo(out system);
            return system.Architecture == 9 ? "x64" : system.Architecture == 0 ? "x86" : system.Architecture == 12 ? "arm64" : null;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct VersionInfo
        {
            internal uint Size, Major, Minor, Build, PlatformId;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string ServicePack;
            internal ushort ServicePackMajor, ServicePackMinor, SuiteMask;
            internal byte ProductType, Reserved;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct SystemInfo
        {
            internal ushort Architecture, Reserved;
            internal uint PageSize;
            internal IntPtr MinimumAddress, MaximumAddress;
            internal UIntPtr ActiveProcessorMask;
            internal uint ProcessorCount, ProcessorType, AllocationGranularity;
            internal ushort ProcessorLevel, ProcessorRevision;
        }
        [DllImport("ntdll.dll", CharSet = CharSet.Unicode)] private static extern int RtlGetVersion(ref VersionInfo version);
        [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
        [DllImport("kernel32.dll")] private static extern void GetNativeSystemInfo(out SystemInfo info);
    }
}
