/*
 * nthost: Windows 2000's own cmd.exe on Windows 2000's own msvcrt, kernel32
 * and ntdll, all lifted, on the host's kernel. The guest's int 2Eh is the
 * only boundary (pcrecomp native32 syscall32.c); csrss, another process on
 * Windows 2000, is answered here (CsrClient* below). Stage 2 of
 * docs/findings.md.
 *
 *   build\cmd.exe [--headless] [--mute] [--watchdog S] [-- cmd args]
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "native32.h"
#include "recomp_trace.h"
extern const char* g_cur_import;

#define ARG(n) MEM32(g_esp + 4 + 4 * (n))
#define NTDLL 0x20000000u
#define EXE_BASE 0x4AD00000u
static native32_module_t g_mods[] = {
    { "cmd.exe", EXE_BASE }, { "ntdll.dll", NTDLL }, { "kernel32.dll", 0x20100000u }, { "msvcrt.dll", 0x20200000u },
};
#define NMODS ((int)(sizeof g_mods / sizeof g_mods[0]))
static DWORD g_watchdog_s;

/* csrss is pcrecomp's (csr32.c); the host's own shims go after it. */
static native32_shim_t g_shims[2];

void recomp_not_lifted(uint32_t va) {
    fprintf(stderr, "\n[not-lifted] sub_%08X  (called from 0x%08X)\n", va, g_cur_func);
    native32_dump_icalls(8);
    fflush(stderr);
    TerminateProcess(GetCurrentProcess(), 2);
}

recomp_func_t recomp_lookup_manual(uint32_t va) { (void)va; return NULL; }

static LONG CALLBACK crash(EXCEPTION_POINTERS* ep) {
    EXCEPTION_RECORD* r = ep->ExceptionRecord;
    HMODULE hm;
    if ((r->ExceptionCode & 0xF0000000u) != 0xC0000000u) return EXCEPTION_CONTINUE_SEARCH;
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCSTR)r->ExceptionAddress, &hm) && hm != GetModuleHandleA(NULL))
        return EXCEPTION_CONTINUE_SEARCH;
    fprintf(stderr, "\n=== fault 0x%08lX at %p ===\n  in lifted sub_%08X, last native call %s\n",
            r->ExceptionCode, r->ExceptionAddress, g_cur_func, g_cur_import);
    fprintf(stderr, "  eax=%08X ecx=%08X edx=%08X ebx=%08X esp=%08X ebp=%08X esi=%08X edi=%08X\n",
            g_eax, g_ecx, g_edx, g_ebx, g_esp, g_ebp, g_esi, g_edi);
    native32_dump_icalls(12);
    recomp_dump_trace("fault");
    recomp_trace_flush();
    fflush(stderr);
    TerminateProcess(GetCurrentProcess(), 3);
    return EXCEPTION_CONTINUE_SEARCH;
}

static DWORD WINAPI watchdog(LPVOID unused) {
    (void)unused;
    Sleep(g_watchdog_s * 1000);
    fprintf(stderr, "\n[watchdog] %lu s: in sub_%08X, last native call %s\n", g_watchdog_s, g_cur_func, g_cur_import);
    fflush(stderr);
    native32_dump_icalls(8);
    recomp_dump_trace("watchdog");
    recomp_trace_flush();
    TerminateProcess(GetCurrentProcess(), 4);
    return 0;
}

/* The guest's ExitProcess ends in NtTerminateProcess: flush what the host
 * buffers (--calltrace, stdio) before the host kernel ends us. */
static uint32_t nt_terminate_process(uint32_t* a) {
    if (a[0] == 0xFFFFFFFFu || a[0] == 0) { recomp_trace_flush(); fflush(NULL); }
    return native32_nt_forward("NtTerminateProcess", a);
}
static int host_main(int argc, char** argv) {
    const char* sys = "work/rebased";
    char dir[MAX_PATH], nls[MAX_PATH];
    wchar_t cmdline[1024] = L"cmd.exe", image[MAX_PATH];
    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], "--mute") || !strcmp(argv[i], "--headless")) SetEnvironmentVariableA("PCRECOMP_MUTE", "1");
    for (int i = 1; i < argc; i++) {
        int rc;
        if (!strcmp(argv[i], "--headless") && (rc = native32_headless()) >= 0) return rc;
    }
    for (int i = 1; i < argc; i++) {
        int n = recomp_trace_arg(argc, argv, i);
        if (n) { i += n - 1; continue; }
        if (!strcmp(argv[i], "--headless") || !strcmp(argv[i], "--mute")) ;
        else if (!strcmp(argv[i], "--watchdog") && i + 1 < argc) g_watchdog_s = strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--native-trace")) native32_trace_native = 1;
        else if (!strcmp(argv[i], "--")) {
            while (++i < argc) {
                size_t n = wcslen(cmdline);
                _snwprintf(cmdline + n, 1023 - n, L" %hs", argv[i]);
            }
            break;
        }
        else { printf("usage: cmd [--headless] [--mute] [--watchdog S] [--native-trace] [-- args]\n"); return 1; }
    }
    GetFullPathNameA(sys, MAX_PATH, dir, NULL);
    GetFullPathNameA("work/sys", MAX_PATH, nls, NULL);
    {
        char exe[MAX_PATH];
        _snprintf(exe, sizeof exe - 1, "%s\cmd.exe", dir);
        exe[MAX_PATH - 1] = 0;
        native32_hold_image(exe, EXE_BASE);
        MultiByteToWideChar(CP_ACP, 0, exe, -1, image, MAX_PATH);
    }
    native32_init();
    AddVectoredExceptionHandler(0, crash);
    if (!native32_modules_map(dir, dir, g_mods, NMODS)) return 1;
    native32_nt_override("NtTerminateProcess", nt_terminate_process);
    native32_nt_syscalls(NTDLL);
    memcpy(g_shims, native32_csr_shims, sizeof g_shims);
    int missing = native32_modules_bind(g_shims, (int)(sizeof g_shims / sizeof g_shims[0]));
    if (missing) fprintf(stderr, "warning: %d imports unresolved\n", missing);
    /* SP4 ntdll's RtlpInitDeferedCriticalSection (LdrpInitializeProcess calls
     * it first; found from the writer of the debug-info free list). */
    {
        /* csrss's \NLS sections, from Windows 2000's own NLS files */
        static const struct { const wchar_t* sec; const char* file; } nls_sec[] = {
            { L"\\NLS\\NlsSectionUnicode", "unicode.nls" }, { L"\\NLS\\NlsSectionCType", "ctype.nls" },
            { L"\\NLS\\NlsSectionLocale", "locale.nls" }, { L"\\NLS\\NlsSectionSortkey", "sortkey.nls" },
            { L"\\NLS\\NlsSectionSortTbls", "sorttbls.nls" }, { L"\\NLS\\NlsSectionCP1252", "c_1252.nls" },
            { L"\\NLS\\NlsSectionCP437", "c_437.nls" }, { L"\\NLS\\NlsSectionSortkey00000409", "sortkey_00000409.nls" }, { L"\\NLS\\NlsSectionLANG_INTL", "l_intl.nls" },
        };
        /* csrss's per-locale sort table: sortkey.nls whole, its first WORD set
         * to 1 ("built"; kernel32 waits while it is 0). US English has no
         * exceptions to apply. Written once into work/sys. */
        {
            char src[MAX_PATH], dst[MAX_PATH];
            _snprintf(src, MAX_PATH - 1, "%s\\sortkey.nls", nls);
            _snprintf(dst, MAX_PATH - 1, "%s\\sortkey_00000409.nls", nls);
            if (GetFileAttributesA(dst) == INVALID_FILE_ATTRIBUTES && CopyFileA(src, dst, TRUE)) {
                FILE* f = fopen(dst, "r+b");
                if (f) { uint16_t one = 1; fwrite(&one, 2, 1, f); fclose(f); }
            }
        }        for (int i = 0; i < (int)(sizeof nls_sec / sizeof nls_sec[0]); i++) {
            wchar_t f[MAX_PATH];
            _snwprintf(f, MAX_PATH - 1, L"%hs\\%hs", nls, nls_sec[i].file);
            f[MAX_PATH - 1] = 0;
            native32_nt_section_file(nls_sec[i].sec, f);
        }
    }
    native32_nt_preinit(0x20003A3Bu);
    native32_nt_preinit(0x20003B6Au);   /* RtlInitializeHeapManager: the heap-list lock, Peb->ProcessHeaps */
    /* LdrpInitializeProcess's inline stores this host does in its place
     * (SP4 addresses, rebased; the store instructions are at 0x2000579D..). */
    MEM32(0x2004F1BCu) = 0x20015546u;   /* RtlAllocateStringRoutine */
    MEM32(0x2004F1B0u) = 0x2000EBB4u;   /* RtlFreeStringRoutine */
    if (!native32_nt_process(NTDLL, EXE_BASE, image, cmdline, nls)) return 1;
    native32_nt_loader(0x2004F040u, 0x2000EEFBu);   /* LdrpHashTable, LdrpInsertMemoryTableEntry */
    for (int i = 0; i < NMODS; i++) {
        wchar_t path[MAX_PATH];
        _snwprintf(path, MAX_PATH - 1, L"%hs\\%hs", dir, g_mods[i].name);
        path[MAX_PATH - 1] = 0;
        native32_nt_module(g_mods[i].base, path);
    }
    /* CsrPortHeap: csrss's shared port memory on Windows 2000, the process heap here */
    MEM32(0x2004F634u) = MEM32(native32_guest_peb + 0x18);
    IMAGE_NT_HEADERS32* nt = (IMAGE_NT_HEADERS32*)(uintptr_t)(EXE_BASE + MEM32(EXE_BASE + 0x3C));
    uint32_t entry = EXE_BASE + nt->OptionalHeader.AddressOfEntryPoint;
    if (g_watchdog_s) CloseHandle(CreateThread(NULL, 0, watchdog, NULL, 0, NULL));
    if (!native32_attach_imports(EXE_BASE)) return 1;
    if (getenv("W2K_NLS_TEST")) {
        /* LCMapStringW(0x409, LCMAP_UPPERCASE, L"ver", 3, buf, 8) on the lifted kernel32 */
        static wchar_t in[] = L"ver", out[8];
        uint32_t a[6] = { 0x409, 0x200, (uint32_t)(uintptr_t)in, 3, (uint32_t)(uintptr_t)out, 8 };
        native32_call_guest(native32_export(0x20100000u, "LCMapStringW"), 6, a);
        fprintf(stderr, "[nls] LCMapStringW -> %u \"%ls\" error %u\n", g_eax, out, MEM32(MEM32(g_fs_base + 0x18) + 0x34));
        a[0] = 0x0800; a[1] = 0x200;   /* LOCALE_SYSTEM_DEFAULT */
        native32_call_guest(native32_export(0x20100000u, "LCMapStringW"), 6, a);
        fprintf(stderr, "[nls] LCMapStringW(sys) -> %u \"%ls\" error %u\n", g_eax, out, MEM32(MEM32(g_fs_base + 0x18) + 0x34));
        uint32_t c = 'v';
        native32_call_guest(native32_export(0x20200000u, "towupper"), 1, &c);
        fprintf(stderr, "[nls] msvcrt towupper('v') -> %04X\n", g_eax & 0xFFFF);
        {
            static wchar_t s1[] = L"ver", s2[] = L"VER", s3[] = L"verify";
            uint32_t b[2] = { (uint32_t)(uintptr_t)s1, (uint32_t)(uintptr_t)s2 };
            native32_call_guest(native32_export(0x20100000u, "lstrcmpiW"), 2, b);
            fprintf(stderr, "[nls] lstrcmpiW(ver, VER) -> %d\n", (int)g_eax);
            b[1] = (uint32_t)(uintptr_t)s3;
            native32_call_guest(native32_export(0x20100000u, "lstrcmpiW"), 2, b);
            fprintf(stderr, "[nls] lstrcmpiW(ver, verify) -> %d\n", (int)g_eax);
            b[1] = (uint32_t)(uintptr_t)s2;
            native32_call_guest(native32_export(0x20200000u, "_wcsicmp"), 2, b);
            fprintf(stderr, "[nls] _wcsicmp(ver, VER) -> %d\n", (int)g_eax);
        }        {
            static char empty[] = "";
            static wchar_t s1[] = L"ver", s2[] = L"VER", up[] = L"ver";
            uint32_t b[2] = { 0, (uint32_t)(uintptr_t)empty };
            native32_call_guest(native32_export(0x20200000u, "setlocale"), 2, b);
            fprintf(stderr, "[nls] setlocale(LC_ALL, \"\") -> %s\n", g_eax ? (char*)(uintptr_t)g_eax : "(null)");
            b[0] = (uint32_t)(uintptr_t)s1; b[1] = (uint32_t)(uintptr_t)s2;
            native32_call_guest(native32_export(0x20200000u, "_wcsicmp"), 2, b);
            fprintf(stderr, "[nls] after: _wcsicmp(ver, VER) -> %d\n", (int)g_eax);
            uint32_t c = 'v';
            native32_call_guest(native32_export(0x20200000u, "towupper"), 1, &c);
            fprintf(stderr, "[nls] after: towupper('v') -> %04X\n", g_eax & 0xFFFF);
            b[0] = (uint32_t)(uintptr_t)up;
            native32_call_guest(native32_export(0x20200000u, "_wcsupr"), 1, b);
            fprintf(stderr, "[nls] after: _wcsupr(ver) -> %ls\n", up);
        }        {
            static wchar_t z[] = L"";
            uint32_t a2[6] = { 0, 0x100 /* LCMAP_LOWERCASE */, (uint32_t)(uintptr_t)z, 1, 0, 0 };
            MEM32(MEM32(g_fs_base + 0x18) + 0x34) = 0;
            native32_call_guest(native32_export(0x20100000u, "LCMapStringW"), 6, a2);
            fprintf(stderr, "[nls] probe LCMapStringW(0, LOWER, L\"\", 1, 0, 0) -> %u error %u\n", g_eax,
                    MEM32(MEM32(g_fs_base + 0x18) + 0x34));
            a2[0] = 0x409;
            native32_call_guest(native32_export(0x20100000u, "LCMapStringW"), 6, a2);
            fprintf(stderr, "[nls] probe 0x409 -> %u error %u\n", g_eax, MEM32(MEM32(g_fs_base + 0x18) + 0x34));
        }        native32_call_guest(native32_export(0x20100000u, "GetUserDefaultLCID"), 0, NULL);
        fprintf(stderr, "[nls] GetUserDefaultLCID -> %04X\n", g_eax);
    }    fprintf(stderr, "cmd.exe: %u lifted functions, entering 0x%08X\n", recomp_dispatch_count, entry);
    native32_call_guest(entry, 0, NULL);
    return (int)g_eax;
}

static int g_argc;
static char** g_argv;
static DWORD WINAPI host_thread(LPVOID unused) { (void)unused; return (DWORD)host_main(g_argc, g_argv); }

int main(int argc, char** argv) {
    DWORD code = 1;
    g_argc = argc;
    g_argv = argv;
    HANDLE t = CreateThread(NULL, 16u << 20, host_thread, NULL, STACK_SIZE_PARAM_IS_A_RESERVATION, NULL);
    if (!t) return 1;
    WaitForSingleObject(t, INFINITE);
    GetExitCodeThread(t, &code);
    return (int)code;
}
