if(CONFIG_FPEMU)
  set(FPEMU_DIR ${CMAKE_CURRENT_LIST_DIR}/..)
  set(SF ${FPEMU_DIR}/softfloat/source)

  # Only the operations fpemu uses (shared with the Makefile).
  file(STRINGS ${FPEMU_DIR}/softfloat-sources.txt SF_SOURCES)

  zephyr_library_named(fpemu)
  foreach(f ${SF_SOURCES})
    zephyr_library_sources(${FPEMU_DIR}/softfloat/${f})
  endforeach()
  zephyr_library_sources(
    ${FPEMU_DIR}/src/fpemu.c
    ${FPEMU_DIR}/src/zephyr/fpemu_zephyr.c
    ${FPEMU_DIR}/src/zephyr/fpemu_trap.S)
  zephyr_library_include_directories(
    ${FPEMU_DIR}/softfloat-platform ${SF}/RISCV ${SF}/include)
  zephyr_include_directories(${FPEMU_DIR}/include)
  # SoftFloat's rounding mode and flags become per thread, like the F/D state.
  zephyr_library_compile_definitions(SOFTFLOAT_FAST_INT64 THREAD_LOCAL=__thread)
  zephyr_library_compile_options(-Wno-unused-parameter -Wno-sign-compare)
endif()
