using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using Uten.Legacy.Core;
using Uten.Legacy.Desktop.Controls;

namespace Uten.Legacy.Desktop.Features.Units
{
    /// <summary>Daily fields and raw/presence restoration only. Durable submission, retirement,
    /// cancellation and closing use the same public lifecycle as all native draft dialogs.</summary>
    public sealed class UnitEditorWindow : DurableDraftDialog
    {
        private readonly UnitReadSnapshot<UnitRecord> baseline;
        private readonly MutationAction action;
        private readonly TextBox code = new TextBox();
        private readonly TextBox name = new TextBox();
        private readonly ComboBox status = new ComboBox();
        private readonly StackPanel fields = new StackPanel();
        private readonly string restoredBody;
        private readonly Dictionary<string, object> restoredFields;
        private readonly HashSet<string> editedFields = new HashSet<string>(StringComparer.Ordinal);

        public UnitEditorWindow(Window parent, SessionCoordinator session, UnitService service,
            UnitReadSnapshot<UnitRecord> baseline, MutationAction action, BusinessDraft restoredDraft = null)
            : base(parent, session, action == MutationAction.UnitCreate ? "新增单位" : action == MutationAction.UnitStatus ? "更改单位状态" : "编辑单位",
                action, baseline?.Value.Id, action == MutationAction.UnitUpdate ? baseline?.Value.Status : null, restoredDraft)
        {
            if (service == null) throw new ArgumentNullException(nameof(service));
            this.baseline = baseline; this.action = action;
            if (action != MutationAction.UnitCreate && action != MutationAction.UnitUpdate && action != MutationAction.UnitStatus)
                throw new ArgumentException("Unsupported daily unit action.", nameof(action));
            if (action != MutationAction.UnitCreate && (baseline == null || !baseline.IsCurrent(session)))
                throw new ApiException("READ_SCOPE_CHANGED", "单位详情已过期，请重新读取。");
            if (session.CurrentUser?.HasPermission("unit:view") != true || baseline != null && !baseline.Owner.Matches(DraftOwner))
                throw new ApiException("READ_SCOPE_CHANGED", "单位页面的账号或读取范围已变化，请重新打开资料。");
            code.Text = baseline?.Value.Code ?? ""; name.Text = baseline?.Value.Name ?? "";
            status.ItemsSource = new[] { "使用", "禁用" }; status.SelectedItem = baseline?.Value.Status ?? "使用";
            if (action != MutationAction.UnitStatus)
            {
                Field("单位编号", code); code.ToolTip = "留空自动生成"; Field("单位名称", name);
            }
            Field("状态", status); Body.Children.Add(fields);
            if (action == MutationAction.UnitStatus)
                Body.Children.Insert(0, new TextBlock { Text = (baseline.Value.Code ?? "—") + " · " + (baseline.Value.Name ?? "—"),
                    TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, Space("S12")) });
            string initial = BuildCurrentBody();
            if (restoredDraft != null)
            {
                restoredBody = restoredDraft.BodyJson; restoredFields = UnitJson.Object(UnitJson.Parse(restoredBody));
                code.Text = UnitJson.Text(restoredFields, "code") ?? ""; name.Text = UnitJson.Text(restoredFields, "name") ?? "";
                status.SelectedItem = UnitJson.Text(restoredFields, "status");
            }
            code.TextChanged += (sender, args) => Changed("code"); name.TextChanged += (sender, args) => Changed("name");
            status.SelectionChanged += (sender, args) => Changed("status");
            Loaded += (sender, args) => { if (action == MutationAction.UnitStatus) status.Focus(); else name.Focus(); };
            InitializeDraftUi(action == MutationAction.UnitCreate ? "新增" : "保存", initial);
        }
        private void Field(string title, Control input)
        {
            System.Windows.Automation.AutomationProperties.SetName(input, title);
            fields.Children.Add(new TextBlock { Text = title, Margin = new Thickness(0, Space("S12"), 0, Space("S6")) });
            fields.Children.Add(input);
        }
        private void Changed(string field)
        {
            if (restoredFields != null) editedFields.Add(field);
            MarkDraftChanged();
        }
        protected override string BuildCurrentBody()
        {
            if (restoredFields != null)
            {
                if (editedFields.Count == 0) return restoredBody;
                var updated = new Dictionary<string, object>(restoredFields, StringComparer.Ordinal);
                foreach (string key in editedFields) updated[key] = key == "code" ? code.Text : key == "name" ? name.Text : status.SelectedItem as string;
                return new JavaScriptSerializer().Serialize(updated);
            }
            return action == MutationAction.UnitStatus
                ? new JavaScriptSerializer().Serialize(new Dictionary<string, object> { ["status"] = status.SelectedItem as string })
                : UnitSaveInput.Daily(name.Text, code.Text, status.SelectedItem as string).ToJson();
        }
        protected override bool CanSubmitBody
        { get { return (action == MutationAction.UnitStatus || !String.IsNullOrWhiteSpace(name.Text)) && (status.SelectedItem as string == "使用" || status.SelectedItem as string == "禁用"); } }
        protected override void SetEditorEnabled(bool enabled)
        { fields.IsEnabled = enabled; status.IsEnabled = enabled && Session.CurrentUser?.HasPermission("unit:status") == true; }
        protected override Task BeforeSubmitAsync(CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            if (baseline != null && (!baseline.IsCurrent(Session) || !baseline.Owner.Matches(DraftOwner)))
                throw new ApiException("READ_SCOPE_CHANGED", "原编辑详情的读取范围已变化，请重新核对原输入。");
            return Task.CompletedTask;
        }
    }
}
