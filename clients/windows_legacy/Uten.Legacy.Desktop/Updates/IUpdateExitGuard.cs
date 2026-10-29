namespace Uten.Legacy.Desktop.Updates
{
    /// <summary>Editable native pages must preserve their drafts before allowing software replacement.</summary>
    public interface IUpdateExitGuard
    {
        bool CanCloseForUpdate { get; }
    }
}
