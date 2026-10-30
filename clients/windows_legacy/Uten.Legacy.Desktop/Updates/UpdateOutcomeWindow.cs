using System;
using System.Windows;
using System.Windows.Controls;
using Uten.Legacy.Desktop.Controls;

namespace Uten.Legacy.Desktop.Updates
{
    /// <summary>Startup surface for a finished or interrupted update job (W7-UPD-009).
    /// States stay in words, not colors alone; the recovery directory is shown verbatim.</summary>
    public sealed class UpdateOutcomeWindow : UtenDialogWindow
    {
        public UpdateOutcomeWindow(Window owner, StartupUpdateOutcome outcome) : base(owner, "更新结果", 520)
        {
            if (outcome == null) throw new ArgumentNullException(nameof(outcome));
            var heading = new TextBlock { Text = outcome.State == "succeeded" ? "更新已完成" : "更新未完成或被中断",
                FontWeight = FontWeights.SemiBold };
            Body.Children.Add(heading);
            var detail = new TextBlock { Text = outcome.DisplayText(), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, Space("S8"), 0, 0) };
            detail.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Muted"); Body.Children.Add(detail);
            ActionButton("知道了", () => DialogResult = true, primary: true).IsDefault = true;
        }
    }
}
