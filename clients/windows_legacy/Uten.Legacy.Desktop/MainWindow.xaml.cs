using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Features.Goods;
using Uten.Legacy.Desktop.Features.Units;
using Uten.Legacy.Desktop.Views;
using Uten.Legacy.Desktop.Controls;
using Uten.Legacy.Desktop.Features.Downloads;
using Uten.Legacy.Desktop.Features.Publish;
using Uten.Legacy.Desktop.Updates;

namespace Uten.Legacy.Desktop
{
    public partial class MainWindow : Window, IPendingEditHost
    {
        private readonly SessionCoordinator session;
        private readonly bool rendering;
        private readonly CancellationTokenSource lifetime = new CancellationTokenSource();
        private readonly DispatcherTimer revocationRetry = new DispatcherTimer { Interval = TimeSpan.FromMinutes(2) };
        private bool drainingRevocations;
        private bool initializing = true;
        private bool busy;
        private bool closing;
        private string displayedOwner;
        private string displayedDataset;
        private long displayedGeneration = -1;
        private readonly NativeWindowFrame nativeFrame = new NativeWindowFrame();
        private readonly HashSet<Window> pendingEditors = new HashSet<Window>();

        public MainWindow(SessionCoordinator session, ClientConfiguration configuration, bool rendering = false)
        {
            this.session = session ?? throw new ArgumentNullException(nameof(session));
            this.rendering = rendering;
            InitializeComponent();
            CommandBindings.Add(new CommandBinding(ApplicationCommands.Help, (sender, args) => OnAbout(sender, args)));
            InputBindings.Add(new KeyBinding(ApplicationCommands.Help, Key.F1, ModifierKeys.None));
            SetResourceReference(StyleProperty, typeof(Window));
            EndpointBox.ItemsSource = configuration.Endpoints;
            EndpointBox.SelectedValue = configuration.SelectedEndpointId;
            session.SessionChanged += OnSessionChanged;
            session.ReadScopeChanged += OnReadScopeChanged;
            revocationRetry.Tick += async (sender, args) => await DrainRevocationsAsync();
            SizeChanged += OnWindowSizeChanged;
            SourceInitialized += (sender, args) => UpdateWindowFrame();
            if (!rendering) FitLoginBounds();
            initializing = false;
            if (configuration.Endpoints.Count == 0)
            {
                LoginButton.IsEnabled = false;
                ShowLoginStatus("尚未配置公司服务器，请联系管理员。", true);
            }
        }

        private async void OnLoaded(object sender, RoutedEventArgs e)
        {
            if (rendering) return;
            AccountBox.Focus();
            ShowStartupUpdateOutcome();
            long restoreGeneration = session.Generation;
            try
            {
                var restore = session.RestoreAsync(lifetime.Token, waitForPendingRevocations: false);
                restoreGeneration = session.Generation;
                await restore;
                if (session.Generation == restoreGeneration) ApplySession();
            }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (!busy && session.Generation == restoreGeneration) ShowLoginStatus(error.UserMessage, true); }
            catch (Exception) { if (!busy && session.Generation == restoreGeneration) ShowLoginStatus("会话暂时无法恢复，请手动登录。", true); }
            finally
            {
                if (!closing)
                {
                    revocationRetry.Start();
                    // Revocation belongs to the stored issuer, and must also
                    // progress after an offline logout left no active session.
                    _ = DrainRevocationsAsync();
                }
            }
        }

        private async Task DrainRevocationsAsync()
        {
            if (closing || drainingRevocations) return;
            drainingRevocations = true;
            try { await session.DrainPendingRevocationsAsync(lifetime.Token); }
            catch (OperationCanceledException) { }
            catch (ApiException) { /* Durable records remain for the next bounded attempt. */ }
            finally { drainingRevocations = false; }
        }

        /// <summary>W7-UPD-009: consume the finished or interrupted update job's outcome once.
        /// The fact is shown before login so a failed/interrupted update is never silently
        /// ignored; recovery material stays untouched and remains available for the admin.</summary>
        private void ShowStartupUpdateOutcome()
        {
            try
            {
                var reader = new UpdateOutcomeReader();
                var outcome = reader.ReadFirstPending();
                if (outcome == null) return;
                new UpdateOutcomeWindow(this, outcome).ShowDialog();
                reader.MarkConsumed(outcome);
            }
            catch (Exception)
            {
                // Startup must still reach login; the unconsumed outcome resurfaces next launch.
            }
        }

        private void OnSessionChanged(object sender, EventArgs e)
        {
            if (closing) return;
            Dispatcher.BeginInvoke(new Action(() => { if (!closing) ApplySession(); }));
        }

        private void OnReadScopeChanged(object sender, EventArgs e)
        {
            if (closing) return;
            Dispatcher.BeginInvoke(new Action(() =>
            {
                if (closing || !session.IsAuthenticated || session.CurrentUser.MustChangePassword) return;
                if (WorkspaceContent.Content is GoodsWorkspaceView) OpenGoods();
                else if (WorkspaceContent.Content is DashboardView) SetWorkspace(new DashboardView(session, OpenGoods));
            }));
        }

        private void ApplySession()
        {
            var user = session.CurrentUser;
            bool authenticated = session.IsAuthenticated && user != null;
            bool mustChange = authenticated && user.MustChangePassword;
            if (!authenticated || mustChange)
            {
                DisposeWorkspace();
                displayedOwner = displayedDataset = null;
                displayedGeneration = -1;
                WorkspacePanel.Visibility = Visibility.Collapsed;
                LoginPanel.Visibility = Visibility.Visible;
                CaptionBar.Visibility = Visibility.Visible;
                CaptionRow.Height = new GridLength((double)FindResource("Uten.Height.Caption"));
                WindowSurface.SetResourceReference(Border.CornerRadiusProperty, "Uten.Radius.Card");
                SignInFields.Visibility = mustChange ? Visibility.Collapsed : Visibility.Visible;
                ChangePasswordFields.Visibility = mustChange ? Visibility.Visible : Visibility.Collapsed;
                FitLoginBounds();
                WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.CanMinimize;
                UpdateWindowFrame();
                if (mustChange) OldPasswordBox.Focus();
                return;
            }
            bool newOwner = displayedOwner != user.Id || displayedDataset != user.BusinessDatasetId
                || displayedGeneration != session.Generation;
            LoginPanel.Visibility = Visibility.Collapsed;
            WorkspacePanel.Visibility = Visibility.Visible;
            CaptionBar.Visibility = Visibility.Collapsed;
            CaptionRow.Height = new GridLength(0);
            WindowSurface.CornerRadius = new CornerRadius(0);
            SignInFields.Visibility = Visibility.Visible;
            ChangePasswordFields.Visibility = Visibility.Collapsed;
            UserLabel.Text = (user.Name ?? user.LoginAccount) + (user.SuperAdmin || string.IsNullOrWhiteSpace(user.Department) ? "" : " · " + user.Department);
            ConnectionLabel.Text = session.CurrentEndpoint == null ? "" : session.CurrentEndpoint.Name;
            GoodsNavButton.Visibility = user.HasPermission("goods:view") ? Visibility.Visible : Visibility.Collapsed;
            UnitsNavButton.Visibility = user.HasPermission("unit:view") ? Visibility.Visible : Visibility.Collapsed;
            if (newOwner)
            {
                displayedOwner = user.Id; displayedDataset = user.BusinessDatasetId;
                displayedGeneration = session.Generation;
                WindowStyle = WindowStyle.SingleBorderWindow; ResizeMode = ResizeMode.CanResize;
                MinWidth = Math.Min(960, SystemParameters.WorkArea.Width);
                MinHeight = Math.Min(640, SystemParameters.WorkArea.Height);
                Width = Math.Min(1280, SystemParameters.WorkArea.Width);
                Height = Math.Min(820, SystemParameters.WorkArea.Height);
                Left = SystemParameters.WorkArea.Left + (SystemParameters.WorkArea.Width - Width) / 2;
                Top = SystemParameters.WorkArea.Top + (SystemParameters.WorkArea.Height - Height) / 2;
                SetWorkspace(new DashboardView(session, OpenGoods), force: true);
                UpdateWindowFrame();
            }
            else if ((WorkspaceContent.Content is GoodsWorkspaceView && !user.HasPermission("goods:view"))
                || (WorkspaceContent.Content is UnitsWorkspaceView && !user.HasPermission("unit:view")))
            {
                SetWorkspace(new DashboardView(session, OpenGoods), force: true);
            }
        }

        private async void OnLogin(object sender, RoutedEventArgs e)
        {
            if (busy) return;
            string account = AccountBox.Text.Trim();
            string password = PasswordBox.Password;
            if (account.Length == 0 || password.Length == 0) { ShowLoginStatus("请输入员工账号和密码。", true); return; }
            SetBusy(true); ShowLoginStatus("正在登录…", false);
            try
            {
                await session.LoginAsync(account, password, lifetime.Token);
                PasswordBox.Clear();
                ShowLoginStatus(null, false);
                ApplySession();
            }
            catch (OperationCanceledException) { }
            catch (ApiException error) { ShowLoginStatus(error.UserMessage, true); }
            catch (Exception) { ShowLoginStatus("暂时无法完成登录，请检查公司服务器连接后重试。", true); }
            finally { password = null; if (!closing) SetBusy(false); }
        }

        private async void OnChangePassword(object sender, RoutedEventArgs e)
        {
            if (busy) return;
            if (NewPasswordBox.Password != ConfirmPasswordBox.Password) { ShowLoginStatus("两次输入的新密码不一致。", true); return; }
            if (OldPasswordBox.Password.Length == 0 || NewPasswordBox.Password.Length == 0) { ShowLoginStatus("请填写当前密码和新密码。", true); return; }
            SetBusy(true);
            try
            {
                await session.ChangePasswordAsync(OldPasswordBox.Password, NewPasswordBox.Password, lifetime.Token);
                OldPasswordBox.Clear(); NewPasswordBox.Clear(); ConfirmPasswordBox.Clear();
                ShowLoginStatus(null, false); ApplySession();
            }
            catch (OperationCanceledException) { }
            catch (ApiException error) { ShowLoginStatus(error.UserMessage, true); }
            catch (Exception) { ShowLoginStatus("本次修改结果待确认，请重新登录核对，不要连续提交。", true); }
            finally { if (!closing) SetBusy(false); }
        }

        private async void OnLogout(object sender, RoutedEventArgs e)
        {
            if (!CanLeaveWorkspace()) return;
            SetBusy(true);
            DisposeWorkspace();
            try { await session.LogoutAsync(lifetime.Token); }
            catch (OperationCanceledException) { }
            catch (ApiException error) { ShowLoginStatus(error.UserMessage, true); }
            catch (Exception) { ShowLoginStatus("已退出本机登录，服务器退出状态将在恢复连接后核对。", true); }
            finally
            {
                PasswordBox.Clear(); OldPasswordBox.Clear(); NewPasswordBox.Clear(); ConfirmPasswordBox.Clear();
                if (!closing) { ApplySession(); SetBusy(false); }
            }
        }

        private void OnEndpointChanged(object sender, SelectionChangedEventArgs e)
        {
            if (initializing || busy || EndpointBox.SelectedValue == null) return;
            try { session.SelectEndpoint(EndpointBox.SelectedValue.ToString()); PasswordBox.Clear(); ShowLoginStatus(null, false); }
            catch (Exception)
            {
                // A failed durable logout must not leave the selector naming a
                // different server from the transport that will receive login.
                initializing = true;
                try { EndpointBox.SelectedValue = session.CurrentEndpoint?.Id; }
                finally { initializing = false; }
                PasswordBox.Clear(); ShowLoginStatus(null, false);
                ShowLoginStatus("服务器切换未完成，仍使用原服务器。请联系管理员核对本机会话存储。", true);
            }
        }

        private void OnAccountChanged(object sender, TextChangedEventArgs e) { if (!initializing) ShowLoginStatus(null, false); }
        private void SetBusy(bool value)
        {
            busy = value;
            SignInFields.IsEnabled = !value; ChangePasswordFields.IsEnabled = !value;
            LoginButton.Content = value ? "请稍候…" : "登录";
        }
        private void ShowLoginStatus(string text, bool error)
        {
            LoginStatus.Text = text ?? ""; LoginStatus.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
            LoginStatus.Foreground = (System.Windows.Media.Brush)FindResource(error ? "Uten.Error" : "Uten.Muted");
        }
        private void OnDashboard(object sender, RoutedEventArgs e) { if (session.IsAuthenticated) SetWorkspace(new DashboardView(session, OpenGoods)); }
        private void OnGoods(object sender, RoutedEventArgs e) { OpenGoods(); }
        private void OnUnits(object sender, RoutedEventArgs e)
        {
            if (session.CurrentUser?.HasPermission("unit:view") == true) SetWorkspace(new UnitsWorkspaceView(session));
        }
        private void OnWindowsDownloads(object sender, RoutedEventArgs e)
        {
            if (session.IsAuthenticated && !busy) SetWorkspace(new SoftwareDownloadsView(session, OpenClientPublish));
        }

        private void OpenClientPublish()
        {
            if (!session.IsAuthenticated || busy) return;
            if (session.CurrentUser != null && session.CurrentUser.HasPermission(ClientReleasePublishLimits.PublishPermission))
                SetWorkspace(new ClientReleasePublishView(session));
        }
        private void OnAbout(object sender, RoutedEventArgs args)
        {
            if (!busy && CanLeaveWorkspace()) new AboutWindow(this).ShowDialog();
        }
        private async void OnCheckUpdate(object sender, RoutedEventArgs e)
        {
            if (busy || !session.IsAuthenticated || session.CurrentUser.MustChangePassword) return;
            if (!CanLeaveWorkspace()) return;
            long owner = session.Generation;
            CheckUpdateButton.IsEnabled = false;
            try
            {
                ConnectionLabel.Text = "正在检查 Win7 兼容版更新…";
                var updates = new ClientUpdateCoordinator(session);
                var release = await updates.CheckAsync(lifetime.Token);
                if (closing || owner != session.Generation) return;
                if (release == null) { ConnectionLabel.Text = "当前没有适用于本客户端的更新。"; return; }
                if (new UpdatePromptWindow(this, release).ShowDialog() != true) return;
                SetBusy(true); WorkspacePanel.IsEnabled = false;
                var progress = new Progress<long>(received => ConnectionLabel.Text = "正在下载并校验更新："
                    + (received / 1024d / 1024d).ToString("0.0") + " / " + (release.SizeBytes / 1024d / 1024d).ToString("0.0") + " MiB");
                using (var prepared = await updates.PrepareAsync(release, lifetime.Token, progress))
                {
                    if (closing || owner != session.Generation) return;
                    if (!CanLeaveWorkspace())
                    { ConnectionLabel.Text = "当前页面仍有未完成操作，已取消本次更新退出。"; return; }
                    prepared.AuthorizeShutdown();
                    ConnectionLabel.Text = "更新预检已完成，软件正在正常退出…";
                    Application.Current.Shutdown(0);
                }
            }
            catch (OperationCanceledException) { }
            catch (ApiException error) { if (!closing) ConnectionLabel.Text = error.UserMessage; }
            catch (Exception) { if (!closing) ConnectionLabel.Text = "更新未完成，当前客户端保持运行。请稍后重试或使用完整安装包。"; }
            finally
            {
                if (!closing) { WorkspacePanel.IsEnabled = true; CheckUpdateButton.IsEnabled = true; SetBusy(false); }
            }
        }
        private void OpenGoods() { if (session.CurrentUser?.HasPermission("goods:view") == true) SetWorkspace(new GoodsWorkspaceView(session)); }
        private bool CanLeaveWorkspace()
        {
            if (pendingEditors.Count != 0)
            { ConnectionLabel.Text = "请先完成编辑窗口的草稿保全，再退出或更新软件。"; return false; }
            var guard = WorkspaceContent?.Content as IUpdateExitGuard;
            if (guard == null || guard.CanCloseForUpdate) return true;
            ConnectionLabel.Text = "请先保存草稿或完成当前操作，再离开此页面。";
            return false;
        }
        public void TrackPendingEditor(Window editor)
        {
            Window ancestor = editor?.Owner;
            while (ancestor != null && ancestor != this) ancestor = ancestor.Owner;
            if (ancestor != this) throw new ArgumentException("The editor must belong to this main window's owned dialog chain.");
            if (pendingEditors.Add(editor)) editor.Closed += OnPendingEditorClosed;
        }
        private void OnPendingEditorClosed(object sender, EventArgs args)
        {
            var editor = sender as Window;
            if (editor == null) return;
            editor.Closed -= OnPendingEditorClosed; pendingEditors.Remove(editor);
        }
        private void SetWorkspace(object view, bool force = false)
        {
            if (!force && !CanLeaveWorkspace()) { (view as IDisposable)?.Dispose(); return; }
            DisposeWorkspace();
            WorkspaceContent.Margin = view is GoodsWorkspaceView || view is UnitsWorkspaceView ? new Thickness(0) : (Thickness)FindResource("Uten.Padding.S24");
            WorkspaceContent.Content = view;
        }
        private void DisposeWorkspace() { if (WorkspaceContent == null) return; (WorkspaceContent.Content as IDisposable)?.Dispose(); WorkspaceContent.Content = null; }
        private void OnWindowSizeChanged(object sender, SizeChangedEventArgs e)
        {
            bool compact = e.NewSize.Width < 680;
            BrandColumn.Width = compact ? new GridLength(0) : new GridLength(45, GridUnitType.Star);
            CaptionBrandColumn.Width = BrandColumn.Width;
            BrandPanel.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
            UpdateWindowFrame();
        }
        private void UpdateWindowFrame() { nativeFrame.Update(this, WindowStyle == WindowStyle.None, (double)FindResource("Uten.Radius.CardValue")); }
        private void FitLoginBounds()
        {
            var work = SystemParameters.WorkArea;
            MinWidth = Math.Min(480, work.Width); MinHeight = Math.Min(360, work.Height);
            Width = Math.Min(800, work.Width); Height = Math.Min(540, work.Height);
            if (IsLoaded) { Left = work.Left + (work.Width - Width) / 2; Top = work.Top + (work.Height - Height) / 2; }
        }
        private void OnCaptionDrag(object sender, MouseButtonEventArgs e) { if (e.ChangedButton == MouseButton.Left && e.LeftButton == MouseButtonState.Pressed) DragMove(); }
        private void OnMinimize(object sender, RoutedEventArgs e) { WindowState = WindowState.Minimized; }
        private void OnClose(object sender, RoutedEventArgs e) { Close(); }
        private void OnClosing(object sender, CancelEventArgs e)
        {
            if (closing) return;
            if (!CanLeaveWorkspace()) { e.Cancel = true; return; }
            closing = true; revocationRetry.Stop(); lifetime.Cancel();
            session.SessionChanged -= OnSessionChanged; session.ReadScopeChanged -= OnReadScopeChanged;
            DisposeWorkspace(); lifetime.Dispose();
        }
    }
}
