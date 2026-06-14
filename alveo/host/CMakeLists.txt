cmake_minimum_required(VERSION 3.10)
project(krnl_namegen_host CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
set(CMAKE_CXX_FLAGS_RELEASE "-O2")

# XRT install (set up by: source /opt/xilinx/xrt/setup.sh, which exports XILINX_XRT).
set(XRT_ROOT "$ENV{XILINX_XRT}")
if(XRT_ROOT STREQUAL "")
  set(XRT_ROOT "/opt/xilinx/xrt")
endif()
message(STATUS "Using XRT at ${XRT_ROOT}")

if(NOT EXISTS "${XRT_ROOT}/include/xrt/xrt_kernel.h")
  message(WARNING
    "XRT headers not found under ${XRT_ROOT}/include. "
    "Run 'source /opt/xilinx/xrt/setup.sh' (sets XILINX_XRT) before cmake.")
endif()

add_executable(host host.cpp)
target_include_directories(host PRIVATE ${XRT_ROOT}/include)
target_link_directories(host PRIVATE ${XRT_ROOT}/lib)
# xrt_coreutil = native C++ XRT API (xrt::device/kernel/bo/run); uuid for the xclbin UUID;
# pthread for the XRT runtime threads our async runs schedule on.
target_link_libraries(host PRIVATE xrt_coreutil uuid pthread)

# Optional convenience: `cmake --build . --target run-verify` reminder (no XRT here to run).
add_custom_target(print-usage
  COMMAND ${CMAKE_COMMAND} -E echo
    "run: ./host <xclbin> [--records N --iters K --temp T --greedy --cus N --buffers N --verify]")
