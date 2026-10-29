using System;
using System.ComponentModel;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Controls;

namespace Uten.Legacy.Desktop.Features.Units
{
    /// <summary>User-authored local annotation only. It never changes Unknown to success,
    /// authorizes business replay, or reads data using a retired preservation lease.</summary>
    public sealed class UnitReviewNoteWindow : UtenDialogWindow
    {
        private readonly SessionCoordinator session;
        private readonly MutationReviewLease lease;
        private readonly UnitReadOwner owner;
        private readonly TextBox note = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 180,
            MaxLength = 2000, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        private readonly Button save, discard;
        private bool ended, preserving, allowedClose, retired;
        public bool NoteRecorded { get; private set; }
        public UnitReviewNoteWindow(Window parent, SessionCoordinator session, MutationReviewLease lease, MutationOwnerSnapshot openedOwner)
            : base(parent, "追加人工核对说明", 640)
        {
            this.session = session ?? throw new ArgumentNullException(nameof(session)); this.lease = lease ?? throw new ArgumentNullException(nameof(lease));
            owner = new UnitReadOwner(session);
            if (!owner.Matches(openedOwner)) throw new ApiException("READ_SCOPE_CHANGED", "核对说明的原账号或读取范围已变化，未打开编辑。");
            Body.Children.Add(new TextBlock { Text = "请记录你核对的记录编号、时间和处理情况。此说明保存在原账号的本机记录中，不会改变原提交结果，也不会重新发送操作。",
                TextWrapping = TextWrapping.Wrap });
            note.Margin = new Thickness(0, Space("S12"), 0, 0);
            System.Windows.Automation.AutomationProperties.SetName(note, "核对说明");
            Body.Children.Add(note);
            discard = ActionButton("放弃本次未保存说明", () => { if (!preserving) { allowedClose = true; Close(); } });
            save = ActionButton("保存说明", () => { _ = PreserveAndCloseAsync(); }, primary: true);
            session.SessionChanged += OnOwnerChanged; session.ReadScopeChanged += OnOwnerChanged;
            (parent as IPendingEditHost)?.TrackPendingEditor(this);
            if (!owner.IsCurrent(session)) OnOwnerChanged(this, EventArgs.Empty);
        }
        private async Task PreserveAndCloseAsync()
        {
            if (ended || preserving) return;
            preserving = true; note.IsEnabled = false; save.IsEnabled = discard.IsEnabled = CloseButton.IsEnabled = false;
            string original = note.Text;
            try
            {
                if (!String.IsNullOrWhiteSpace(original))
                {
                    await session.AppendMutationReviewNoteAsync(lease, original, CancellationToken.None);
                    NoteRecorded = true;
                }
                allowedClose = true; Close();
            }
            catch (Exception)
            { ShowStatus("核对说明未能保存在本机，原输入仍保留。请恢复存储后重试，或明确放弃本次未保存说明。", true); }
            finally
            {
                preserving = false;
                if (!ended)
                { note.IsEnabled = !retired; save.IsEnabled = discard.IsEnabled = CloseButton.IsEnabled = true; }
            }
        }
        private void OnOwnerChanged(object sender, EventArgs args)
        {
            if (ended) return;
            Dispatcher.BeginInvoke(new Action(() =>
            {
                if (ended || owner.IsCurrent(session)) return;
                retired = true; Body.Visibility = Visibility.Collapsed;
                _ = PreserveAndCloseAsync();
            }));
        }
        protected override void OnClosing(CancelEventArgs args)
        {
            base.OnClosing(args);
            if (args.Cancel || ended || allowedClose) return;
            args.Cancel = true;
            if (!preserving) Dispatcher.BeginInvoke(new Action(() => { if (!ended) _ = PreserveAndCloseAsync(); }));
        }
        protected override void OnClosed(EventArgs args)
        {
            ended = true; note.Clear();
            session.SessionChanged -= OnOwnerChanged; session.ReadScopeChanged -= OnOwnerChanged; base.OnClosed(args);
        }
    }
}
