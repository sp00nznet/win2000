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
  add_executable(${name} ${main} ${N32}/native32.c ${N32}/modules32.c
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

foreach(app winmine sol freecell notepad calc)
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

# Stage 3: winmine on its own lifted user32 + gdi32 (and kernel32, ntdll, msvcrt)
w2k_host(ntwinmine src/nthost.c ${N32}/syscall32.c ${N32}/csr32.c)
if(TARGET ntwinmine)
  target_compile_definitions(ntwinmine PRIVATE RECOMP_TRACE=1 W2K_EXE="winmine.exe" W2K_EXE_W=L"winmine.exe"
    EXE_BASE=0x01000000u W2K_SYS="work/rebased-gui" W2K_NLS="work/sys" W2K_CSD=0x0400 "W2K_MORE_MODS=,{\"user32.dll\",0x20300000u},{\"gdi32.dll\",0x20400000u}")
endif()

# Interim: winmine on its own lifted gdi32, the host's user32 (pcrecomp w32kgdi.c)
w2k_host(ntwmgdi src/nthost.c ${N32}/syscall32.c ${N32}/csr32.c ${N32}/w32kgdi.c)
if(TARGET ntwmgdi)
  target_compile_definitions(ntwmgdi PRIVATE RECOMP_TRACE=1 W2K_EXE="winmine.exe" W2K_EXE_W=L"winmine.exe"
    EXE_BASE=0x01000000u W2K_SYS="work/rebased-gdi" W2K_NLS="work/sys" W2K_CSD=0x0400 W2K_GDI_LAYER=1
    "W2K_MORE_MODS=,{\"gdi32.dll\",0x20400000u}")
endif()
