using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Uten.Legacy.Core;

namespace Uten.Legacy.Desktop.Controls
{
    /// <summary>Shared password re-authentication dialog for sensitive actions. The attempt
    /// callback performs the real step-up exchange; a wrong password keeps the dialog open with
    /// the server's own message, and cancelling returns null without touching any grant.</summary>
    public sealed class StepUpPasswordDialog : UtenDialogWindow
    {
        private readonly Func<string, CancellationToken, Task<string>> attempt;
        private readonly PasswordBox password = new PasswordBox();
        private string granted;
        private bool attempting;

        private StepUpPasswordDialog(Window owner, string actionTitle,
            Func<string, CancellationToken, Task<string>> attempt) : base(owner, "身份确认", 420)
        {
            this.attempt = attempt ?? throw new ArgumentNullException("attempt");
            Body.Children.Add(new TextBlock
            {
                Text = "「" + (actionTitle ?? "敏感操作") + "」需要重新输入登录密码确认。密码只用于本次确认，不会被保存。",
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 12)
            });
            password.SetResourceReference(MinHeightProperty, "Uten.Height.Standard");
            password.KeyDown += async (sender, args) =>
            {
                if (args.Key == System.Windows.Input.Key.Enter) await TryConfirm();
            };
            Body.Children.Add(password);
            ActionButton("确认", async delegate { await TryConfirm(); }, true);
            ActionButton("取消", Close);
            Loaded += (sender, args) => password.Focus();
        }

        private async Task TryConfirm()
        {
            if (attempting) return;
            if (password.SecurePassword == null || password.SecurePassword.Length == 0)
            { ShowStatus("请输入登录密码。", true); return; }
            attempting = true;
            try
            {
                var token = await attempt(password.Password, CancellationToken.None);
                granted = token;
                Close();
            }
            catch (ApiException error)
            {
                ShowStatus(error.UserMessage, true);
                password.Clear();
                password.Focus();
            }
            catch (Exception)
            { ShowStatus("身份确认暂未完成，请稍后重试。", true); }
            finally { attempting = false; }
        }

        /// <summary>Shows the dialog and returns the granted one-shot step-up token, or null
        /// when the user cancelled. Wrong passwords retry inside the dialog.</summary>
        public static string Request(Window owner, string actionTitle, SessionCoordinator session)
        {
            if (session == null) throw new ArgumentNullException("session");
            var dialog = new StepUpPasswordDialog(owner, actionTitle, async (password, cancellation) =>
            {
                var grant = await session.StepUpAsync(password, cancellation);
                return grant.StepUpToken;
            });
            dialog.ShowDialog();
            return dialog.granted;
        }
    }
}
