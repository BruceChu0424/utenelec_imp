using System;
using System.Collections.Generic;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Controls;
using Uten.Legacy.Desktop.Updates;

namespace Uten.Legacy.Desktop.Features.Downloads
{
    /// <summary>Native WPF download page. It saves verified files and never starts an installer.</summary>
    public sealed class SoftwareDownloadsView : UserControl, IUpdateExitGuard
    {
        private sealed class TargetChoice
        {
            public string Value { get; set; }
            public string Label { get; set; }
        }
        private readonly SessionCoordinator session;
        private readonly SoftwareDownloadsService service;
        private readonly ComboBox runtime = new ComboBox { DisplayMemberPath = "Label", SelectedValuePath = "Value" };
        private readonly ComboBox architecture = new ComboBox { DisplayMemberPath = "Label", SelectedValuePath = "Value" };
        private readonly Button refresh = new Button { Content = "刷新版本" };
        private readonly Button download = new Button { Content = "下载安装程序", Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Left };
        private readonly Button cancel = new Button { Content = "取消下载", Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Left };
        private readonly TextBlock status = new TextBlock();
        private readonly TextBlock packageTitle = new TextBlock { Visibility = Visibility.Collapsed };
        private readonly TextBlock packageInfo = new TextBlock { Visibility = Visibility.Collapsed };
        private readonly TextBlock notes = new TextBlock { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        private readonly TextBlock savedPath = new TextBlock { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        private readonly ProgressBar progress = new ProgressBar { Minimum = 0, Maximum = 100, Visibility = Visibility.Collapsed };
        private readonly TextBlock progressText = new TextBlock { Visibility = Visibility.Collapsed };
        private CancellationTokenSource lifetime, readCancellation, transferCancellation;
        private long readSequence, transferSequence, observedGeneration, observedReadRevision;
        private long packageGeneration, packageReadRevision;
        private ClientPackageDescriptor selected;
        private bool subscribed, initializing = true, loading, transferring, choosingPath;
        private int activeTransfers;
        public bool CanCloseForUpdate { get { return !choosingPath && !transferring && activeTransfers == 0; } }

        public SoftwareDownloadsView(SessionCoordinator session)
        {
            this.session = session ?? throw new ArgumentNullException(nameof(session));
            SetResourceReference(StyleProperty, "Uten.Workspace");
            service = new SoftwareDownloadsService(session);
            BuildLayout();
            runtime.ItemsSource = new[] {
                new TargetChoice { Value = ClientPackageDescriptor.LegacyRuntime, Label = "Windows 7 SP1 / 8.1 兼容版" },
                new TargetChoice { Value = ClientPackageDescriptor.FlutterRuntime, Label = "Windows 10 / 11 常规版" }
            };
            architecture.ItemsSource = new[] {
                new TargetChoice { Value = "x64", Label = "64 位 · Intel / AMD" },
                new TargetChoice { Value = "x86", Label = "32 位" }
            };
            runtime.SelectedValue = ClientPackageDescriptor.LegacyRuntime;
            architecture.SelectedValue = Environment.Is64BitOperatingSystem ? "x64" : "x86";
            initializing = false;
            runtime.SelectionChanged += OnTargetChanged;
            architecture.SelectionChanged += OnTargetChanged;
            refresh.Click += async (sender, args) => await LoadAsync();
            download.Click += async (sender, args) => await DownloadAsync();
            cancel.Click += (sender, args) => transferCancellation?.Cancel();
            Loaded += OnLoaded;
            Unloaded += OnUnloaded;
        }

        private double Space(string token) { return (double)FindResource("Uten.Space." + token); }
        private Thickness Gap(string top = null, string right = null, string bottom = null)
        {
            return new Thickness(0, top == null ? 0 : Space(top), right == null ? 0 : Space(right), bottom == null ? 0 : Space(bottom));
        }
        private void BuildLayout()
        {
            SetResourceReference(BackgroundProperty, "Uten.Background");
            var content = new StackPanel();
            content.SetResourceReference(MarginProperty, "Uten.Padding.S24");
            var header = new DockPanel { Margin = Gap(bottom: "S16") };
            refresh.SetResourceReference(MinHeightProperty, "Uten.Height.Standard");
            DockPanel.SetDock(refresh, Dock.Right); header.Children.Add(refresh);
            var title = new TextBlock { Text = "Windows 下载", VerticalAlignment = VerticalAlignment.Center };
            title.SetResourceReference(StyleProperty, "Uten.PageTitle"); header.Children.Add(title);
            content.Children.Add(header);
            var panel = new StackPanel();
            var selectors = new Grid();
            selectors.ColumnDefinitions.Add(new ColumnDefinition());
            selectors.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Space("S12")) });
            selectors.ColumnDefinitions.Add(new ColumnDefinition());
            selectors.Children.Add(Selector("Windows 版本", runtime));
            var architecturePanel = Selector("电脑架构", architecture);
            Grid.SetColumn(architecturePanel, 2); selectors.Children.Add(architecturePanel);
            panel.Children.Add(selectors);
            packageTitle.SetResourceReference(StyleProperty, "Uten.SectionTitle");
            packageTitle.Margin = Gap(top: "S24"); panel.Children.Add(packageTitle);
            packageInfo.Margin = Gap(top: "S8"); packageInfo.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Muted"); panel.Children.Add(packageInfo);
            status.Margin = Gap(top: "S12"); status.TextWrapping = TextWrapping.Wrap; panel.Children.Add(status);
            notes.Margin = Gap(top: "S12", bottom: "S16"); panel.Children.Add(notes);
            download.SetResourceReference(StyleProperty, "Uten.PrimaryButton");
            download.SetResourceReference(MinHeightProperty, "Uten.Height.Primary");
            panel.Children.Add(download);
            progress.Margin = Gap(top: "S16"); progress.SetResourceReference(HeightProperty, "Uten.Space.S4");
            progress.SetResourceReference(ForegroundProperty, "Uten.PrimaryBrush"); panel.Children.Add(progress);
            progressText.Margin = Gap(top: "S8"); progressText.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Muted"); panel.Children.Add(progressText);
            cancel.Margin = Gap(top: "S8"); panel.Children.Add(cancel);
            savedPath.Margin = Gap(top: "S12"); panel.Children.Add(savedPath);
            var surface = new RoundedSurface { Child = panel, BorderThickness = new Thickness(1) };
            surface.SetResourceReference(Border.CornerRadiusProperty, "Uten.Radius.Card");
            surface.SetResourceReference(Border.PaddingProperty, "Uten.Padding.S24");
            surface.SetResourceReference(Border.BackgroundProperty, "Uten.Surface");
            surface.SetResourceReference(Border.BorderBrushProperty, "Uten.Border"); content.Children.Add(surface);
            var guidance = new TextBlock { Text = "请选择目标电脑的系统和架构。下载完成后，请在对应 Windows 电脑上打开安装程序，并使用本人账号登录。兼容版的功能范围与更新方式以对应发布说明为准。",
                TextWrapping = TextWrapping.Wrap, Margin = Gap(top: "S16") };
            guidance.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Muted"); content.Children.Add(guidance);
            Content = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        }
        private StackPanel Selector(string label, ComboBox control)
        {
            var panel = new StackPanel();
            var caption = new TextBlock { Text = label, Margin = Gap(bottom: "S8") };
            caption.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Muted"); panel.Children.Add(caption);
            control.SetResourceReference(MinHeightProperty, "Uten.Height.Input"); panel.Children.Add(control);
            return panel;
        }
        private string Family { get { return runtime.SelectedValue as string; } }
        private string Architecture { get { return architecture.SelectedValue as string; } }
        private async void OnLoaded(object sender, RoutedEventArgs args)
        {
            if (subscribed) return;
            subscribed = true; session.SessionChanged += OnSessionChanged; session.ReadScopeChanged += OnSessionChanged;
            observedGeneration = session.Generation; observedReadRevision = session.ReadScopeRevision;
            lifetime = new CancellationTokenSource();
            await LoadAsync();
        }
        private void OnUnloaded(object sender, RoutedEventArgs args)
        {
            if (subscribed) { session.SessionChanged -= OnSessionChanged; session.ReadScopeChanged -= OnSessionChanged; }
            subscribed = false; CancelOperations(); lifetime?.Cancel(); lifetime?.Dispose(); lifetime = null;
        }
        private void OnSessionChanged(object sender, EventArgs args)
        {
            if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(new Action(() => OnSessionChanged(sender, args))); return; }
            if (!subscribed || !IsLoaded || observedGeneration == session.Generation && observedReadRevision == session.ReadScopeRevision) return;
            observedGeneration = session.Generation; observedReadRevision = session.ReadScopeRevision;
            CancelOperations(); ClearPackage(); status.Text = "账号、权限或服务器连接已变化，请重新获取下载版本。";
        }
        private void CancelOperations()
        {
            readSequence++; transferSequence++; readCancellation?.Cancel(); transferCancellation?.Cancel();
            loading = transferring = false; UpdateControls();
        }
        private void ClearPackage()
        {
            selected = null; download.Visibility = Visibility.Collapsed;
            packageTitle.Text = ""; packageInfo.Text = ""; notes.Text = ""; savedPath.Text = "";
            packageTitle.Visibility = packageInfo.Visibility = notes.Visibility = savedPath.Visibility = progressText.Visibility = Visibility.Collapsed;
            progress.Visibility = cancel.Visibility = Visibility.Collapsed; progressText.Text = ""; progress.Value = 0;
        }
        private async void OnTargetChanged(object sender, SelectionChangedEventArgs args)
        {
            if (!initializing && IsLoaded && !transferring) await LoadAsync();
        }
        public async Task LoadAsync()
        {
            if (!IsLoaded || lifetime == null || lifetime.IsCancellationRequested || transferring || Family == null || Architecture == null) return;
            readCancellation?.Cancel(); long mine = ++readSequence, owner = session.Generation, revision = session.ReadScopeRevision;
            var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            readCancellation = cancellation; string family = Family, targetArchitecture = Architecture;
            ClearPackage(); loading = true; UpdateControls(); status.Text = "正在获取可下载版本…";
            try
            {
                var packages = await service.LoadAsync(targetArchitecture, cancellation.Token);
                if (cancellation.IsCancellationRequested || mine != readSequence || owner != session.Generation || revision != session.ReadScopeRevision || !IsLoaded) return;
                selected = SoftwareDownloadsContract.SelectInstaller(packages, family, targetArchitecture);
                if (selected == null)
                {
                    packageTitle.Text = family == ClientPackageDescriptor.LegacyRuntime ? "兼容版暂未发布" : "常规版暂未发布";
                    packageTitle.Visibility = Visibility.Visible;
                    status.Text = "所选系统与架构的安装包暂未发布。公司发布对应版本后即可下载。";
                    return;
                }
                packageGeneration = owner; packageReadRevision = revision;
                packageTitle.Text = family == ClientPackageDescriptor.LegacyRuntime ? "Windows 7 SP1 / 8.1 兼容版" : "Windows 10 / 11 常规版";
                packageInfo.Text = "版本 " + selected.Version + " · " + (targetArchitecture == "x86" ? "32 位" : "64 位") + " · " + Megabytes(selected.SizeBytes) + " MB";
                packageTitle.Visibility = packageInfo.Visibility = Visibility.Visible;
                notes.Text = selected.ReleaseNotes;
                notes.Visibility = String.IsNullOrWhiteSpace(selected.ReleaseNotes) ? Visibility.Collapsed : Visibility.Visible;
                status.Text = "下载完成后将核验完整性，并保存完整安装程序。";
                download.Visibility = Visibility.Visible;
            }
            catch (OperationCanceledException) { }
            catch (Exception error)
            {
                if (!cancellation.IsCancellationRequested && mine == readSequence && owner == session.Generation && IsLoaded)
                { ClearPackage(); status.Text = error is ApiException ? ((ApiException)error).UserMessage : "暂时无法获取版本，请检查连接与下载资格后刷新重试。"; }
            }
            finally
            {
                cancellation.Dispose();
                if (ReferenceEquals(readCancellation, cancellation)) readCancellation = null;
                if (mine == readSequence && IsLoaded) { loading = false; UpdateControls(); }
            }
        }
        private async Task DownloadAsync()
        {
            var package = selected;
            if (transferring || loading || package == null || !package.IsInstallerFor(Family, Architecture)
                || packageGeneration != session.Generation || packageReadRevision != session.ReadScopeRevision) return;
            long owner = session.Generation, revision = session.ReadScopeRevision;
            var chooser = new SaveFileDialog { Title = "保存 Windows 安装程序", FileName = package.FileName,
                Filter = "Windows 安装程序 (*.exe)|*.exe", DefaultExt = ".exe", AddExtension = true,
                CheckPathExists = true, OverwritePrompt = true };
            bool? accepted;
            choosingPath = true; UpdateControls();
            try { accepted = chooser.ShowDialog(Window.GetWindow(this)); }
            finally { choosingPath = false; UpdateControls(); }
            if (accepted != true || owner != session.Generation || revision != session.ReadScopeRevision || !IsLoaded) return;
            long mine = ++transferSequence;
            var cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            transferCancellation = cancellation; transferring = true; activeTransfers++; savedPath.Text = "";
            savedPath.Visibility = Visibility.Collapsed; progress.Value = 0;
            progress.Visibility = cancel.Visibility = Visibility.Visible; status.Text = "正在下载安装程序…"; UpdateControls();
            progressText.Visibility = Visibility.Visible;
            var observer = new Progress<long>(received =>
            {
                if (mine != transferSequence || owner != session.Generation || revision != session.ReadScopeRevision || !IsLoaded || cancellation.IsCancellationRequested) return;
                progress.Value = Math.Min(100, (double)received / package.SizeBytes * 100);
                progressText.Text = "已下载 " + Megabytes(received) + " / " + Megabytes(package.SizeBytes) + " MB";
            });
            try
            {
                string path = await service.DownloadAsync(package, Family, Architecture, chooser.FileName, cancellation.Token, observer);
                if (cancellation.IsCancellationRequested || mine != transferSequence || owner != session.Generation || revision != session.ReadScopeRevision || !IsLoaded) return;
                progress.Value = 100; status.Text = "安装程序已校验并保存。"; savedPath.Text = path; savedPath.Visibility = Visibility.Visible;
            }
            catch (OperationCanceledException)
            {
                if (mine == transferSequence && IsLoaded) { status.Text = "下载已取消。"; progressText.Text = ""; progressText.Visibility = Visibility.Collapsed; }
            }
            catch (Exception error)
            {
                if (mine == transferSequence && owner == session.Generation && IsLoaded)
                { status.Text = error is ApiException ? ((ApiException)error).UserMessage : "下载未完成，请检查网络和本机可用空间后重试。"; savedPath.Text = ""; }
            }
            finally
            {
                activeTransfers--;
                cancellation.Dispose();
                if (ReferenceEquals(transferCancellation, cancellation)) transferCancellation = null;
                if (mine == transferSequence && IsLoaded) { transferring = false; cancel.Visibility = Visibility.Collapsed; UpdateControls(); }
            }
        }
        private void UpdateControls()
        {
            runtime.IsEnabled = architecture.IsEnabled = !transferring && !choosingPath;
            refresh.IsEnabled = !loading && !transferring && !choosingPath;
            download.IsEnabled = selected != null && !loading && !transferring && !choosingPath;
        }
        private static string Megabytes(long bytes) { return ((decimal)bytes / 1048576m).ToString("0.0", CultureInfo.CurrentCulture); }
    }
}
