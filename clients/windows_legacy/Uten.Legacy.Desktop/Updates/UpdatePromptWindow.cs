using System;
using System.Windows;
using System.Windows.Controls;
using Uten.Legacy.Desktop.Controls;
using Uten.Legacy.Desktop.Features.Downloads;

namespace Uten.Legacy.Desktop.Updates
{
    public sealed class UpdatePromptWindow : UtenDialogWindow
    {
        public UpdatePromptWindow(Window owner, ClientPackageDescriptor release) : base(owner, "发现新版本", 480)
        {
            Body.Children.Add(new TextBlock { Text = release.Version + "（" + release.BuildNumber + "）", FontWeight = FontWeights.SemiBold });
            var explanation = new TextBlock { Text = "下载和校验完成后，软件将正常关闭并安装更新。请先完成当前操作。",
                TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, Space("S8"), 0, 0) };
            explanation.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Muted"); Body.Children.Add(explanation);
            if (!string.IsNullOrWhiteSpace(release.ReleaseNotes))
                Body.Children.Add(new TextBlock { Text = release.ReleaseNotes, TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(0, Space("S16"), 0, 0) });
            ActionButton("稍后", () => DialogResult = false).IsCancel = true;
            ActionButton("下载并更新", () => DialogResult = true, primary: true).IsDefault = true;
        }
    }
}
