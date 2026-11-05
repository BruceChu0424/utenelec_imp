// Local headless-test launcher only. The kill-on-close job owns Node and Chrome descendants.
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;
class FinanceTestChromeLauncher {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attrs,string name);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int cls,IntPtr info,uint length);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  [StructLayout(LayoutKind.Sequential)] struct Basic {public long ProcessTime,JobTime;public uint Flags;public UIntPtr Min,Max;public uint Active;public UIntPtr Affinity;public uint Priority,Scheduling;}
  [StructLayout(LayoutKind.Sequential)] struct Counters {public ulong Read,Write,Other,ReadBytes,WriteBytes,OtherBytes;}
  [StructLayout(LayoutKind.Sequential)] struct Limits {public Basic Basic;public Counters Io;public UIntPtr ProcessMemory,JobMemory,PeakProcessMemory,PeakJobMemory;}
  static int Main(string[] args) {
    if(Array.IndexOf(args,"--version")>=0){Console.WriteLine("Google Chrome "+FileVersionInfo.GetVersionInfo(Environment.GetEnvironmentVariable("UTEN_TEST_REAL_CHROME")).ProductVersion);return 0;}
    string directory=AppDomain.CurrentDomain.BaseDirectory;
    string script=Path.Combine(directory,"finance_test_chrome_launcher.cjs");
    string ready=Path.Combine(directory,"chrome-ready-"+Process.GetCurrentProcess().Id+".flag");
    string payload=Convert.ToBase64String(Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(args)));
    string signal=Convert.ToBase64String(Encoding.UTF8.GetBytes(ready));
    IntPtr job=CreateJobObject(IntPtr.Zero,null);
    if(job==IntPtr.Zero)throw new Win32Exception();
    Process child=null;
    try {
      var limits=new Limits();limits.Basic.Flags=0x2000;
      int length=Marshal.SizeOf(typeof(Limits));IntPtr memory=Marshal.AllocHGlobal(length);
      try {Marshal.StructureToPtr(limits,memory,false);if(!SetInformationJobObject(job,9,memory,(uint)length))throw new Win32Exception();}
      finally {Marshal.FreeHGlobal(memory);}
      var info=new ProcessStartInfo(Environment.GetEnvironmentVariable("UTEN_TEST_NODE_EXE"),"\""+script+"\" "+payload+" "+signal);
      info.UseShellExecute=false;info.CreateNoWindow=true;info.RedirectStandardOutput=true;info.RedirectStandardError=true;
      child=new Process();child.StartInfo=info;
      child.OutputDataReceived+=(sender,eventArgs)=>{if(eventArgs.Data!=null)Console.Out.WriteLine(eventArgs.Data);};
      child.ErrorDataReceived+=(sender,eventArgs)=>{if(eventArgs.Data!=null)Console.Error.WriteLine(eventArgs.Data);};
      child.Start();
      if(!AssignProcessToJobObject(job,child.Handle))throw new Win32Exception();
      File.WriteAllText(ready,"ready",Encoding.ASCII);
      child.BeginOutputReadLine();child.BeginErrorReadLine();child.WaitForExit();child.WaitForExit();return child.ExitCode;
    } catch(Exception error) {Console.Error.WriteLine(error);if(child!=null&&!child.HasExited)child.Kill();return 1;}
    finally {if(File.Exists(ready))File.Delete(ready);CloseHandle(job);if(child!=null)child.Dispose();}
  }
}
