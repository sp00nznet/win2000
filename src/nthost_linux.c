/*
 * nthost_linux: Windows 2000's own cmd.exe on its own lifted msvcrt,
 * kernel32 and ntdll, on Linux. No Wine: the guest's int 2Eh is answered on
 * POSIX by pcrecomp's runtime/native32/ntposix.c. The Linux counterpart of
 * src/nthost.c; docs/linux.md.
 *
 *   cmd-linux [--root DIR] [--sys DIR] [--nls DIR] [--cd C:\X] [-- cmd args]
 *
 *   --root  the host directory that is the guest's C:\ (default: the current directory)
 *   --sys   the rebased lifted modules, the guest's C:\WINNT\system32 (default: ROOT/sys)
 *   --nls   Windows 2000's .nls files (default: the --sys directory)
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>
#include <pthread.h>
#include "ntposix.h"

#define ARG(n) MEM32(g_esp + 4 + 4 * (n))
#define RET(v, n) do { g_eax = (v); g_esp += 4 + 4 * (n); } while (0)

/* What cmd.exe imports from user32 and advapi32, answered here: no window
 * station, and a registry with nothing in it (cmd's AutoRun, CompletionChar
 * and the like stay at their defaults). */
static void u_MessageBeep(void) { RET(1, 1); }
static void u_GetThreadDesktop(void) { RET(0, 1); }
static void u_GetProcessWindowStation(void) { RET(0, 0); }
static void u_GetUserObjectInformationW(void) { RET(0, 5); }
static const ntp_stub_t g_user32[] = {
    { "MessageBeep", 1, u_MessageBeep }, { "GetThreadDesktop", 1, u_GetThreadDesktop },
    { "GetProcessWindowStation", 0, u_GetProcessWindowStation },
    { "GetUserObjectInformationW", 5, u_GetUserObjectInformationW },
};
#define ERROR_FILE_NOT_FOUND 2
#define ERROR_ACCESS_DENIED 5
static void a_RegOpenKeyExW(void) { if (ARG(4)) MEM32(ARG(4)) = 0; RET(ERROR_FILE_NOT_FOUND, 5); }
static void a_RegOpenKeyW(void) { if (ARG(2)) MEM32(ARG(2)) = 0; RET(ERROR_FILE_NOT_FOUND, 3); }
static void a_RegQueryValueExW(void) { RET(ERROR_FILE_NOT_FOUND, 6); }
static void a_RegQueryValueW(void) { RET(ERROR_FILE_NOT_FOUND, 4); }
static void a_RegCloseKey(void) { RET(0, 1); }
static void a_RegCreateKeyExW(void) { RET(ERROR_ACCESS_DENIED, 9); }
static void a_RegSetValueExW(void) { RET(ERROR_ACCESS_DENIED, 6); }
static void a_RegSetValueW(void) { RET(ERROR_ACCESS_DENIED, 5); }
static void a_RegDeleteKeyW(void) { RET(ERROR_ACCESS_DENIED, 2); }
static void a_RegEnumKeyW(void) { RET(259, 4); }                 /* ERROR_NO_MORE_ITEMS */
static void a_GetSecurityInfoExW(void) { RET(1, 9); }
static const ntp_stub_t g_advapi32[] = {
    { "RegOpenKeyExW", 5, a_RegOpenKeyExW }, { "RegOpenKeyW", 3, a_RegOpenKeyW },
    { "RegQueryValueExW", 6, a_RegQueryValueExW }, { "RegQueryValueW", 4, a_RegQueryValueW },
    { "RegCloseKey", 1, a_RegCloseKey }, { "RegCreateKeyExW", 9, a_RegCreateKeyExW },
    { "RegSetValueExW", 6, a_RegSetValueExW }, { "RegSetValueW", 5, a_RegSetValueW },
    { "RegDeleteKeyW", 2, a_RegDeleteKeyW }, { "RegEnumKeyW", 4, a_RegEnumKeyW },
    { "GetSecurityInfoExW", 9, a_GetSecurityInfoExW },
};

static const struct { const char* name; uint32_t base; } g_mods[] = {
    { "cmd.exe", 0x4AD00000u }, { "ntdll.dll", 0x20000000u }, { "kernel32.dll", 0x20100000u }, { "msvcrt.dll", 0x20200000u },
};

static int g_argc;
static char** g_argv;

static void* host_main(void* rcp) {
    char root[PATH_MAX], sys[PATH_MAX] = "", nls[PATH_MAX] = "", cd[1024] = "", cmdline[4096] = "C:\\WINNT\\system32\\cmd.exe";
    if (!getcwd(root, sizeof root)) strcpy(root, ".");
    for (int i = 1; i < g_argc; i++) {
        if (!strcmp(g_argv[i], "--root") && i + 1 < g_argc) { if (!realpath(g_argv[++i], root)) { perror(g_argv[i]); exit(1); } }
        else if (!strcmp(g_argv[i], "--sys") && i + 1 < g_argc) { if (!realpath(g_argv[++i], sys)) { perror(g_argv[i]); exit(1); } }
        else if (!strcmp(g_argv[i], "--nls") && i + 1 < g_argc) { if (!realpath(g_argv[++i], nls)) { perror(g_argv[i]); exit(1); } }
        else if (!strcmp(g_argv[i], "--cd") && i + 1 < g_argc) snprintf(cd, sizeof cd, "%s", g_argv[++i]);
        else if (!strcmp(g_argv[i], "--mute")) ;          /* nothing makes a sound here */
        else if (!strcmp(g_argv[i], "--")) {
            while (++i < g_argc) { strncat(cmdline, " ", sizeof cmdline - strlen(cmdline) - 1); strncat(cmdline, g_argv[i], sizeof cmdline - strlen(cmdline) - 1); }
            break;
        } else { fprintf(stderr, "usage: cmd-linux [--root DIR] [--sys DIR] [--nls DIR] [--cd C:\\X] [-- args]\n"); exit(1); }
    }
    if (!sys[0]) snprintf(sys, sizeof sys, "%s/sys", root);
    if (!nls[0]) snprintf(nls, sizeof nls, "%s", sys);
    if (!cd[0]) {                    /* the host's current directory, if it is under the root */
        char here[PATH_MAX];
        size_t n = strlen(root);
        if (getcwd(here, sizeof here) && !strncmp(here, root, n) && (here[n] == '/' || !here[n])) {
            snprintf(cd, sizeof cd, "C:\\%s", here[n] ? here + n + 1 : "");
            for (char* p = cd; *p; p++) if (*p == '/') *p = '\\';
        } else strcpy(cd, "C:\\");
    }

    ntp_init();
    ntp_mount("C:", root);
    ntp_mount("C:\\WINNT\\system32", sys);
    for (size_t i = 0; i < sizeof g_mods / sizeof g_mods[0]; i++) {
        char p[PATH_MAX + 64];
        snprintf(p, sizeof p, "%s/%s", sys, g_mods[i].name);
        if (!ntp_map(p, g_mods[i].base, g_mods[i].name)) exit(1);
    }
    ntp_proxy("user32.dll", g_user32, sizeof g_user32 / sizeof g_user32[0]);
    ntp_proxy("advapi32.dll", g_advapi32, sizeof g_advapi32 / sizeof g_advapi32[0]);
    ntp_syscalls(0x20000000u);
    {   /* csrss's \NLS sections, from Windows 2000's own NLS files */
        static const char* sec[][2] = {
            { "\\NLS\\NlsSectionUnicode", "unicode.nls" }, { "\\NLS\\NlsSectionCType", "ctype.nls" },
            { "\\NLS\\NlsSectionLocale", "locale.nls" }, { "\\NLS\\NlsSectionSortkey", "sortkey.nls" },
            { "\\NLS\\NlsSectionSortTbls", "sorttbls.nls" }, { "\\NLS\\NlsSectionCP1252", "c_1252.nls" },
            { "\\NLS\\NlsSectionCP437", "c_437.nls" }, { "\\NLS\\NlsSectionLANG_INTL", "l_intl.nls" },
            { "\\NLS\\NlsSectionSortkey00000409", "sortkey_00000409.nls" },
        };
        for (size_t i = 0; i < sizeof sec / sizeof sec[0]; i++) {
            char f[PATH_MAX + 64];
            snprintf(f, sizeof f, "%s/%s", nls, sec[i][1]);
            ntp_section_file(sec[i][0], f);
        }
    }
    uint32_t exe = g_mods[0].base;
    if (!ntp_boot(0x20000000u, exe, "C:\\WINNT\\system32\\cmd.exe", cmdline, "C:\\WINNT\\system32;C:\\WINNT", cd, nls, 0x0400))
        exit(1);
    uint32_t entry = exe + MEM32(exe + MEM32(exe + 0x3C) + 0x28);
    fprintf(stderr, "cmd.exe: %u lifted functions, entering 0x%08X\n", recomp_dispatch_count, entry);
    ntp_call(entry, 0, NULL);
    *(int*)rcp = (int)g_eax;
    return NULL;
}

int main(int argc, char** argv) {
    pthread_attr_t at;
    pthread_t t;
    int rc = 1;
    g_argc = argc, g_argv = argv;
    setvbuf(stderr, NULL, _IONBF, 0);
    pthread_attr_init(&at);
    pthread_attr_setstacksize(&at, 256u << 20);    /* lifted calls nest on the host stack */
    if (pthread_create(&t, &at, host_main, &rc)) return 1;
    pthread_join(t, NULL);
    return rc;
}
