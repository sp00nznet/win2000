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
