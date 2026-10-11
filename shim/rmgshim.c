/*
 * rmgshim.exe — per-game environment injector for RunMyGames.
 *
 * Steam runs every game as:   C:\rmg\rmgshim.exe %command%
 * (RunMyGames writes that launch option into Steam's localconfig.vdf.)
 *
 * The shim reads C:\rmg\games\<SteamAppId>.env, a list of KEY=VALUE lines written
 * by RunMyGames (renderer DLL path, overrides, Metal HUD, MetalFX, ...), applies
 * them to its environment and starts the real game. Each variable is also set as
 * __CX_UNIX_<NAME>, which CrossOver's Wine promotes into the child's Unix
 * environment, so Unix-side settings such as WINEDLLPATH_PREPEND take effect.
 *
 * Special keys:  RMG_ARGS=<extra arguments appended to the game command line>
 *                RMG_EXEC=<exe to run instead of the one Steam starts> together with
 *                RMG_REPLACE=<file name of the exe to replace>, used to skip Unreal's
 *                bootstrap stub (its prerequisite check trips over Wine) and start
 *                *-Shipping.exe directly, exactly what the stub would do.
 * An empty value (KEY=) removes the variable.
 *
 * On exit it writes C:\rmg\games\<appid>.last ("exit=<code> seconds=<n> renderer=<name>")
 * so RunMyGames can switch renderers automatically if a game crashes on start.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

#define MAX_CMD 32768

static WCHAR extra_args[4096], exec_override[MAX_PATH], replace_name[MAX_PATH];

static void log_line(const WCHAR *fmt, const WCHAR *arg)
{
    FILE *f = _wfopen(L"C:\\rmg\\logs\\shim.log", L"a, ccs=UTF-8");
    if (!f) return;
    fwprintf(f, fmt, arg);
    fputwc(L'\n', f);
    fclose(f);
}

static void trim(WCHAR *s)
{
    size_t n = wcslen(s);
    while (n && (s[n - 1] == L'\r' || s[n - 1] == L'\n' || s[n - 1] == L' ' || s[n - 1] == L'\t')) s[--n] = 0;
}

static void apply_env_file(const WCHAR *appid)
{
    WCHAR path[MAX_PATH], line[MAX_CMD];
    FILE *f;

    _snwprintf(path, MAX_PATH, L"C:\\rmg\\games\\%ls.env", appid);
    path[MAX_PATH - 1] = 0;
    if (!(f = _wfopen(path, L"r, ccs=UTF-8")))
    {
        log_line(L"no config for app %ls, launching unchanged", appid);
        return;
    }
    while (fgetws(line, MAX_CMD, f))
    {
        WCHAR *eq;
        trim(line);
        if (!line[0] || line[0] == L'#' || !(eq = wcschr(line, L'='))) continue;
        *eq = 0;
        if (!wcscmp(line, L"RMG_ARGS"))
        {
            wcsncpy(extra_args, eq + 1, ARRAYSIZE(extra_args) - 1);
            continue;
        }
        if (!wcscmp(line, L"RMG_EXEC"))
        {
            wcsncpy(exec_override, eq + 1, ARRAYSIZE(exec_override) - 1);
            continue;
        }
        if (!wcscmp(line, L"RMG_REPLACE"))
        {
            wcsncpy(replace_name, eq + 1, ARRAYSIZE(replace_name) - 1);
            continue;
        }
        SetEnvironmentVariableW(line, eq[1] ? eq + 1 : NULL);
        /* Child processes get their Unix environment from Wine, not from this Windows
         * environment; CrossOver's Wine promotes "__CX_UNIX_<NAME>" variables into it
         * (CW Hack 24717). Unix-side readers (the DLL search path, Metal HUD, DXMT,
         * D3DMetal) need that, Windows-side ones (WINEDLLOVERRIDES) the plain name. */
        {
            WCHAR unix_name[300];
            _snwprintf(unix_name, ARRAYSIZE(unix_name), L"__CX_UNIX_%ls", line);
            unix_name[ARRAYSIZE(unix_name) - 1] = 0;
            SetEnvironmentVariableW(unix_name, eq[1] ? eq + 1 : NULL);
        }
    }
    fclose(f);
    log_line(L"applied config for app %ls", appid);
}

/* Returns the command line with our own argv[0] removed. */
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
    while (*cmd == L' ' || *cmd == L'\t') cmd++;
    return cmd;
}

/* If the command's executable is named replace_name, swap in exec_override.
 * Returns the new command line (args preserved) or NULL to keep the original. */
static const WCHAR *apply_exec_override(const WCHAR *cmd, WCHAR *out, size_t outlen, WCHAR *cwd)
{
    const WCHAR *args = skip_argv0(cmd), *end = args, *base;
    WCHAR exe[MAX_PATH];
    size_t n;

    if (!exec_override[0] || !replace_name[0]) return NULL;
    /* first token without quotes */
    while (end > cmd && (end[-1] == L' ' || end[-1] == L'\t')) end--;
    if (*cmd == L'"') { cmd++; if (end > cmd && end[-1] == L'"') end--; }
    n = end - cmd;
    if (n >= MAX_PATH) return NULL;
    memcpy(exe, cmd, n * sizeof(WCHAR));
    exe[n] = 0;
    base = wcsrchr(exe, L'\\');
    base = base ? base + 1 : exe;
    if (_wcsicmp(base, replace_name)) return NULL;

    _snwprintf(out, outlen, L"\"%ls\" %ls", exec_override, args);
    out[outlen - 1] = 0;
    wcsncpy(cwd, exec_override, MAX_PATH - 1);
    if ((base = wcsrchr(cwd, L'\\'))) *(WCHAR *)base = 0;
    return out;
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, LPWSTR unused, int show)
{
    static WCHAR cmdline[MAX_CMD], swapped[MAX_CMD], cwd[MAX_PATH];
    WCHAR appid[64] = L"", renderer[64] = L"";
    ULONGLONG start;
    const WCHAR *rest = skip_argv0(GetCommandLineW());
    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    DWORD code = 1;

    if (!*rest)
    {
        MessageBoxW(NULL, L"rmgshim must be used as a Steam launch option:\n\nC:\\rmg\\rmgshim.exe %command%",
                    L"RunMyGames", MB_ICONINFORMATION);
        return 1;
    }

    if (GetEnvironmentVariableW(L"SteamAppId", appid, ARRAYSIZE(appid)) ||
        GetEnvironmentVariableW(L"SteamGameId", appid, ARRAYSIZE(appid)))
        apply_env_file(appid);

    if (apply_exec_override(rest, swapped, MAX_CMD, cwd))
    {
        log_line(L"skipping launcher stub %ls", replace_name);
        rest = swapped;
    }
    if (extra_args[0])
        _snwprintf(cmdline, MAX_CMD, L"%ls %ls", rest, extra_args);
    else
        wcsncpy(cmdline, rest, MAX_CMD - 1);
    cmdline[MAX_CMD - 1] = 0;
    log_line(L"exec: %ls", cmdline);

    if (!CreateProcessW(NULL, cmdline, NULL, NULL, FALSE, 0, NULL, cwd[0] ? cwd : NULL, &si, &pi))
    {
        WCHAR msg[64];
        _snwprintf(msg, ARRAYSIZE(msg), L"%lu", GetLastError());
        log_line(L"CreateProcess failed: error %ls", msg);
        return 1;
    }
    start = GetTickCount64();
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);

    if (appid[0])
    {
        WCHAR path[MAX_PATH];
        FILE *f;
        GetEnvironmentVariableW(L"RMG_RENDERER", renderer, ARRAYSIZE(renderer));
        _snwprintf(path, MAX_PATH, L"C:\\rmg\\games\\%ls.last", appid);
        path[MAX_PATH - 1] = 0;
        if ((f = _wfopen(path, L"w")))
        {
            fwprintf(f, L"exit=%ld seconds=%llu renderer=%ls\n", (long)(LONG)code,
                     (GetTickCount64() - start) / 1000, renderer);
            fclose(f);
        }
    }
    return (int)code;
}
