using System;
using System.ComponentModel;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Controls;

namespace Uten.Legacy.Desktop.Features.Units
{
    /// <summary>The real page table editor. Its separate owned window is only a
    /// preservation guard, never a modal surrogate for these inline fields.</summary>
    public sealed class UnitInlineWorkspace : UserControl, IDisposable
    {
        private readonly Window parent;
        private readonly SessionCoordinator session;
        private readonly UnitInlineWorkspaceModel model;
        private readonly InlinePreservationGuard guard;
        private readonly DispatcherTimer debounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        private readonly DataGrid table = new DataGrid { IsReadOnly = false, CanUserAddRows = false,
            AutoGenerateColumns = false, CanUserSortColumns = false, SelectionMode = DataGridSelectionMode.Single };
        private readonly TextBlock status = new TextBlock { TextWrapping = TextWrapping.Wrap };
        private readonly StackPanel review = new StackPanel();
        private readonly TextBlock reviewText = new TextBlock { TextWrapping = TextWrapping.Wrap };
        private readonly Button acknowledge = new Button { Content = "已核对原值，继续编辑" };
        private readonly Button save = new Button(), keep = new Button { Content = "保存草稿并返回" },
            discard = new Button { Content = "取消编辑" }, add = new Button { Content = "新增单位" };
        private bool preserving, closeRequested, ended, disposed;
        public event EventHandler Finished;
        public bool BusinessChanged { get { return model.BusinessChanged; } }
        public bool CanLeave { get { return ended; } }
        public bool OwnerRetired { get { return model.IsRetired; } }
        public UnitInlineWorkspaceModel Model { get { return model; } }

        public UnitInlineWorkspace(Window parent, SessionCoordinator session,
            System.Collections.Generic.IReadOnlyList<UnitRecord> currentRows, UnitReadOwner owner, BusinessDraft restoredDraft = null)
        {
            this.parent = parent ?? throw new ArgumentNullException(nameof(parent));
            this.session = session ?? throw new ArgumentNullException(nameof(session));
            if (!(parent is IPendingEditHost)) throw new ArgumentException("行内编辑需要支持本机保全保护的父窗口。", nameof(parent));
            model = new UnitInlineWorkspaceModel(session, currentRows, owner, restoredDraft);
            SetResourceReference(StyleProperty, "Uten.Workspace");
            var layout = new DockPanel();
            var toolbar = new WrapPanel { Margin = new Thickness(0, 0, 0, Space("S12")) };
            save.SetResourceReference(StyleProperty, "Uten.PrimaryButton");
            foreach (var button in new[] { save, keep, discard, add })
            { button.Margin = new Thickness(0, 0, Space("S8"), Space("S4")); toolbar.Children.Add(button); }
            DockPanel.SetDock(toolbar, Dock.Top); layout.Children.Add(toolbar);
            reviewText.Text = model.RestoredReviewSummary ?? "";
            review.Children.Add(new ScrollViewer { Content = reviewText, MaxHeight = Math.Max(80, SystemParameters.WorkArea.Height / 4),
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
            acknowledge.HorizontalAlignment = HorizontalAlignment.Left;
            acknowledge.Margin = new Thickness(0, Space("S8"), 0, Space("S12"));
            review.Children.Add(acknowledge);
            DockPanel.SetDock(review, Dock.Top); layout.Children.Add(review);
            status.Margin = new Thickness(0, Space("S8"), 0, 0); status.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Muted");
            DockPanel.SetDock(status, Dock.Bottom); layout.Children.Add(status);
            table.Columns.Add(Editor("单位编号", nameof(UnitInlineRow.Code), 140));
            table.Columns.Add(Editor("单位名称", nameof(UnitInlineRow.Name), 220, true));
            table.Columns.Add(StatusColumn());
            table.Columns.Add(new DataGridTextColumn { Header = "保存结果", IsReadOnly = true, Binding = new Binding(nameof(UnitInlineRow.Message)),
                Width = new DataGridLength(220), MinWidth = 160 });
            table.ItemsSource = model.Rows;
            var cells = new Style(typeof(DataGridCell), (Style)FindResource(typeof(DataGridCell)));
            cells.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
            table.CellStyle = cells;
            layout.Children.Add(UtenSurfaces.Wrap(table, UtenSurfaceRole.Table));
            Content = layout;
            guard = new InlinePreservationGuard(parent, () => { _ = PreserveAndFinishAsync(); });
            (parent as IPendingEditHost)?.TrackPendingEditor(guard);
            model.StateChanged += OnStateChanged;
            model.InputEdited += OnInputEdited;
            session.SessionChanged += OnOwnerChanged; session.ReadScopeChanged += OnOwnerChanged;
            debounce.Tick += async (sender, args) =>
            {
                debounce.Stop();
                try { await model.FlushDraftsAsync(); }
                catch (Exception) { if (!ended) status.Text = "本机草稿暂未保存，原输入仍保留；请检查存储后重试。"; }
            };
            save.Click += async (sender, args) => { if (await SaveAllAsync()) await PreserveAndFinishAsync(); };
            acknowledge.Click += async (sender, args) =>
            {
                if (!model.RestoredJournalVerified) { await VerifyRestoredDraftAsync(); return; }
                try { model.AcknowledgeRestoredReview(); }
                catch (ApiException error) { if (model.IsOwnerCurrent) status.Text = error.UserMessage; }
            };
            Loaded += async (sender, args) => { if (model.HasRestoredDraft) await VerifyRestoredDraftAsync(); };
            keep.Click += async (sender, args) => await PreserveAndFinishAsync();
            discard.Click += async (sender, args) =>
            {
                if (!model.IsOwnerCurrent || model.IsBusy || preserving) return;
                var prompt = new InlineDiscardPrompt(parent);
                (parent as IPendingEditHost)?.TrackPendingEditor(prompt);
                if (prompt.ShowDialog() != true || !model.IsOwnerCurrent) return;
                try { await model.DiscardUnsentAndFinishAsync(); if (model.IsFinished) Complete(); }
                catch (Exception) { status.Text = "未能完成本机草稿清理，原输入仍保留，请先保存草稿。"; }
            };
            add.Click += (sender, args) =>
            {
                var row = model.FirstBlankRow();
                if (row == null) return;
                table.SelectedItem = row; table.ScrollIntoView(row);
                table.CurrentCell = new DataGridCellInfo(row, table.Columns[1]); table.Focus();
                Dispatcher.BeginInvoke(DispatcherPriority.Input, new Action(() => FocusName(row)));
            };
            Refresh();
            if (!model.IsOwnerCurrent) RetireOwner();
        }
        private double Space(string name) { return (double)FindResource("Uten.Space." + name); }
        private DataGridTemplateColumn Editor(string label, string property, double width, bool stretch = false)
        {
            var input = new FrameworkElementFactory(typeof(TextBox)) { Name = "InlineEditor" };
            input.SetBinding(TextBox.TextProperty, new Binding(property) { Mode = BindingMode.TwoWay, UpdateSourceTrigger = UpdateSourceTrigger.PropertyChanged });
            input.SetBinding(IsEnabledProperty, new Binding(nameof(UnitInlineRow.CanEdit)));
            if (property == nameof(UnitInlineRow.Code)) input.SetBinding(TextBox.IsReadOnlyProperty, new Binding(nameof(UnitInlineRow.CodeReadOnly)));
            input.SetResourceReference(HeightProperty, "Uten.Height.Cell");
            input.SetResourceReference(MinHeightProperty, "Uten.Height.Cell");
            input.SetResourceReference(Control.FontSizeProperty, "Uten.FontSize.Compact");
            input.SetValue(Control.PaddingProperty, (Thickness)FindResource("Uten.Padding.Filter"));
            input.SetValue(System.Windows.Automation.AutomationProperties.NameProperty, label);
            input.SetValue(ToolTipProperty, property == nameof(UnitInlineRow.Code) ? "新增编号留空由服务器分配" : "单位名称必填");
            input.AddHandler(TextCompositionManager.PreviewTextInputStartEvent, new TextCompositionEventHandler(CompositionStarted));
            input.AddHandler(TextCompositionManager.PreviewTextInputUpdateEvent, new TextCompositionEventHandler(CompositionStarted));
            input.AddHandler(TextCompositionManager.PreviewTextInputEvent, new TextCompositionEventHandler(CompositionCompleted));
            input.AddHandler(LostKeyboardFocusEvent, new KeyboardFocusChangedEventHandler((sender, args) =>
            {
                var editor = sender as FrameworkElement; var row = editor?.DataContext as UnitInlineRow;
                if (row != null) Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => row.SetComposing(false)));
            }));
            var root = new FrameworkElementFactory(typeof(Grid));
            var display = new FrameworkElementFactory(typeof(TextBlock)) { Name = "InlineReadOnly" };
            display.SetBinding(TextBlock.TextProperty, new Binding(property));
            display.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
            display.SetValue(VisibilityProperty, Visibility.Collapsed);
            root.AppendChild(input); root.AppendChild(display);
            var template = new DataTemplate { VisualTree = root };
            var readOnly = new DataTrigger { Binding = new Binding(property == nameof(UnitInlineRow.Code) ? nameof(UnitInlineRow.IsNew) : nameof(UnitInlineRow.SupportsEditing)), Value = false };
            readOnly.Setters.Add(new Setter(VisibilityProperty, Visibility.Collapsed, "InlineEditor"));
            readOnly.Setters.Add(new Setter(VisibilityProperty, Visibility.Visible, "InlineReadOnly"));
            template.Triggers.Add(readOnly);
            return new DataGridTemplateColumn { Header = label, CellTemplate = template, MinWidth = width,
                Width = new DataGridLength(stretch ? 1 : width, stretch ? DataGridLengthUnitType.Star : DataGridLengthUnitType.Pixel) };
        }
        private DataGridTemplateColumn StatusColumn()
        {
            var input = new FrameworkElementFactory(typeof(ComboBox));
            input.SetValue(ItemsControl.ItemsSourceProperty, new[] { "使用", "禁用" });
            input.SetBinding(SelectorSelectedItemProperty(), new Binding(nameof(UnitInlineRow.Status)) { Mode = BindingMode.TwoWay, UpdateSourceTrigger = UpdateSourceTrigger.PropertyChanged });
            input.SetBinding(IsEnabledProperty, new Binding(nameof(UnitInlineRow.CanEditStatus)));
            input.SetResourceReference(HeightProperty, "Uten.Height.Cell"); input.SetResourceReference(MinHeightProperty, "Uten.Height.Cell");
            input.SetResourceReference(Control.FontSizeProperty, "Uten.FontSize.Compact");
            input.SetValue(Control.PaddingProperty, (Thickness)FindResource("Uten.Padding.Filter"));
            input.SetValue(System.Windows.Automation.AutomationProperties.NameProperty, "状态");
            return new DataGridTemplateColumn { Header = "状态", Width = 120, CellTemplate = new DataTemplate { VisualTree = input } };
        }
        private static DependencyProperty SelectorSelectedItemProperty() { return System.Windows.Controls.Primitives.Selector.SelectedItemProperty; }
        private void CompositionStarted(object sender, TextCompositionEventArgs args)
        { ((sender as FrameworkElement)?.DataContext as UnitInlineRow)?.SetComposing(true); }
        private void CompositionCompleted(object sender, TextCompositionEventArgs args)
        {
            var row = (sender as FrameworkElement)?.DataContext as UnitInlineRow;
            if (row != null) Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => row.SetComposing(false)));
        }
        private void FocusName(UnitInlineRow row)
        {
            var container = table.ItemContainerGenerator.ContainerFromItem(row) as DataGridRow;
            if (container == null) return;
            foreach (var input in Descendants<TextBox>(container))
                if (System.Windows.Automation.AutomationProperties.GetName(input) == "单位名称") { input.Focus(); break; }
        }
        private static System.Collections.Generic.IEnumerable<T> Descendants<T>(DependencyObject parent) where T : DependencyObject
        {
            for (int index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
            {
                var child = VisualTreeHelper.GetChild(parent, index);
                if (child is T result) yield return result;
                foreach (var nested in Descendants<T>(child)) yield return nested;
            }
        }
        private void OnInputEdited(object sender, EventArgs args)
        {
            if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(new Action(() => OnInputEdited(sender, args))); return; }
            if (!ended && !preserving && !model.IsRetired) { debounce.Stop(); debounce.Start(); }
        }
        private void OnStateChanged(object sender, EventArgs args)
        {
            if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(new Action(() => OnStateChanged(sender, args))); return; }
            Refresh();
            if (closeRequested && !model.IsBusy && !preserving && !ended)
                Dispatcher.BeginInvoke(new Action(() => { _ = PreserveAndFinishAsync(); }));
        }
        private void Refresh()
        {
            if (!ended && !model.IsRetired && !model.IsOwnerCurrent) { RetireOwner(); return; }
            save.Content = "保存 " + model.PendingRows + " 行修改";
            save.IsEnabled = !preserving && model.CanSave;
            keep.IsEnabled = discard.IsEnabled = !preserving && !model.IsBusy;
            discard.IsEnabled &= model.IsOwnerCurrent;
            add.IsEnabled = !preserving && !model.IsBusy && model.IsOwnerCurrent && session.CurrentUser?.HasPermission("unit:create") == true;
            table.IsEnabled = !preserving;
            review.Visibility = model.HasRestoredDraft && !model.IsRetired ? Visibility.Visible : Visibility.Collapsed;
            acknowledge.Content = model.RestoredJournalVerified ? model.RequiresRestoredReview ? "已核对原值，继续编辑" : "已明确核对原值" : "重试核对原提交记录";
            acknowledge.IsEnabled = !preserving && !model.IsBusy && model.IsOwnerCurrent && !model.HasUnresolved
                && (model.RequiresRestoredReview || !model.RestoredJournalVerified);
            if (model.IsRetired)
            {
                table.Visibility = Visibility.Collapsed;
                status.Text = "账号或读取范围已变化，正在保全原账号的本机草稿。";
            }
            else status.Text = model.HasComposition ? "请完成中文输入后再保存。" : model.Status ?? "既有编号只读；新增编号留空由服务器分配。";
        }
        public Task<bool> SaveAllAsync()
        { return Dispatcher.InvokeAsync(new Func<Task<bool>>(() => { if (model.CanSave) debounce.Stop(); return model.SaveAllAsync(); })).Task.Unwrap(); }
        public Task PreserveAndFinishAsync()
        { return Dispatcher.InvokeAsync(new Func<Task>(PreserveOnDispatcherAsync)).Task.Unwrap(); }
        private async Task PreserveOnDispatcherAsync()
        {
            if (ended || preserving) return;
            closeRequested = true; debounce.Stop();
            if (model.IsBusy) { model.RequestStop(); return; }
            preserving = true; Refresh();
            try
            {
                // Let the final IME/binding event finish before freezing local bodies.
                await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Background);
                await model.PreserveAndFinishAsync(); Complete();
            }
            catch (Exception) { guard.ShowPreservationFailure(); }
            finally { preserving = false; if (!ended) Refresh(); }
        }
        public Task VerifyRestoredDraftAsync()
        {
            return Dispatcher.InvokeAsync(new Func<Task>(async () =>
            {
                bool failed = false;
                try { await model.VerifyRestoredDraftAsync(); }
                catch (Exception) { failed = true; }
                if (!ended) Refresh();
                if (failed && !ended && model.IsOwnerCurrent) status.Text = "原提交记录暂未完整读取，不能重新提交；原草稿仍保留。请重试核对。";
            })).Task.Unwrap();
        }
        private void OnOwnerChanged(object sender, EventArgs args)
        { if (!ended) Dispatcher.BeginInvoke(new Action(() => { if (!ended && !model.IsOwnerCurrent) RetireOwner(); })); }
        public void RetireOwner()
        {
            if (ended) return;
            debounce.Stop(); model.RetireOwner(); table.Visibility = Visibility.Collapsed; Refresh();
            _ = PreserveAndFinishAsync();
        }
        private void Complete()
        {
            if (ended) return;
            ended = true; debounce.Stop();
            session.SessionChanged -= OnOwnerChanged; session.ReadScopeChanged -= OnOwnerChanged;
            model.StateChanged -= OnStateChanged; model.InputEdited -= OnInputEdited;
            guard.Release();
            Finished?.Invoke(this, EventArgs.Empty);
        }
        public void Dispose() { if (disposed) return; disposed = true; RetireOwner(); }

        private sealed class InlinePreservationGuard : UtenDialogWindow
        {
            private readonly Action preserve;
            private bool released;
            internal InlinePreservationGuard(Window owner, Action preserve) : base(owner, "本机草稿保全", 440)
            {
                this.preserve = preserve;
                Body.Children.Add(new TextBlock { Text = "原窗口仍有输入需要保存。请恢复本机存储后重试；不会在新账号下显示或提交原资料。", TextWrapping = TextWrapping.Wrap });
                ActionButton("重试保全并关闭", preserve, true);
            }
            internal void ShowPreservationFailure()
            {
                ShowStatus("本机草稿尚未保存，原输入仍保留。请检查存储空间或访问权限后重试。", true);
                if (!IsVisible) Show();
            }
            internal void Release() { released = true; Close(); }
            protected override void OnClosing(CancelEventArgs args)
            {
                base.OnClosing(args);
                if (released || args.Cancel) return;
                args.Cancel = true; preserve();
            }
        }
        private sealed class InlineDiscardPrompt : UtenDialogWindow
        {
            internal InlineDiscardPrompt(Window owner) : base(owner, "放弃未提交修改？", 440)
            {
                Body.Children.Add(new TextBlock { Text = "放弃当前未提交的修改并返回列表。已确认及待核对的原提交记录仍会保留。", TextWrapping = TextWrapping.Wrap });
                ActionButton("继续编辑", () => { DialogResult = false; });
                ActionButton("放弃未提交修改", () => { DialogResult = true; });
            }
        }
    }
}
