# CMake generated Testfile for 
# Source directory: /Users/adhir/src/mm3-port/third_party/mm3-recomp/tools/xboxrecomp/tests/dsp
# Build directory: /Users/adhir/src/mm3-port/build-dsptests
# 
# This file includes the relevant testing commands required for 
# testing this directory and lists subdirectories to be tested as well.
add_test("dsp_cpu" "/Users/adhir/src/mm3-port/build-dsptests/dsp_cpu_test")
set_tests_properties("dsp_cpu" PROPERTIES  _BACKTRACE_TRIPLES "/Users/adhir/src/mm3-port/third_party/mm3-recomp/tools/xboxrecomp/tests/dsp/CMakeLists.txt;17;add_test;/Users/adhir/src/mm3-port/third_party/mm3-recomp/tools/xboxrecomp/tests/dsp/CMakeLists.txt;0;")
add_test("dsp_disasm" "/Users/adhir/src/mm3-port/build-dsptests/dsp_disasm_test")
set_tests_properties("dsp_disasm" PROPERTIES  _BACKTRACE_TRIPLES "/Users/adhir/src/mm3-port/third_party/mm3-recomp/tools/xboxrecomp/tests/dsp/CMakeLists.txt;21;add_test;/Users/adhir/src/mm3-port/third_party/mm3-recomp/tools/xboxrecomp/tests/dsp/CMakeLists.txt;0;")
add_test("dsp_interrupt_fastpath" "/Users/adhir/src/mm3-port/build-dsptests/dsp_interrupt_fastpath_test")
set_tests_properties("dsp_interrupt_fastpath" PROPERTIES  _BACKTRACE_TRIPLES "/Users/adhir/src/mm3-port/third_party/mm3-recomp/tools/xboxrecomp/tests/dsp/CMakeLists.txt;25;add_test;/Users/adhir/src/mm3-port/third_party/mm3-recomp/tools/xboxrecomp/tests/dsp/CMakeLists.txt;0;")
add_test("dsp_clipped_capture" "/opt/homebrew/bin/cmake" "-E" "env" "RECOMP_DSP_FRAME_DUMP=/Users/adhir/src/mm3-port/build-dsptests/clipped-frame" "RECOMP_DSP_CAPTURE_CLIPPED=1" "/Users/adhir/src/mm3-port/build-dsptests/dsp_clipped_capture_test")
set_tests_properties("dsp_clipped_capture" PROPERTIES  FIXTURES_SETUP "clipped_frame" _BACKTRACE_TRIPLES "/Users/adhir/src/mm3-port/third_party/mm3-recomp/tools/xboxrecomp/tests/dsp/CMakeLists.txt;111;add_test;/Users/adhir/src/mm3-port/third_party/mm3-recomp/tools/xboxrecomp/tests/dsp/CMakeLists.txt;0;")
add_test("dsp_clipped_replay" "/Users/adhir/src/mm3-port/build-dsptests/dsp_frame_replay" "/Users/adhir/src/mm3-port/build-dsptests/clipped-frame.ep.frame.bin")
set_tests_properties("dsp_clipped_replay" PROPERTIES  FIXTURES_REQUIRED "clipped_frame" _BACKTRACE_TRIPLES "/Users/adhir/src/mm3-port/third_party/mm3-recomp/tools/xboxrecomp/tests/dsp/CMakeLists.txt;115;add_test;/Users/adhir/src/mm3-port/third_party/mm3-recomp/tools/xboxrecomp/tests/dsp/CMakeLists.txt;0;")
add_test("dsp_recomp_replay" "/Users/adhir/src/mm3-port/build-dsptests/dsp_recomp_frame_replay" "/Users/adhir/src/mm3-port/build-dsptests/recomp/clipped-frame.ep.frame.bin")
set_tests_properties("dsp_recomp_replay" PROPERTIES  _BACKTRACE_TRIPLES "/Users/adhir/src/mm3-port/third_party/mm3-recomp/tools/xboxrecomp/tests/dsp/CMakeLists.txt;145;add_test;/Users/adhir/src/mm3-port/third_party/mm3-recomp/tools/xboxrecomp/tests/dsp/CMakeLists.txt;0;")
