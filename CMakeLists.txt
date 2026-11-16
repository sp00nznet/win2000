# Windows 2000 userland on pcrecomp's native32 (32-bit host, MSVC x86).
#   py -3 tools/lift.py winmine work/sys/winmine.exe   (and so on, README)
#   build.cmd
cmake_minimum_required(VERSION 3.20)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
project(win2000 C)
if(NOT CMAKE_SIZEOF_VOID_P EQUAL 4 OR NOT MSVC)
  message(FATAL_ERROR "the host must be 32-bit MSVC: use build.cmd")
endif()
set(PCRECOMP "${CMAKE_SOURCE_DIR}/../pcrecomp-w2k" CACHE PATH "pcrecomp checkout")
include(${PCRECOMP}/cmake/pcrecomp_gen.cmake)

set(N32 ${PCRECOMP}/runtime/native32)
function(w2k_host name main)
  if(NOT EXISTS ${CMAKE_SOURCE_DIR}/src/gen/${name}/recomp_dispatch.c)
    message(STATUS "${name}: not lifted, skipped")
    return()
  endif()
  add_executable(${name} ${main} ${N32}/native32.c ${N32}/modules32.c ${N32}/regbox32.c
                 ${PCRECOMP}/runtime/recomp32/image_loader.c ${PCRECOMP}/runtime/recomp32/recomp_trace.c ${ARGN})
  pcrecomp_gen_sources(${name} DIR ${CMAKE_SOURCE_DIR}/src/gen/${name})
  target_include_directories(${name} PRIVATE src src/gen/${name} ${N32} ${PCRECOMP}/runtime/recomp32)
  target_compile_definitions(${name} PRIVATE RECOMP_RETADDR=0u _CRT_SECURE_NO_WARNINGS
                             RECOMP_FLAT_MEMORY RECOMP_LOCAL_REGS)
  # High, fixed and /NXCOMPAT (the callback trampoline is the DEP fault).
  target_link_options(${name} PRIVATE /BASE:0x60000000 /FIXED:NO /DYNAMICBASE:NO /NXCOMPAT
                      /LARGEADDRESSAWARE /STACK:0x40000 /MANIFESTUAC:NO)
  target_link_libraries(${name} PRIVATE user32 gdi32 kernel32 winmm advapi32)
endfunction()

foreach(app winmine sol freecell notepad calc clipbrd packager mspaint wordpad)
  w2k_host(${app} src/apphost.c)
  if(TARGET ${app})
    target_compile_definitions(${app} PRIVATE APP_EXE="${app}.exe" APP_BASE=0x01000000u)
  endif()
endforeach()
foreach(app sol freecell)   # cards.dll is not on a modern Windows: lifted too
  if(TARGET ${app})
    target_compile_definitions(${app} PRIVATE "APP_DLLS=,{\"cards.dll\",0x74260000u}")
  endif()
endforeach()

# MFC (Windows 2000's mfc42u, riched20): lifted from the rebased copies, as on lifted user32
if(TARGET mspaint)
  target_compile_definitions(mspaint PRIVATE APP_SYS="work/rebased-gui" "APP_DLLS=,{\"mfc42u.dll\",0x20600000u}")
endif()
if(TARGET wordpad)
  target_compile_definitions(wordpad PRIVATE APP_SYS="work/rebased-gui" "APP_DLLS=,{\"mfc42u.dll\",0x20600000u},{\"riched20.dll\",0x20700000u}")
endif()

# Stage 2: cmd.exe on lifted msvcrt + kernel32 + ntdll (rebased: tools in README)
w2k_host(cmd src/nthost.c ${N32}/syscall32.c ${N32}/csr32.c)
option(W2K_TRACE "ring buffer of lifted function entries in the cmd host" ON)
if(TARGET cmd AND W2K_TRACE)
  target_compile_definitions(cmd PRIVATE RECOMP_TRACE=1)
endif()

# The same host for another Windows 2000 build: pro.zip's ISO is build 2163
# (a pre-release), lifted into src/gen/cmd_rtm from work/rebased-rtm.
w2k_host(cmd_rtm src/nthost.c ${N32}/syscall32.c ${N32}/csr32.c)
if(TARGET cmd_rtm)
  target_compile_definitions(cmd_rtm PRIVATE RECOMP_TRACE=1 W2K_SYS="work/rebased-rtm" W2K_NLS="work/sys-rtm" W2K_CSD=0)
endif()

# cmd's own utilities (pipes: echo hi | find "hi"), on lifted ulib.dll too; build\find.exe and
# build\more.exe are the runners cmd's CreateProcess reaches (nthost.c, the launch path)
foreach(util find more)
  w2k_host(${util} src/nthost.c ${N32}/syscall32.c ${N32}/csr32.c)
endforeach()
if(TARGET find)
  target_compile_definitions(find PRIVATE W2K_EXE="find.exe" W2K_EXE_W=L"find.exe" EXE_BASE=0x01000000u
    W2K_SYS="work/rebased-util" W2K_NLS="work/sys" W2K_CSD=0x0400 "W2K_MORE_MODS=,{\"ulib.dll\",0x20300000u}")
endif()
if(TARGET more)
  target_compile_definitions(more PRIVATE W2K_EXE="more.com" W2K_EXE_W=L"more.com" EXE_BASE=0x01000000u
    W2K_SYS="work/rebased-util" W2K_NLS="work/sys" W2K_CSD=0x0400 "W2K_MORE_MODS=,{\"ulib.dll\",0x20300000u}")
endif()

# Stage 3: accessories on their own lifted user32 + gdi32 (and kernel32, ntdll, msvcrt)
set(W2K_USER_SYS work/rebased-gui)
function(w2k_user_host name exe)
  w2k_host(${name} src/nthost.c ${N32}/syscall32.c ${N32}/csr32.c ${N32}/w32kgdi.c ${N32}/w32kuser.c)
  if(TARGET ${name})
    target_compile_definitions(${name} PRIVATE RECOMP_TRACE=1 W2K_EXE="${exe}" W2K_EXE_W=L"${exe}"
      EXE_BASE=0x01000000u W2K_SYS="${W2K_USER_SYS}" W2K_NLS="work/sys" W2K_CSD=0x0400 W2K_USER_LAYER=1
      "W2K_MORE_MODS=,{\"user32.dll\",0x20300000u},{\"gdi32.dll\",0x20400000u}${ARGN}")
  endif()
endfunction()
w2k_user_host(ntwinmine winmine.exe)
w2k_user_host(ntnotepad notepad.exe)
w2k_user_host(ntcalc calc.exe)
w2k_user_host(ntclipbrd clipbrd.exe)     # RegisterClassA: the ANSI path
w2k_user_host(ntpackager packager.exe)   # RegisterClassA
w2k_user_host(ntsol sol.exe ",{\"cards.dll\",0x20500000u}")
w2k_user_host(ntfreecell freecell.exe ",{\"cards.dll\",0x20500000u}")
w2k_user_host(ntmspaint mspaint.exe ",{\"mfc42u.dll\",0x20600000u}")
w2k_user_host(ntwordpad wordpad.exe ",{\"mfc42u.dll\",0x20600000u},{\"riched20.dll\",0x20700000u}")

# Interim: winmine on its own lifted gdi32, the host's user32 (pcrecomp w32kgdi.c)
w2k_host(ntwmgdi src/nthost.c ${N32}/syscall32.c ${N32}/csr32.c ${N32}/w32kgdi.c)
if(TARGET ntwmgdi)
  target_compile_definitions(ntwmgdi PRIVATE RECOMP_TRACE=1 W2K_EXE="winmine.exe" W2K_EXE_W=L"winmine.exe"
    EXE_BASE=0x01000000u W2K_SYS="work/rebased-gdi" W2K_NLS="work/sys" W2K_CSD=0x0400 W2K_GDI_LAYER=1
    "W2K_MORE_MODS=,{\"gdi32.dll\",0x20400000u}")
endif()

# More accessories on lifted gdi32 + host user32, growing w32kgdi.c
function(w2k_gdi_host name exe)
  w2k_host(${name} src/nthost.c ${N32}/syscall32.c ${N32}/csr32.c ${N32}/w32kgdi.c)
  if(TARGET ${name})
    target_compile_definitions(${name} PRIVATE RECOMP_TRACE=1 W2K_EXE="${exe}" W2K_EXE_W=L"${exe}"
      EXE_BASE=0x01000000u W2K_SYS="work/rebased-gdi" W2K_NLS="work/sys" W2K_CSD=0x0400 W2K_GDI_LAYER=1
      "W2K_MORE_MODS=,{\"gdi32.dll\",0x20400000u}${ARGN}")
  endif()
endfunction()
w2k_gdi_host(gdisol sol.exe ",{\"cards.dll\",0x20500000u}")
w2k_gdi_host(gdifreecell freecell.exe ",{\"cards.dll\",0x20500000u}")
w2k_gdi_host(gdinotepad notepad.exe)
w2k_gdi_host(gdicalc calc.exe)

# Windows inside Windows: explorer.exe on the virtual screen (W2K_SCREEN, docs/findings.md)
set(W2K_USER_SYS work/rebased-shell)   # the shell's DLLs apart: another program must not load them
w2k_user_host(ntexplorer explorer.exe ",{\"comctl32.dll\",0x20800000u},{\"shlwapi.dll\",0x20900000u},{\"shell32.dll\",0x20A00000u},{\"browseui.dll\",0x20D00000u},{\"shdocvw.dll\",0x20E00000u},{\"ole32.dll\",0x21000000u},{\"oleaut32.dll\",0x21100000u},{\"rpcrt4.dll\",0x21200000u},{\"actxprxy.dll\",0x21300000u},{\"desk.cpl\",0x21400000u},{\"clbcatq.dll\",0x21500000u},{\"mydocs.dll\",0x21600000u}")

