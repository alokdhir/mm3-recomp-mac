cmake_minimum_required(VERSION 3.20)
# Any Apple Silicon Mac on Sonoma or later: the floor of the Metal 3.1
# shaders. Without it the build would require the macOS it was built on.
if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS" FORCE)
endif()
project(mm3_port C CXX OBJC)

# Midtown Madness 3 (Xbox), native on Apple Silicon.
#
# The game is the upstream static recompilation (third_party/mm3-recomp, with
# the xboxrecomp runtime under it), built for arm64-apple-macos. This project
# supplies what replaces the Win32 host: mac/include (a windows.h over the
# runtime's Win32 vocabulary) and mac/src (launcher, file and CRT shims).
#
# Game data is never part of the tree: scripts/setup.sh extracts your disc to
# game_files/ and generates the translated C into build/gen.

if(NOT APPLE OR NOT CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
    message(FATAL_ERROR "mm3-port targets arm64 macOS")
endif()

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

set(MM3_GAME_DIR "${CMAKE_CURRENT_SOURCE_DIR}/game_files" CACHE PATH
    "Extracted game files (default.xbe, Data/...)")
set(RECOMP_GEN_DIR "${CMAKE_CURRENT_BINARY_DIR}/gen" CACHE PATH
    "Generated recompilation C sources")
set(XBOXRECOMP_DSP_PROGRAM_DIR "${MM3_GAME_DIR}/dsp")

set(MM3_PLATFORM_INCLUDE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/mac/include" CACHE STRING "" FORCE)
set(MM3_PLATFORM_SOURCES
    "${CMAKE_CURRENT_SOURCE_DIR}/mac/src/app_macos.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/mac/src/mac_win32_extras.c"
    "${CMAKE_CURRENT_SOURCE_DIR}/mac/src/mm3_asset_cache_posix.c"
    "${CMAKE_CURRENT_SOURCE_DIR}/mac/src/mm3_launcher_macos.c"
    CACHE STRING "" FORCE)
set(MM3_PLATFORM_LIBRARIES "-framework Cocoa" "-framework IOKit" CACHE STRING "" FORCE)

# Audio out through Core Audio, pads through the GameController framework.
set(XBOX_AUDIO_BACKEND_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/mac/src/audio/apu_coreaudio.c")
set(XBOX_AUDIO_BACKEND_LIBRARIES "-framework AudioToolbox" "-framework CoreAudio")
set(XBOX_INPUT_BACKEND_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/mac/src/input/gc_xinput.m")
set(XBOX_INPUT_BACKEND_INCLUDES "${CMAKE_CURRENT_SOURCE_DIR}/mac/include")
set(XBOX_INPUT_BACKEND_LIBRARIES "-framework GameController" "-framework CoreHaptics" "-framework Foundation")

# The renderer: Metal in place of D3D11, and the AppKit window it draws into.
set(XBOX_VIDEO_BACKEND_SOURCES
    "${CMAKE_CURRENT_SOURCE_DIR}/mac/src/video/nv2a_metal.m"
    "${CMAKE_CURRENT_SOURCE_DIR}/mac/src/video/fb_window_macos.m")
set(XBOX_VIDEO_BACKEND_INCLUDES
    "${CMAKE_CURRENT_SOURCE_DIR}/mac/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/mac/src/video"
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/mm3-recomp/tools/xboxrecomp/src/platform")
# Guest memory accesses in x86 order (TSO): the generated code's loads and
# stores are load-acquire / store-release (scripts/tso_accessors.py,
# mm3_recomp_types.h). OFF compiles them as plain accesses, for comparison.
option(MM3_TSO "Order guest memory accesses as x86 does" ON)

# The shader source, embedded in the renderer (nv2a_metal_source.inc): with
# no precompiled library the renderer compiles it at launch (about half a
# second), so a build needs only the Command Line Tools, not Xcode's Metal
# compiler. Regenerated whenever the shader changes.
set(NV2A_METAL_SRC "${CMAKE_CURRENT_SOURCE_DIR}/mac/src/video/nv2a.metal")
set(MM3_GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${NV2A_METAL_SRC}")
file(READ "${NV2A_METAL_SRC}" nv2a_metal_hex HEX)
string(REGEX REPLACE "([0-9a-f][0-9a-f])" "0x\\1," nv2a_metal_hex "${nv2a_metal_hex}")
file(WRITE "${MM3_GENERATED_DIR}/nv2a_metal_source.inc.new"
     "/* Generated from mac/src/video/nv2a.metal by CMakeLists.txt. */\n"
     "static const unsigned char nv2a_metal_source[] = { ${nv2a_metal_hex} 0x00 };\n")
file(COPY_FILE "${MM3_GENERATED_DIR}/nv2a_metal_source.inc.new"
     "${MM3_GENERATED_DIR}/nv2a_metal_source.inc" ONLY_IF_DIFFERENT)
list(APPEND XBOX_VIDEO_BACKEND_INCLUDES "${MM3_GENERATED_DIR}")

set(XBOX_VIDEO_BACKEND_LIBRARIES
    "-framework Metal" "-framework QuartzCore" "-framework Cocoa" "-framework Carbon"
    "-framework ImageIO" "-framework CoreGraphics")

add_subdirectory(third_party/mm3-recomp)

# The game's arithmetic as x86 rounds it: clang on arm64 fuses a*b+c into
# one FMA (one rounding instead of two), which x86 code never did. Physics
# and the CPU-built shadow geometry are sensitive to that at their edges.
target_compile_options(mm3_recomp PRIVATE -ffp-contract=off)

# Upstream's main() runs on a worker thread; AppKit owns the real one
# (mac/src/app_macos.m).
set_property(SOURCE third_party/mm3-recomp/src/main.c
    DIRECTORY third_party/mm3-recomp APPEND PROPERTY COMPILE_DEFINITIONS main=mm3_main)

# The translated code as clang sees it. MSVC accepts a call to an undeclared
# function; the generator relies on that for tail jumps it emits into dead
# code (after a return, under labels nothing branches to), which optimisation
# then removes. Keep those a warning in the generated sources only, and quiet
# the lifter's double-parenthesised conditions. recomp_types.h replaces
# memcpy with the guest-aware copy, so the SDK's fortified macro stays out.
file(GLOB MM3_GEN_SOURCES CONFIGURE_DEPENDS "${RECOMP_GEN_DIR}/*.c")
set_property(SOURCE ${MM3_GEN_SOURCES} DIRECTORY third_party/mm3-recomp APPEND PROPERTY
    COMPILE_OPTIONS -Wno-error=implicit-function-declaration -Wno-parentheses-equality
    -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0)

# The renderer's shaders, compiled ahead of time beside the executable when
# a Metal compiler is installed (Xcode); otherwise they are compiled from the
# embedded source at launch.
set(NV2A_METALLIB "${CMAKE_CURRENT_BINARY_DIR}/third_party/mm3-recomp/nv2a.metallib")
# -DMM3_PRECOMPILE_SHADERS=OFF builds as a machine without Xcode would.
if(NOT DEFINED MM3_PRECOMPILE_SHADERS)
    execute_process(COMMAND ${CMAKE_COMMAND} -E env TOOLCHAINS=Metal xcrun -sdk macosx metal --version
                    RESULT_VARIABLE mm3_metal_rc OUTPUT_QUIET ERROR_QUIET)
    if(mm3_metal_rc EQUAL 0)
        set(MM3_PRECOMPILE_SHADERS ON)
    else()
        set(MM3_PRECOMPILE_SHADERS OFF)
    endif()
endif()
if(MM3_PRECOMPILE_SHADERS)
    message(STATUS "Metal compiler found: shaders precompiled")
else()
    message(STATUS "No Metal compiler (Xcode): shaders compile at launch from the embedded source")
endif()
if(MM3_PRECOMPILE_SHADERS)
# TOOLCHAINS=Metal: newer Xcodes ship the Metal compiler as a separate
# download (xcodebuild -downloadComponent MetalToolchain), which plain xcrun
# does not always find; naming it works either way.
add_custom_command(OUTPUT "${NV2A_METALLIB}"
    COMMAND ${CMAKE_COMMAND} -E env TOOLCHAINS=Metal
            xcrun -sdk macosx metal -std=metal3.1 -fmetal-math-mode=relaxed
            -mmacosx-version-min=${CMAKE_OSX_DEPLOYMENT_TARGET}
            -c "${NV2A_METAL_SRC}" -o "${CMAKE_CURRENT_BINARY_DIR}/nv2a.air"
    COMMAND ${CMAKE_COMMAND} -E env TOOLCHAINS=Metal
            xcrun -sdk macosx metallib "${CMAKE_CURRENT_BINARY_DIR}/nv2a.air" -o "${NV2A_METALLIB}"
    DEPENDS "${NV2A_METAL_SRC}"
    COMMENT "Compiling the NV2A Metal shaders")
add_custom_target(nv2a_metallib ALL DEPENDS "${NV2A_METALLIB}")
add_dependencies(mm3_recomp nv2a_metallib)
endif()

# Each generated source -- as the seams left it, in hooked_chunks/ when it
# has one -- is compiled from a copy with ordered accessors (ordered/), made
# at build time, so the generated code and the seams' text stay untouched.
if(MM3_TSO)
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    set(mm3_tso_script "${CMAKE_CURRENT_SOURCE_DIR}/third_party/mm3-recomp/scripts/tso_accessors.py")
    set(mm3_hooked_dir "${CMAKE_CURRENT_BINARY_DIR}/third_party/mm3-recomp/hooked_chunks")
    get_target_property(mm3_sources mm3_recomp SOURCES)
    set(mm3_sources_out "")
    set(mm3_ordered "")
    foreach(src IN LISTS mm3_sources)
        cmake_path(ABSOLUTE_PATH src BASE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/third_party/mm3-recomp"
                   NORMALIZE OUTPUT_VARIABLE abs)
        cmake_path(GET abs FILENAME name)
        cmake_path(GET abs PARENT_PATH dir)
        set(kind "")
        if(name MATCHES "^recomp_.*\\.c$")
            if(dir STREQUAL RECOMP_GEN_DIR)
                set(kind gen)
            elseif(dir STREQUAL mm3_hooked_dir)
                set(kind hooked)
            endif()
        endif()
        if(kind)
            set(out "${CMAKE_CURRENT_BINARY_DIR}/ordered/${kind}/${name}")
            add_custom_command(OUTPUT "${out}"
                COMMAND Python3::Interpreter "${mm3_tso_script}" "${abs}" "${out}"
                DEPENDS "${abs}" "${mm3_tso_script}" VERBATIM)
            foreach(prop COMPILE_DEFINITIONS COMPILE_OPTIONS INCLUDE_DIRECTORIES)
                get_source_file_property(value "${abs}" DIRECTORY third_party/mm3-recomp ${prop})
                if(value)
                    set_property(SOURCE "${out}" DIRECTORY third_party/mm3-recomp PROPERTY ${prop} "${value}")
                endif()
            endforeach()
            list(APPEND mm3_sources_out "${out}")
            list(APPEND mm3_ordered "${out}")
        else()
            list(APPEND mm3_sources_out "${src}")
        endif()
    endforeach()
    set_property(TARGET mm3_recomp PROPERTY SOURCES ${mm3_sources_out})
    add_custom_target(mm3_ordered_sources DEPENDS ${mm3_ordered})
    add_dependencies(mm3_recomp mm3_ordered_sources)
    list(LENGTH mm3_ordered mm3_ordered_n)
    message(STATUS "Guest memory ordered as x86 (MM3_TSO): ${mm3_ordered_n} generated sources")
else()
    target_compile_definitions(mm3_recomp PRIVATE RECOMP_PLAIN_ORDER)
endif()

# The source tree, for the bare executable's app icon (mac/bundle).
set_property(SOURCE mac/src/app_macos.m DIRECTORY third_party/mm3-recomp APPEND PROPERTY
    COMPILE_DEFINITIONS "MM3_BUILD_ROOT=\"${CMAKE_CURRENT_SOURCE_DIR}\"")

# build/Midtown Madness 3.app: the same executable, the shaders (when
# precompiled) and icon in Resources, ad-hoc signed. The game data belongs in
# Contents/Resources/game_files: here a link to the repository's, added after
# signing (a link out of the bundle cannot be sealed), so a rebuild stays
# quick; scripts/package.sh puts the real files there and signs over them.
if(CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET_OR_DEFAULT "${CMAKE_OSX_DEPLOYMENT_TARGET}")
else()
    set(CMAKE_OSX_DEPLOYMENT_TARGET_OR_DEFAULT "13.0")
endif()
set(MM3_APP "${CMAKE_CURRENT_BINARY_DIR}/Midtown Madness 3.app")
set(MM3_APP_METALLIB_COPY "")
set(MM3_APP_METALLIB_DEP "")
if(MM3_PRECOMPILE_SHADERS)
    set(MM3_APP_METALLIB_COPY COMMAND ${CMAKE_COMMAND} -E copy "${NV2A_METALLIB}"
                              "${MM3_APP}/Contents/Resources/")
    set(MM3_APP_METALLIB_DEP "${NV2A_METALLIB}")
endif()
configure_file(mac/bundle/Info.plist.in "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" @ONLY)
# The same Info.plist inside the executable, so the bare build-tree binary
# carries the app's identity too: system services such as controller haptics
# refuse a process without one ("Couldn't communicate with a helper
# application").
target_link_options(mm3_recomp PRIVATE
    "LINKER:-sectcreate,__TEXT,__info_plist,${CMAKE_CURRENT_BINARY_DIR}/Info.plist")
set_property(TARGET mm3_recomp APPEND PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/Info.plist")
# Signed again with the app's identifier, which binds that Info.plist (the
# linker's ad-hoc signature does not). A step of its own: a POST_BUILD rule
# cannot be attached from this directory.
add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/mm3_recomp.signed"
    COMMAND codesign --force --sign - --identifier org.mm3-port.midtown-madness-3
            "$<TARGET_FILE:mm3_recomp>"
    COMMAND ${CMAKE_COMMAND} -E touch "${CMAKE_CURRENT_BINARY_DIR}/mm3_recomp.signed"
    DEPENDS mm3_recomp "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
    COMMENT "Signing mm3_recomp with its Info.plist")
add_custom_target(mm3_signed ALL DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/mm3_recomp.signed")
add_custom_command(OUTPUT "${MM3_APP}/Contents/MacOS/mm3_recomp"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${MM3_APP}/Contents/MacOS" "${MM3_APP}/Contents/Resources"
    COMMAND ${CMAKE_COMMAND} -E rm -f "${MM3_APP}/Contents/Resources/game_files"
    COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" "${MM3_APP}/Contents/Info.plist"
    ${MM3_APP_METALLIB_COPY}
    COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_CURRENT_SOURCE_DIR}/mac/bundle/AppIcon.icns"
            "${MM3_APP}/Contents/Resources/"
    # Replaced by rename, so a copy of the game already running keeps its
    # executable (overwriting it in place kills that process).
    COMMAND ${CMAKE_COMMAND} -E copy "$<TARGET_FILE:mm3_recomp>" "${MM3_APP}/Contents/MacOS/mm3_recomp.new"
    COMMAND ${CMAKE_COMMAND} -E rename "${MM3_APP}/Contents/MacOS/mm3_recomp.new" "${MM3_APP}/Contents/MacOS/mm3_recomp"
    COMMAND codesign --force --sign - "${MM3_APP}"
    COMMAND ln -sfn "${CMAKE_CURRENT_SOURCE_DIR}/game_files" "${MM3_APP}/Contents/Resources/game_files"
    DEPENDS mm3_recomp "${CMAKE_CURRENT_BINARY_DIR}/mm3_recomp.signed" ${MM3_APP_METALLIB_DEP}
            "${CMAKE_CURRENT_SOURCE_DIR}/mac/bundle/AppIcon.icns"
            "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
    COMMENT "Packaging Midtown Madness 3.app")
add_custom_target(mm3_app ALL DEPENDS "${MM3_APP}/Contents/MacOS/mm3_recomp")

# Host checks that need no game data.
enable_testing()
add_executable(test_mmio_arm64 mac/tests/test_mmio_arm64.c)
target_link_libraries(test_mmio_arm64 PRIVATE platform)
target_include_directories(test_mmio_arm64 PRIVATE
    third_party/mm3-recomp/tools/xboxrecomp/src/platform)
add_test(NAME mmio_arm64 COMMAND test_mmio_arm64)

# The Metal renderer end to end, without game data: clear, an ubershader and
# a combiner draw, present, capture and write-back.
add_executable(test_metal_render EXCLUDE_FROM_ALL mac/tests/test_metal_render.m
    mac/src/video/nv2a_metal.m mac/src/video/fb_window_macos.m)
target_include_directories(test_metal_render PRIVATE ${XBOX_VIDEO_BACKEND_INCLUDES}
    third_party/mm3-recomp/tools/xboxrecomp/src
    third_party/mm3-recomp/tools/xboxrecomp/src/video
    third_party/mm3-recomp/tools/xboxrecomp/src/kernel)
target_link_libraries(test_metal_render PRIVATE platform ${XBOX_VIDEO_BACKEND_LIBRARIES})
if(MM3_PRECOMPILE_SHADERS)
    add_dependencies(test_metal_render nv2a_metallib)
    add_custom_command(TARGET test_metal_render POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${NV2A_METALLIB}" "$<TARGET_FILE_DIR:test_metal_render>/")
endif()

# GPU cost of the pixel shaders, without the game: bench_ps nv2a.metal keys.txt
# (keys from RECOMP_SPEC_DUMP).
add_executable(bench_ps EXCLUDE_FROM_ALL mac/tests/bench_ps.m)
target_compile_options(bench_ps PRIVATE -fobjc-arc)
target_link_libraries(bench_ps PRIVATE "-framework Metal" "-framework Foundation")

# DSP56300 core speed on a recorded frame, verified bit for bit:
# dsp_bench <capture.frame.bin> [replays] (see mac/tests/dsp_bench.c).
set(MM3_DSP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/mm3-recomp/tools/xboxrecomp/src/apu/dsp")
add_executable(dsp_bench EXCLUDE_FROM_ALL mac/tests/dsp_bench.c
    ${MM3_DSP_DIR}/interp/dsp_cpu.c ${MM3_DSP_DIR}/dsp.c ${MM3_DSP_DIR}/dsp_dma.c)
target_include_directories(dsp_bench PRIVATE ${MM3_DSP_DIR} ${MM3_DSP_DIR}/interp
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/mm3-recomp/tools/xboxrecomp/src/apu"
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/mm3-recomp/tools/xboxrecomp/src")
target_compile_definitions(dsp_bench PRIVATE
    DSP_RECOMP_INC="${CMAKE_CURRENT_BINARY_DIR}/xboxrecomp/src/apu/dsp_recomp_programs.inc")
set_property(SOURCE ${MM3_DSP_DIR}/interp/dsp_cpu.c TARGET_DIRECTORY dsp_bench APPEND PROPERTY
    COMPILE_OPTIONS -mllvm -inline-threshold=1000)
add_dependencies(dsp_bench dsp_recomp_programs)

# The Xbox memory model and trapped MMIO on this host, on a synthetic XBE.
add_executable(test_memory_layout EXCLUDE_FROM_ALL mac/tests/test_memory_layout.c)
target_link_libraries(test_memory_layout PRIVATE xboxrecomp "-Wl,-undefined,dynamic_lookup")
add_test(NAME memory_layout COMMAND test_memory_layout)
