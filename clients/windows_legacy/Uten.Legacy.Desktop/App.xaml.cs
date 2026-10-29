using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Threading;
using System.Security.Principal;
using Uten.Legacy.Core;

namespace Uten.Legacy.Desktop
{
    public partial class App : Application
    {
        private SessionCoordinator session;
        private Mutex instance;
        private bool ownsInstance;

        private void OnStartup(object sender, StartupEventArgs e)
        {
            // Resource consumers/contract runners can load this Application without
            // launching the desktop executable. They must never start its real
            // profile, single-instance mutex or default company network session.
            if (!Object.ReferenceEquals(Assembly.GetEntryAssembly(), typeof(App).Assembly)) return;
            bool render = e.Args.Length == 2 && e.Args[0] == "--render-login";
            bool development = e.Args.Contains("--development-smoke");
            // Installing/launching this validation client on modern Windows is
            // opt-in for developers. Its DPAPI profile never shares Flutter data.
            if (Environment.OSVersion.Version.Major >= 10 && !render && !development)
            {
                MessageBox.Show("此电脑请继续使用现有 UTEN 客户端。Win7 兼容验证版不会替换现有版本。", "UTEN", MessageBoxButton.OK, MessageBoxImage.Information);
                Shutdown(2);
                return;
            }
            try
            {
                if (!render)
                {
                    string user = WindowsIdentity.GetCurrent().User.Value;
                    instance = new Mutex(false, "Local\\Uten.Win7.Wpf." + user);
                    try { ownsInstance = instance.WaitOne(0, false); }
                    catch (AbandonedMutexException) { ownsInstance = true; }
                    if (!ownsInstance)
                    {
                        MessageBox.Show("Win7 兼容客户端已在运行。", "UTEN", MessageBoxButton.OK, MessageBoxImage.Information);
                        Shutdown(2); return;
                    }
                }
                var configuration = ClientConfiguration.Load(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "uten.client.json"));
                session = new SessionCoordinator(configuration);
                var window = new MainWindow(session, configuration, render);
                MainWindow = window;
                if (render)
                {
                    // Actual WPF controls rendered without showing a window,
                    // reading a token store, or making a backend request.
                    RenderOptions.ProcessRenderMode = System.Windows.Interop.RenderMode.SoftwareOnly;
                    var content = (FrameworkElement)window.Content;
                    content.Measure(new Size(800, 540));
                    content.Arrange(new Rect(0, 0, 800, 540));
                    content.UpdateLayout();
                    var bitmap = new RenderTargetBitmap(800, 540, 96, 96, PixelFormats.Pbgra32);
                    bitmap.Render(content);
                    var encoder = new PngBitmapEncoder();
                    encoder.Frames.Add(BitmapFrame.Create(bitmap));
                    string target = Path.GetFullPath(e.Args[1]);
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    using (var stream = File.Create(target)) encoder.Save(stream);
                    window.Close();
                    Shutdown(0);
                    return;
                }
                window.Show();
            }
            catch (Exception error)
            {
                // Never display configuration contents, request bodies or tokens.
                if (render) Console.Error.WriteLine("WPF_RENDER_FAILED " + error);
                else MessageBox.Show("客户端启动失败。请联系管理员核对本兼容版本及服务器配置。", "UTEN", MessageBoxButton.OK, MessageBoxImage.Error);
                Shutdown(1);
            }
        }

        protected override void OnExit(ExitEventArgs e)
        {
            (session as IDisposable)?.Dispose();
            if (ownsInstance) instance.ReleaseMutex();
            instance?.Dispose();
            base.OnExit(e);
        }
    }
}
