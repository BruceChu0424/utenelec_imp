using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Microsoft.Win32;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Controls;
using Uten.Legacy.Desktop.Updates;

namespace Uten.Legacy.Desktop.Features.Publish
{
    /// <summary>Native publish workbench: target/version context, file queue with per-row
    /// outcomes, the release ledger with withdrawal, and the Windows pair summary. Not a
    /// read-only shell — every prepare/upload/publish/withdraw path goes through the queue.</summary>
    public sealed class ClientReleasePublishView : UserControl, IUpdateExitGuard, IDisposable
    {
        private const double WideLayoutThreshold = 1120;
        private readonly SessionCoordinator session;
        private readonly DpapiPublishDraftStore draftStore = new DpapiPublishDraftStore();
        private readonly ClientReleaseTargetEditor contextEditor = new ClientReleaseTargetEditor();
        private readonly TextBox releaseNotes = new TextBox { MinHeight = 56, TextWrapping = TextWrapping.Wrap, AcceptsReturn = true, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        private readonly TabControl tabs = new TabControl();
        private readonly StackPanel queueRows = new StackPanel();
        private readonly StackPanel ledgerRows = new StackPanel();
        private readonly TextBlock notice = new TextBlock { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        private readonly TextBlock queueStatus = new TextBlock { TextWrapping = TextWrapping.Wrap };
        private readonly TextBlock pairSummary = new TextBlock { TextWrapping = TextWrapping.Wrap };
        private readonly TextBlock countSummary = new TextBlock { TextWrapping = TextWrapping.Wrap };
        private readonly Button addFile = new Button { Content = "添加单个文件" };
        private readonly Button addMany = new Button { Content = "批量添加" };
        private readonly Button addStore = new Button { Content = "添加商店链接", Visibility = Visibility.Collapsed };
        private readonly Button run = new Button { Content = "上传并发布" };
        private readonly Button refreshLedger = new Button { Content = "刷新发布记录" };
        private readonly Button saveDraft = new Button { Content = "保存发布草稿" };
        private readonly ScrollViewer workScroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        private readonly ScrollViewer summaryScroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        private readonly Grid contentGrid = new Grid();
        private readonly StackPanel lockedPanel = new StackPanel { Visibility = Visibility.Collapsed };
        private readonly StackPanel mainPanel = new StackPanel();
        private readonly Dictionary<string, QueueRow> rowControls = new Dictionary<string, QueueRow>(StringComparer.Ordinal);
        private readonly DispatcherTimer debounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
        private readonly CancellationTokenSource lifetime = new CancellationTokenSource();

        private ClientReleasePublishQueue queue;
        private ClientReleasePublishDraftLease lease;
        private bool retired, choosing, ready, exitAllowed, discarding, discarded, hadInput, storageError, rebuilding, disposed;

        /// <summary>Small adapter exposing the protected dialog body/action helpers to this view.</summary>
        private sealed class PromptDialog : UtenDialogWindow
        {
            public PromptDialog(Window owner, string title, double width = 480) : base(owner, title, width) { }
            public void Add(UIElement element) { Body.Children.Add(element); }
            public Button AddAction(string text, Action action, bool primary = false)
            { return ActionButton(text, action, primary); }
        }

        public bool CanCloseForUpdate { get { return ConfirmLeave(); } }

        public ClientReleasePublishView(SessionCoordinator session)
        {
            this.session = session ?? throw new ArgumentNullException("session");
            SetResourceReference(StyleProperty, "Uten.Workspace");
            BuildLayout();
            addFile.Click += delegate { PickFiles(false, null); };
            addMany.Click += delegate { PickFiles(true, null); };
            addStore.Click += delegate { AddStoreRow(); };
            run.Click += async delegate { await RunQueueAsync(); };
            refreshLedger.Click += async delegate { await ReloadLedgerAsync(); };
            saveDraft.Click += delegate { SaveDraft(); };
            releaseNotes.TextChanged += delegate { hadInput = true; ScheduleDraftSave(); };
            debounce.Tick += delegate { debounce.Stop(); SaveDraft(); };
            session.SessionChanged += OnSessionChanged;
            Loaded += async delegate { await InitializeAsync(); };
            Unloaded += delegate { session.SessionChanged -= OnSessionChanged; };
            SizeChanged += delegate { ApplyLayout(); };
        }

        private double Space(string token) { return (double)FindResource("Uten.Space." + token); }
        private void Status(string text, bool error)
        {
            notice.Text = text ?? "";
            notice.Visibility = String.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
            notice.SetResourceReference(TextBlock.ForegroundProperty, error ? "Uten.Error" : "Uten.Muted");
        }

        private void BuildLayout()
        {
            SetResourceReference(BackgroundProperty, "Uten.Background");
            var content = new DockPanel();
            content.Children.Add(BuildHeader());
            mainPanel.Children.Add(BuildContextPanel());
            mainPanel.Children.Add(notice);
            contentGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            contentGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            contentGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            contentGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(300), MinWidth = 260 });
            contentGrid.Children.Add(workScroll);
            contentGrid.Children.Add(summaryScroll);
            mainPanel.Children.Add(contentGrid);
            var page = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            page.Content = mainPanel;
            content.Children.Add(page);
            lockedPanel.Children.Add(new TextBlock
            {
                Text = "发布身份、权限或服务器已变化，请重新进入页面。原发布元数据只保留在原账号下。",
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, Space("S16"), 0, 0)
            });
            lockedPanel.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Error");
            var host = new Grid();
            host.Children.Add(page);
            host.Children.Add(lockedPanel);
            Content = host;
            workScroll.Content = BuildWorkPanel();
            summaryScroll.Content = BuildSummaryPanel();
            ApplyLayout();
        }

        private Border BuildHeader()
        {
            var title = new TextBlock { Text = "客户端发布工作台", Style = (Style)FindResource("Uten.PageTitle") };
            var subtitle = new TextBlock
            {
                Text = "选择文件、核对目标与版本，逐项上传并保留明确结果",
                TextWrapping = TextWrapping.Wrap
            };
            subtitle.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Muted");
            var head = new StackPanel { Margin = new Thickness(0, 0, 0, Space("S16")) };
            head.Children.Add(title);
            head.Children.Add(subtitle);
            DockPanel.SetDock(head, Dock.Top);
            return new Border { Child = head };
        }

        private Border BuildContextPanel()
        {
            var panel = new StackPanel { Margin = new Thickness(0, 0, 0, Space("S12")) };
            var caption = new TextBlock { Text = "版本与适用设备", Margin = new Thickness(0, 0, 0, Space("S8")), Style = (Style)FindResource("Uten.SectionTitle") };
            panel.Children.Add(caption);
            var editorHost = new StackPanel();
            var fields = new StackPanel { Orientation = Orientation.Horizontal };
            foreach (var child in contextEditor.Root.Children.Cast<UIElement>().ToList()) fields.Children.Add(child);
            editorHost.Children.Add(fields);
            var notesLabel = new TextBlock { Text = "发布说明", Margin = new Thickness(0, Space("S8"), 0, Space("S4")) };
            notesLabel.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Muted");
            editorHost.Children.Add(notesLabel);
            releaseNotes.MinWidth = 320;
            editorHost.Children.Add(releaseNotes);
            panel.Children.Add(editorHost);
            return WrapCard(panel);
        }

        private Control BuildWorkPanel()
        {
            var queueTab = new TabItem { Header = "发布队列" };
            var queuePanel = new StackPanel { Margin = new Thickness(Space("S8")) };
            var queueHeader = new DockPanel { Margin = new Thickness(0, 0, 0, Space("S8")) };
            var queueCaption = new TextBlock { Text = "文件队列", VerticalAlignment = VerticalAlignment.Center, Style = (Style)FindResource("Uten.SectionTitle") };
            DockPanel.SetDock(queueCaption, Dock.Left);
            queueHeader.Children.Add(queueCaption);
            var actions = new StackPanel { Orientation = Orientation.Horizontal };
            addFile.SetResourceReference(MinHeightProperty, "Uten.Height.Standard");
            addMany.SetResourceReference(MinHeightProperty, "Uten.Height.Standard");
            addStore.SetResourceReference(MinHeightProperty, "Uten.Height.Standard");
            actions.Children.Add(addFile);
            actions.Children.Add(addMany);
            actions.Children.Add(addStore);
            DockPanel.SetDock(actions, Dock.Right);
            queueHeader.Children.Add(actions);
            queuePanel.Children.Add(queueHeader);
            var queueScroll = new ScrollViewer { MaxHeight = 420, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            queueScroll.Content = queueRows;
            queuePanel.Children.Add(queueScroll);
            queuePanel.Children.Add(queueStatus);
            run.SetResourceReference(StyleProperty, "Uten.PrimaryButton");
            run.SetResourceReference(MinHeightProperty, "Uten.Height.Standard");
            run.MinWidth = 128;
            run.Margin = new Thickness(0, Space("S8"), 0, 0);
            run.HorizontalAlignment = HorizontalAlignment.Left;
            queuePanel.Children.Add(run);
            queueTab.Content = queuePanel;

            var ledgerTab = new TabItem { Header = "发布记录" };
            var ledgerPanel = new StackPanel { Margin = new Thickness(Space("S8")) };
            var ledgerHeader = new DockPanel { Margin = new Thickness(0, 0, 0, Space("S8")) };
            var ledgerCaption = new TextBlock { Text = "原文件的发布与撤回结果", VerticalAlignment = VerticalAlignment.Center, Style = (Style)FindResource("Uten.SectionTitle") };
            DockPanel.SetDock(ledgerCaption, Dock.Left);
            ledgerHeader.Children.Add(ledgerCaption);
            refreshLedger.SetResourceReference(MinHeightProperty, "Uten.Height.Standard");
            DockPanel.SetDock(refreshLedger, Dock.Right);
            ledgerHeader.Children.Add(refreshLedger);
            ledgerPanel.Children.Add(ledgerHeader);
            var ledgerScroll = new ScrollViewer { MaxHeight = 460, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            ledgerScroll.Content = ledgerRows;
            ledgerPanel.Children.Add(ledgerScroll);
            ledgerTab.Content = ledgerPanel;

            tabs.Items.Add(queueTab);
            tabs.Items.Add(ledgerTab);
            return tabs;
        }

        private UIElement BuildSummaryPanel()
        {
            var panel = new StackPanel();
            var pairCaption = new TextBlock { Text = "完整配对", Margin = new Thickness(0, 0, 0, Space("S8")), Style = (Style)FindResource("Uten.SectionTitle") };
            panel.Children.Add(pairCaption);
            panel.Children.Add(pairSummary);
            var pairNote = new TextBlock
            {
                Text = "新发布的 Windows 组：同适用设备、版本和构建号的 Setup 与 ZIP 都发布后，才开放该组下载。历史版本沿原发布方式保留。",
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, Space("S4"), 0, Space("S12"))
            };
            pairNote.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Muted");
            panel.Children.Add(pairNote);
            var countCaption = new TextBlock { Text = "发布摘要", Margin = new Thickness(0, 0, 0, Space("S8")), Style = (Style)FindResource("Uten.SectionTitle") };
            panel.Children.Add(countCaption);
            panel.Children.Add(countSummary);
            saveDraft.SetResourceReference(MinHeightProperty, "Uten.Height.Standard");
            saveDraft.Margin = new Thickness(0, Space("S12"), 0, 0);
            saveDraft.HorizontalAlignment = HorizontalAlignment.Left;
            panel.Children.Add(saveDraft);
            return WrapCard(panel);
        }

        private Border WrapCard(object content)
        {
            var border = new Border { Child = content as UIElement, Padding = new Thickness(Space("S16")), Margin = new Thickness(0, 0, 0, Space("S12")) };
            border.SetResourceReference(Border.BorderBrushProperty, "Uten.Border");
            border.SetResourceReference(Border.BackgroundProperty, "Uten.Surface");
            border.SetResourceReference(Border.CornerRadiusProperty, "Uten.Radius.CardValue");
            return border;
        }

        private void ApplyLayout()
        {
            if (ActualWidth >= WideLayoutThreshold)
            {
                Grid.SetRow(workScroll, 0); Grid.SetColumn(workScroll, 0);
                Grid.SetRow(summaryScroll, 0); Grid.SetColumn(summaryScroll, 1);
                contentGrid.RowDefinitions[1].Height = new GridLength(0);
            }
            else
            {
                Grid.SetRow(workScroll, 0); Grid.SetColumn(workScroll, 0);
                Grid.SetRow(summaryScroll, 1); Grid.SetColumn(summaryScroll, 0);
                contentGrid.RowDefinitions[1].Height = new GridLength(1, GridUnitType.Star);
            }
        }

        private async System.Threading.Tasks.Task InitializeAsync()
        {
            if (ready || retired) return;
            try
            {
                session.DemandClientReleasePublishAccess();
                var user = session.CurrentUser;
                var baseUrl = session.CurrentEndpoint?.ApiBaseUrl;
                if (user == null || baseUrl == null) throw new ApiException("FORBIDDEN", "发布身份不可用，请重新登录。", 403);
                var namespaceHash = ClientReleasePublishDraftLease.ComputeNamespaceHash(baseUrl, user);
                var previous = draftStore.List(namespaceHash).FirstOrDefault();
                string draftId = null;
                if (previous != null && OfferResume(previous))
                {
                    draftId = previous.DraftId;
                }
                lease = new ClientReleasePublishDraftLease(draftStore, baseUrl, user, draftId);
                var service = new ClientReleasePublishService(session, Window.GetWindow(this));
                service.Begin();
                queue = new ClientReleasePublishQueue(service, SaveDraft);
                queue.Changed += OnQueueChanged;
                var stored = lease.Load();
                if (stored != null)
                {
                    var snapshot = ClientReleasePublishContract.ValidateAndRestore(stored);
                    queue.Restore(snapshot);
                    if (snapshot.Context != null)
                    {
                        contextEditor.Bind(MetadataFromContext(snapshot.Context));
                        releaseNotes.Text = ContextText(snapshot.Context, "releaseNotes");
                    }
                    Status("已恢复发布元数据。原提交先核对状态；文件内容不会保存在草稿中，请按提示重选原文件。", false);
                }
                ready = true;
                UpdateControls();
                try { await queue.LoadAsync(lifetime.Token); }
                catch (Exception) { Status("发布列表暂未读取完整，已保留当前队列。", true); }
            }
            catch (Exception error)
            {
                Status(ClientReleasePublishQueue.Describe(error), true);
                storageError = true;
            }
        }

        private bool OfferResume(PublishDraftEntry previous)
        {
            var dialog = new PromptDialog(Window.GetWindow(this), "恢复发布草稿", 460);
            dialog.Add(new TextBlock
            {
                Text = "检测到 " + previous.LastWriteUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm") + " 保存的未确认发布草稿。恢复后先核对原状态；文件需要重新选择。",
                TextWrapping = TextWrapping.Wrap
            });
            var resumed = false;
            dialog.AddAction("恢复草稿", delegate { resumed = true; dialog.Close(); }, true);
            dialog.AddAction("不用了", delegate { dialog.Close(); });
            dialog.ShowDialog();
            return resumed;
        }

        private static ClientReleasePublishMetadata MetadataFromContext(Dictionary<string, object> context)
        {
            try { return ClientReleasePublishMetadata.FromDictionary(context); }
            catch (Exception) { return DefaultContext(); }
        }

        private static string ContextText(Dictionary<string, object> context, string key)
        {
            object value;
            return context != null && context.TryGetValue(key, out value) && value is string ? (string)value : "";
        }

        private static ClientReleasePublishMetadata DefaultContext()
        {
            return new ClientReleasePublishMetadata
            {
                Platform = "windows",
                RuntimeFamily = "flutter",
                Architecture = "x64",
                PackageKind = "update",
                Version = "",
                BuildNumber = "",
                ReleaseNotes = "",
                StoreUrl = ""
            };
        }

        private void OnSessionChanged(object sender, EventArgs args)
        {
            if (retired) return;
            var user = session.CurrentUser;
            if (user == null || !user.HasPermission(ClientReleasePublishLimits.PublishPermission))
            {
                Retire();
                return;
            }
        }

        private void Retire()
        {
            retired = true;
            if (queue != null) queue.Retire();
            SaveDraft();
            mainPanel.Visibility = Visibility.Collapsed;
            lockedPanel.Visibility = Visibility.Visible;
        }

        private void OnQueueChanged()
        {
            if (rebuilding) return;
            rebuilding = true;
            Dispatcher.BeginInvoke(new Action(delegate
            {
                rebuilding = false;
                RebuildRows();
                RebuildLedger();
                UpdateSummary();
                UpdateControls();
            }), DispatcherPriority.Background);
            ScheduleDraftSave();
        }

        private void ScheduleDraftSave()
        {
            if (!ready || retired || discarding || disposed) return;
            debounce.Stop();
            debounce.Start();
        }

        private bool SaveDraft()
        {
            if (!ready || retired || discarding || disposed) return true;
            if (queue == null || lease == null) return true;
            if (!hadInput && queue.Items.Count == 0) return true;
            try
            {
                var context = contextEditor.Read();
                context.ReleaseNotes = releaseNotes.Text;
                var contextDict = context.ToDictionary();
                contextDict["releaseNotes"] = releaseNotes.Text;
                var snapshot = ClientReleasePublishContract.BuildSnapshot(queue.Items, contextDict, queue.Withdrawals);
                lease.Save(new System.Web.Script.Serialization.JavaScriptSerializer().Serialize(snapshot));
                storageError = false;
                if (notice.Text == "本机草稿尚未保存，请保留此页并重试；未保全的项目不会继续发送。") Status(null, false);
                return true;
            }
            catch (Exception)
            {
                storageError = true;
                Status("本机草稿尚未保存，请保留此页并重试；未保全的项目不会继续发送。", true);
                return false;
            }
        }

        private void PickFiles(bool multiple, ClientReleaseQueueItem replacing)
        {
            if (!ready || retired || queue.Busy || choosing) return;
            choosing = true;
            UpdateControls();
            try
            {
                var dialog = new OpenFileDialog
                {
                    Filter = "客户端发布文件 (*.exe;*.zip;*.apk)|*.exe;*.zip;*.apk",
                    Multiselect = multiple,
                    CheckFileExists = true
                };
                if (dialog.ShowDialog(Window.GetWindow(this)) != true || dialog.FileNames.Length == 0) return;
                try
                {
                    if (replacing != null)
                    {
                        var path = dialog.FileNames[0];
                        queue.ReplaceFile(replacing, path, new System.IO.FileInfo(path).Length);
                    }
                    else
                    {
                        foreach (var path in dialog.FileNames)
                            queue.AddFile(path, new System.IO.FileInfo(path).Length, contextEditor.Read());
                    }
                    hadInput = true;
                    SaveDraft();
                }
                catch (Exception error) { Status(ClientReleasePublishQueue.Describe(error), true); }
            }
            finally
            {
                choosing = false;
                UpdateControls();
            }
        }

        private void AddStoreRow()
        {
            if (!ready || retired || queue.Busy) return;
            try
            {
                var metadata = contextEditor.Read();
                var error = metadata.ValidationError();
                if (error != null && error != "请填写该平台的官方商店链接。") { Status(error, true); return; }
                queue.AddStore(metadata);
                hadInput = true;
                SaveDraft();
            }
            catch (Exception error) { Status(ClientReleasePublishQueue.Describe(error), true); }
        }

        private async System.Threading.Tasks.Task RunQueueAsync()
        {
            if (!ready || retired || queue.Busy || choosing || queue.Items.Count == 0) return;
            Status(null, false);
            await queue.RunAsync(lifetime.Token);
            if (queue.Error != null) Status(queue.Error, true);
        }

        private async System.Threading.Tasks.Task ReloadLedgerAsync()
        {
            if (!ready || retired) return;
            try { await queue.LoadAsync(lifetime.Token); }
            catch (Exception) { Status("发布记录刷新未完成，请稍后重试。", true); }
        }

        private bool ConfirmLeave()
        {
            if (exitAllowed) return true;
            if (queue != null && (queue.Busy || choosing))
            {
                Status("正在完成当前文件或提交状态，请稍候再离开。", true);
                return false;
            }
            if (queue == null || (!hadInput && queue.Items.Count == 0)) return true;
            if (retired) return SaveDraft();
            var hasUnknown = queue.HasUnknown;
            var owner = Window.GetWindow(this);
            var dialog = new PromptDialog(owner, hasUnknown ? "保留原发布记录后离开？" : "保存发布队列？", 480);
            dialog.Add(new TextBlock
            {
                Text = hasUnknown
                    ? "待核对项目不能丢弃或换编号重发。离开前将保留原目标、原编号和阶段；文件需要重新选择。"
                    : "可保存当前目标、版本与队列进度。草稿不包含文件内容、路径或认证材料。",
                TextWrapping = TextWrapping.Wrap
            });
            var save = false;
            if (storageError)
            {
                var storageNote = new TextBlock { Text = "原元数据尚未保全，请恢复本机存储后重试。", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };
                storageNote.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Error");
                dialog.Add(storageNote);
            }
            dialog.AddAction(hasUnknown ? "保存原记录并离开" : "保存草稿", delegate { save = true; dialog.Close(); }, true);
            if (!hasUnknown) dialog.AddAction("不保存", delegate { dialog.Close(); });
            dialog.AddAction("留在本页", delegate { dialog.Close(); });
            dialog.ShowDialog();
            if (!save && hasUnknown) return false;
            if (save)
            {
                if (!SaveDraft()) return false;
                exitAllowed = true;
                return true;
            }
            try
            {
                discarding = true;
                debounce.Stop();
                lease.Discard(delegate { return !retired && !queue.HasUnknown; });
                discarded = true;
                exitAllowed = true;
                return true;
            }
            catch (Exception error)
            {
                Status(error.Message, true);
                return false;
            }
            finally { discarding = false; }
        }

        private sealed class QueueRow
        {
            public Border Card;
            public TextBlock Title;
            public TextBlock Target;
            public TextBlock Stage;
            public TextBlock Error;
            public ProgressBar Progress;
            public Button Edit;
            public Button Replace;
            public Button Reconcile;
            public Button Remove;
        }

        private void RebuildRows()
        {
            if (queue == null) return;
            var liveIds = new HashSet<string>(queue.Items.Select(item => item.LocalId), StringComparer.Ordinal);
            foreach (var stale in rowControls.Keys.Where(id => !liveIds.Contains(id)).ToList())
            {
                queueRows.Children.Remove(rowControls[stale].Card);
                rowControls.Remove(stale);
            }
            foreach (var item in queue.Items)
            {
                QueueRow row;
                if (!rowControls.TryGetValue(item.LocalId, out row))
                {
                    row = BuildRow(item);
                    rowControls.Add(item.LocalId, row);
                    queueRows.Children.Add(row.Card);
                }
                UpdateRow(item, row);
            }
            if (queue.Items.Count == 0)
            {
                var empty = new TextBlock
                {
                    Text = "把同一版本的文件集中在这里。Windows 选择 Setup.exe 和更新 ZIP；请核对每项版本和适用设备，系统会校验文件内容。",
                    TextWrapping = TextWrapping.Wrap,
                    Opacity = 0.8
                };
                empty.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Muted");
                if (emptyPlaceholder == null) { emptyPlaceholder = empty; queueRows.Children.Add(empty); }
            }
            else if (emptyPlaceholder != null)
            {
                queueRows.Children.Remove(emptyPlaceholder);
                emptyPlaceholder = null;
            }
            queueStatus.Text = queue.Busy
                ? "逐项处理，原编号和结果持续保全…"
                : "已确认 " + queue.ConfirmedCount + " 项；失败与待核对项目保留原记录。";
        }

        private TextBlock emptyPlaceholder;

        private QueueRow BuildRow(ClientReleaseQueueItem item)
        {
            var row = new QueueRow();
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var left = new StackPanel();
            row.Title = new TextBlock { TextWrapping = TextWrapping.Wrap, FontWeight = FontWeights.SemiBold };
            row.Target = new TextBlock { TextWrapping = TextWrapping.Wrap };
            row.Target.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Muted");
            row.Stage = new TextBlock { Margin = new Thickness(0, 4, 0, 0) };
            row.Error = new TextBlock { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed, Margin = new Thickness(0, 4, 0, 0) };
            row.Error.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Error");
            row.Progress = new ProgressBar { Minimum = 0, Maximum = 1, Height = 6, Visibility = Visibility.Collapsed, Margin = new Thickness(0, 4, 0, 0) };
            left.Children.Add(row.Title);
            left.Children.Add(row.Target);
            left.Children.Add(row.Stage);
            left.Children.Add(row.Progress);
            left.Children.Add(row.Error);
            Grid.SetColumn(left, 0);
            grid.Children.Add(left);
            var actions = new StackPanel { Margin = new Thickness(Space("S12"), 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            row.Edit = RowButton("编辑", delegate { EditRow(item); });
            row.Replace = RowButton("重选文件", delegate { PickFiles(false, item); });
            row.Reconcile = RowButton("核对原状态", async delegate { await queue.ReconcileAsync(item, lifetime.Token); });
            row.Remove = RowButton("移除", delegate { queue.Remove(item); });
            actions.Children.Add(row.Edit);
            actions.Children.Add(row.Replace);
            actions.Children.Add(row.Reconcile);
            actions.Children.Add(row.Remove);
            Grid.SetColumn(actions, 1);
            grid.Children.Add(actions);
            row.Card = WrapCard(grid);
            row.Card.Padding = new Thickness(Space("S12"));
            row.Card.Margin = new Thickness(0, 0, 0, Space("S8"));
            return row;
        }

        private Button RowButton(string text, Action action)
        {
            var button = new Button { Content = text, Margin = new Thickness(0, 0, 0, 4), MinWidth = 88 };
            button.SetResourceReference(MinHeightProperty, "Uten.Height.Compact");
            button.Click += delegate { action(); };
            return button;
        }

        private Button RowButton(string text, Func<System.Threading.Tasks.Task> action)
        {
            var button = new Button { Content = text, Margin = new Thickness(0, 0, 0, 4), MinWidth = 88 };
            button.SetResourceReference(MinHeightProperty, "Uten.Height.Compact");
            button.Click += async delegate { await action(); };
            return button;
        }

        private void UpdateRow(ClientReleaseQueueItem item, QueueRow row)
        {
            row.Title.Text = item.Metadata.IsStore ? "官方商店链接" : (item.FileName ?? "未选择文件");
            row.Target.Text = ClientReleaseTargetEditor.TargetLabel(item.Metadata.Platform, item.Metadata.RuntimeFamily ?? "flutter", item.Metadata.Architecture)
                + " · " + (item.Metadata.Version ?? "") + " + " + (item.Metadata.BuildNumber ?? "")
                + " · " + (item.Metadata.PackageKind == "installer" ? "安装包" : "更新包");
            row.Stage.Text = StageLabel(item);
            row.Error.Text = item.Error;
            row.Error.Visibility = String.IsNullOrEmpty(item.Error) ? Visibility.Collapsed : Visibility.Visible;
            row.Progress.Visibility = item.Stage == ClientReleaseQueueStage.Uploading ? Visibility.Visible : Visibility.Collapsed;
            row.Progress.Value = item.Progress;
            var busy = queue.Busy;
            row.Edit.Visibility = item.Frozen ? Visibility.Collapsed : Visibility.Visible;
            row.Edit.IsEnabled = !busy;
            row.Replace.Visibility = item.NeedsFile || !item.Frozen ? Visibility.Visible : Visibility.Collapsed;
            row.Replace.IsEnabled = !busy && !item.Uncertain;
            row.Reconcile.Visibility = item.RequestId != null && !item.Terminal ? Visibility.Visible : Visibility.Collapsed;
            row.Reconcile.IsEnabled = !busy;
            row.Remove.Visibility = !item.Frozen || item.Stage == ClientReleaseQueueStage.Rejected || item.Stage == ClientReleaseQueueStage.Withdrawn
                ? Visibility.Visible : Visibility.Collapsed;
            row.Remove.IsEnabled = !busy && !item.Uncertain && !item.Published;
        }

        private static string StageLabel(ClientReleaseQueueItem item)
        {
            if (item.PublishedRelease != null && item.PublishedRelease.State == "WITHDRAWN") return "已撤回";
            if (item.RetentionPending) return "已发布，待保留检查";
            switch (item.Stage)
            {
                case ClientReleaseQueueStage.NeedsFile: return "请重选原文件";
                case ClientReleaseQueueStage.Ready: return "待校验";
                case ClientReleaseQueueStage.Validating: return "读取与校验";
                case ClientReleaseQueueStage.Prepared: return "已准备草稿";
                case ClientReleaseQueueStage.Uploading: return "正在上传";
                case ClientReleaseQueueStage.Uploaded: return "文件已确认";
                case ClientReleaseQueueStage.Publishing: return "正在发布";
                case ClientReleaseQueueStage.Published: return "已确认发布";
                case ClientReleaseQueueStage.Withdrawn: return "已撤回";
                case ClientReleaseQueueStage.Rejected: return "未完成";
                default: return "结果待核对";
            }
        }

        private void EditRow(ClientReleaseQueueItem item)
        {
            if (queue.Busy || item.Frozen) return;
            var dialog = new PromptDialog(Window.GetWindow(this), "核对发布目标", 520);
            var editor = new ClientReleaseTargetEditor();
            editor.Bind(item.Metadata);
            dialog.Add(editor.Root);
            var notes = new TextBox { MinHeight = 56, TextWrapping = TextWrapping.Wrap, AcceptsReturn = true, Text = item.Metadata.ReleaseNotes ?? "" };
            var notesLabel = new TextBlock { Text = "发布说明", Margin = new Thickness(0, 8, 0, 4) };
            dialog.Add(notesLabel);
            dialog.Add(notes);
            dialog.AddAction("保存目标", delegate
            {
                var metadata = editor.Read();
                metadata.ReleaseNotes = notes.Text;
                queue.Edit(item, metadata);
                hadInput = true;
                SaveDraft();
                dialog.Close();
            }, true);
            dialog.AddAction("取消", dialog.Close);
            dialog.ShowDialog();
        }

        private void RebuildLedger()
        {
            if (queue == null) return;
            ledgerRows.Children.Clear();
            if (queue.Releases.Count == 0)
            {
                var empty = new TextBlock { Text = "尚无可显示的发布记录。", Opacity = 0.8 };
                empty.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Muted");
                ledgerRows.Children.Add(empty);
                return;
            }
            foreach (var record in queue.Releases)
            {
                var card = new StackPanel();
                var title = new TextBlock { Text = String.IsNullOrEmpty(record.FileName) ? record.Version : record.FileName, TextWrapping = TextWrapping.Wrap, FontWeight = FontWeights.SemiBold };
                card.Children.Add(title);
                var target = new TextBlock
                {
                    Text = ClientReleaseTargetEditor.TargetLabel(record.Platform, record.RuntimeFamily ?? "flutter", record.Architecture)
                        + " · " + record.Version + " + " + record.BuildNumber.ToString(System.Globalization.CultureInfo.InvariantCulture)
                        + " · " + (record.PackageKind == "installer" ? "安装包" : "更新包"),
                    TextWrapping = TextWrapping.Wrap
                };
                target.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Muted");
                card.Children.Add(target);
                var state = new TextBlock { Margin = new Thickness(0, 4, 0, 4) };
                state.Text = LedgerStateLabel(record);
                card.Children.Add(state);
                var actions = new StackPanel { Orientation = Orientation.Horizontal };
                ClientReleaseWithdrawState pending;
                queue.Withdrawals.TryGetValue(record.Id, out pending);
                if (pending == ClientReleaseWithdrawState.Unknown)
                {
                    var reconcile = RowButton("核对原撤回状态", async delegate { await queue.ReconcileWithdrawalAsync(record.Id, lifetime.Token); });
                    actions.Children.Add(reconcile);
                }
                else if (record.State == "PUBLISHED")
                {
                    var withdraw = RowButton("撤回", delegate { ConfirmWithdraw(record); });
                    withdraw.IsEnabled = !queue.Busy;
                    actions.Children.Add(withdraw);
                }
                card.Children.Add(actions);
                ledgerRows.Children.Add(WrapCard(card));
            }
        }

        private static string LedgerStateLabel(ClientReleaseRecord record)
        {
            if (record.State == "PUBLISHED") return "已发布";
            if (record.State == "WITHDRAWN") return "已撤回";
            return "草稿";
        }

        private void ConfirmWithdraw(ClientReleaseRecord record)
        {
            if (queue.Busy || record.State != "PUBLISHED") return;
            var dialog = new PromptDialog(Window.GetWindow(this), "撤回这个版本？", 460);
            dialog.Add(new TextBlock
            {
                Text = "撤回后该文件不再提供下载。已发布的其他组合与原审计记录保留。",
                TextWrapping = TextWrapping.Wrap
            });
            dialog.AddAction("确认撤回", async delegate
            {
                dialog.Close();
                await queue.WithdrawAsync(record, lifetime.Token);
            }, true);
            dialog.AddAction("取消", dialog.Close);
            dialog.ShowDialog();
        }

        private void UpdateSummary()
        {
            if (queue == null) return;
            var groups = ClientReleaseAdminContract.BuildPairGroups(queue.Releases, queue.Items);
            if (groups.Count == 0)
            {
                pairSummary.Text = "当前尚无已确认的 Windows 完整组。";
            }
            else
            {
                var lines = new List<string>();
                foreach (var group in groups)
                {
                    var sample = group.Records[0];
                    lines.Add(ClientReleaseTargetEditor.TargetLabel("windows", sample.RuntimeFamily ?? "flutter", sample.Architecture)
                        + " · " + sample.Version + " · 构建 " + sample.BuildNumber.ToString(System.Globalization.CultureInfo.InvariantCulture)
                        + " — " + (group.Complete ? "Setup + ZIP 已齐" : "等待另一份配对文件"));
                }
                pairSummary.Text = String.Join(Environment.NewLine, lines.ToArray());
            }
            countSummary.Text = "已确认 " + queue.ConfirmedCount + " / 已撤回 " + queue.WithdrawnCount
                + " / 待核对 " + queue.UncertainCount + " / 其余 " + queue.RemainingCount;
        }

        private void UpdateControls()
        {
            var enabled = ready && !retired && queue != null && !queue.Busy && !choosing;
            addFile.IsEnabled = enabled;
            addMany.IsEnabled = enabled;
            var storeVisible = ready && (contextEditor.Read().Platform == "ios" || contextEditor.Read().Platform == "macos");
            addStore.Visibility = storeVisible ? Visibility.Visible : Visibility.Collapsed;
            addStore.IsEnabled = enabled;
            refreshLedger.IsEnabled = enabled;
            saveDraft.IsEnabled = ready && !retired && !discarding;
            run.IsEnabled = enabled && queue != null && queue.Items.Count > 0;
            run.Content = queue != null && queue.Busy ? "正在处理" : "上传并发布";
            queueStatus.Text = queue != null && queue.Busy
                ? "逐项处理，原编号和结果持续保全…"
                : queue != null ? "已确认 " + queue.ConfirmedCount + " 项；失败与待核对项目保留原记录。" : "";
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            debounce.Stop();
            lifetime.Cancel();
            session.SessionChanged -= OnSessionChanged;
            if (!discarded && queue != null && (hadInput || queue.Items.Count > 0)) SaveDraft();
            if (queue != null) queue.Retire();
            lifetime.Dispose();
        }
    }
}
