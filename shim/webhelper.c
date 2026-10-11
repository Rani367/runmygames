/*
 * steamwebhelper.exe wrapper for RunMyGames.
 *
 * Steam's browser UI (CEF/Chromium) presents through a GPU swap chain that stays
 * black under Wine on macOS, and Steam does not forward -cef-* switches to the
 * helper. RunMyGames renames Valve's helper to steamwebhelper_real.exe and puts
 * this wrapper in its place; it starts the real helper with Chromium's software
 * rendering switches, so the UI is drawn through plain GDI. Games are unaffected.
 *
 * RunMyGames re-installs the wrapper whenever a Steam update restores the original.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>

#define MAX_CMD 32768

/* The switch set Steam uses under CrossOver: software GPU path in-process, and no
 * Chromium sandbox (its process isolation does not work under Wine, leaving the
 * renderer unable to deliver frames, i.e. a black window). */
static const WCHAR extra[] = L" --disable-gpu --in-process-gpu --no-sandbox";

static const WCHAR *skip_argv0(const WCHAR *cmd)
{
    if (*cmd == L'"')
    {
        cmd++;
        while (*cmd && *cmd != L'"') cmd++;
        if (*cmd) cmd++;
    }
    else
        while (*cmd && *cmd != L' ' && *cmd != L'\t') cmd++;
    return cmd; /* keep the leading space before the arguments */
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, LPWSTR unused, int show)
{
    static WCHAR exe[MAX_PATH], cmdline[MAX_CMD];
    const WCHAR *args = skip_argv0(GetCommandLineW());
    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    DWORD code = 1, len;
    WCHAR *slash;

    len = GetModuleFileNameW(NULL, exe, MAX_PATH);
    if (!len || len >= MAX_PATH || !(slash = wcsrchr(exe, L'\\'))) return 1;
    wcscpy(slash + 1, L"steamwebhelper_real.exe");

    /* Only the top-level browser process needs the switches; Chromium passes the
     * relevant ones on to its renderer/GPU children itself. */
    _snwprintf(cmdline, MAX_CMD, L"\"%ls\"%ls%ls", exe, args, wcsstr(args, L"--type=") ? L"" : extra);
    cmdline[MAX_CMD - 1] = 0;

    GetStartupInfoW(&si);
    if (!CreateProcessW(exe, cmdline, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) return 1;
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)code;
}
