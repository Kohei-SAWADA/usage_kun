namespace UsageKun.Core;

public enum LoginStartupAction { None, Register, Remove, Relocate }

public static class LoginStartupPolicy
{
    public static LoginStartupAction Decide(bool initialized, bool existingInstallation,
        bool requested, bool registered, bool blocked, bool moved, bool explicitChange = false)
    {
        if (explicitChange) return requested ? LoginStartupAction.Register : LoginStartupAction.Remove;
        if (blocked || !requested) return LoginStartupAction.None;
        if (registered && moved) return LoginStartupAction.Relocate;
        if (!initialized && !existingInstallation && !registered) return LoginStartupAction.Register;
        return LoginStartupAction.None;
    }
}
