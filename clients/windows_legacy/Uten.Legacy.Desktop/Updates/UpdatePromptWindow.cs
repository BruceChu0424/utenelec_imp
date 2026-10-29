using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Uten.Legacy.Desktop.Controls;
using Uten.Legacy.Desktop.Features.Downloads;

namespace Uten.Legacy.Desktop.Updates
{
    public sealed class UpdatePromptWindow : Window
    {
        private readonly NativeWindowFrame frame = new NativeWindowFrame();
        public UpdatePromptWindow(Window owner, ClientPackageDescriptor release)
        {
            Owner = owner; Title = "软件更新"; Width = Math.Min(480, SystemParameters.WorkArea.Width);
            MaxHeight = SystemParameters.WorkArea.Height; SizeToContent = SizeToContent.Height;
            WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; ShowInTaskbar = false;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            var stack = new StackPanel { Margin = (Thickness)FindResource("Uten.Padding.S24") };
            var header = new DockPanel();
            var close = new Button { Content = "×", Style = (Style)FindResource("Uten.CaptionButton"), Background = (Brush)FindResource("Uten.Caption.Close"), IsCancel = true };
            DockPanel.SetDock(close, Dock.Right); close.Click += (sender, args) => DialogResult = false; header.Children.Add(close);
            header.Children.Add(new TextBlock { Text = "发现新版本", Style = (Style)FindResource("Uten.PageTitle"), VerticalAlignment = VerticalAlignment.Center });
            stack.Children.Add(header);
            stack.Children.Add(new TextBlock { Text = release.Version + "（" + release.BuildNumber + "）", Margin = new Thickness(0, Space("S16"), 0, Space("S8")), FontWeight = FontWeights.SemiBold });
            stack.Children.Add(new TextBlock { Text = "下载和校验完成后，软件将正常关闭并安装更新。请先完成当前操作。", Foreground = (Brush)FindResource("Uten.Muted") });
            if (!string.IsNullOrWhiteSpace(release.ReleaseNotes))
                stack.Children.Add(new ScrollViewer { Content = new TextBlock { Text = release.ReleaseNotes }, MaxHeight = 240, Margin = new Thickness(0, Space("S16"), 0, 0), VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
            var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, Space("S24"), 0, 0) };
            var cancel = new Button { Content = "稍后", IsCancel = true, Margin = new Thickness(0, 0, Space("S8"), 0) };
            var confirm = new Button { Content = "下载并更新", IsDefault = true, Style = (Style)FindResource("Uten.PrimaryButton") };
            cancel.Click += (sender, args) => DialogResult = false; confirm.Click += (sender, args) => DialogResult = true;
            actions.Children.Add(cancel); actions.Children.Add(confirm); stack.Children.Add(actions);
            Content = new RoundedSurface { Child = stack, Background = (Brush)FindResource("Uten.Surface"), BorderBrush = (Brush)FindResource("Uten.Border"), BorderThickness = new Thickness(1), CornerRadius = (CornerRadius)FindResource("Uten.Radius.Dialog") };
            SourceInitialized += (sender, args) => UpdateFrame(); SizeChanged += (sender, args) => UpdateFrame();
        }
        private double Space(string name) { return (double)FindResource("Uten.Space." + name); }
        private void UpdateFrame() { frame.Update(this, true, (double)FindResource("Uten.Radius.DialogValue")); }
    }
}
