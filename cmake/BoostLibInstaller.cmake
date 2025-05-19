cmake_minimum_required(VERSION 3.2)

include(ExternalProject)
include(GetBoostLibB2Args)
include(DownloadBoost)

# Known dependencies
set(chrono_dep system)
set(coroutine_dep context system)
set(context_dep thread)
set(filesystem_dep system)
set(graph_dep regex)
set(locale_dep system)
set(log_dep chrono date_time filesystem thread)
set(thread_dep chrono)
set(timer_dep chrono)
set(wave_dep chrono date_time filesystem thread)

function(boost_lib_installer req_boost_version req_boost_libs)
    message(STATUS "Boost Lib Installer starting.")

    # Download
    download_boost("${req_boost_version}")
    get_filename_component(req_boost_version "${install_dir}" NAME)
    message(STATUS "Boost path: ${install_dir}")
    message(STATUS "Boost version: ${req_boost_version}")
    string(REGEX MATCH "^([0-9]+)\\.([0-9]+)\\." m "${req_boost_version}")
    set(lib_postfix "${CMAKE_MATCH_1}_${CMAKE_MATCH_2}")
    message(STATUS "Boost library postfix: ${lib_postfix}")


    # Bootstrap
    if(WIN32)
        set(bootstrap bootstrap.bat)
        set(b2_command b2.exe)
        file(TO_CMAKE_PATH "${install_dir}/b2.exe" b2_path)
    else(WIN32)
        set(bootstrap ./bootstrap.sh)
        set(b2_command ./b2)
        file(TO_CMAKE_PATH "${install_dir}/b2" b2_path)
    endif(WIN32)
    if (NOT EXISTS "${b2_path}")
        message(STATUS "Invoking ${install_dir}/tools/build/${bootstrap}")
        execute_process(COMMAND "${bootstrap}" WORKING_DIRECTORY "${install_dir}/tools/build" RESULT_VARIABLE err OUTPUT_VARIABLE err_msg OUTPUT_QUIET)
        if(err)
            message(FATAL_ERROR "Bootstrap error:\n${err_msg}")
        endif(err)
        message(STATUS "Invoking ${install_dir}/${bootstrap}")
        execute_process(COMMAND "${bootstrap}" WORKING_DIRECTORY "${install_dir}" RESULT_VARIABLE err OUTPUT_VARIABLE err_msg OUTPUT_QUIET)
        if(err)
            message(FATAL_ERROR "Bootstrap error:\n${err_msg}")
        endif(err)
    else()
        message(STATUS "b2 executable found.")
    endif()

    # Process libs
    if(req_boost_libs)
        if(MSVC)
            if(CMAKE_CL_64 EQUAL 1)
                set(stage_dir stage64)
            else()
                set(stage_dir stage32)
            endif()
        else()
            set(stage_dir stage)
        endif()

        get_boots_lib_b2_args()
        message(STATUS "b2 args: ${b2Args}")

        # Resolve dependency tree
        foreach(i RANGE 4)
            set(req_boost_libs2 "")

            foreach(lib ${req_boost_libs})
                list(APPEND req_boost_libs2 ${lib})
                list(APPEND req_boost_libs2 ${${lib}_dep})
            endforeach()

            list(REMOVE_DUPLICATES req_boost_libs2)
            set(req_boost_libs "${req_boost_libs2}")
        endforeach()

        # Build all required Boost libs in one b2 call
        list(TRANSFORM req_boost_libs PREPEND "--with-")

        # Prepare build byproducts (library output files)
        set(lib_paths "")
        set(lib_map "")

        foreach(lib_arg ${req_boost_libs})
            string(REPLACE "--with-" "" lib "${lib_arg}")

            if(lib STREQUAL "test")
                set(lib_name unit_test_framework)
            else()
                set(lib_name ${lib})
            endif()

            if(MSVC)
                if(MSVC11)
                    set(compiler_name vc110)
                elseif(MSVC12)
                    set(compiler_name vc120)
                elseif(MSVC14)
                    set(compiler_name vc140)
                endif()

                set(lib_file libboost_${lib_name}-${compiler_name}-mt-${lib_postfix}.lib)
            else()
                set(LIBSUFFIX "")

                if(UNIX AND CMAKE_SIZEOF_VOID_P EQUAL 8)
                    set(LIBSUFFIX "-x64")
                endif()

                if(APPLE)
                    # Extract first letter after architecture= (e.g., 'a' from 'architecture=arm')
                    string(REGEX MATCH "architecture=([a-zA-Z])" _ "${b2Args}")
                    set(ARCHITECTURE_PREFIX "${CMAKE_MATCH_1}")

                    # Extract address model number (e.g., 64 from address-model=64)
                    string(REGEX MATCH "address-model=([0-9_]+)" _ "${b2Args}")
                    set(ADDRESS_MODEL "${CMAKE_MATCH_1}")

                    # Build lib suffix like -x64 or -a32
                    set(LIBSUFFIX "-${ARCHITECTURE_PREFIX}${ADDRESS_MODEL}")
                endif()

                if(CMAKE_BUILD_TYPE STREQUAL "Debug" OR NOT DEFINED CMAKE_BUILD_TYPE OR CMAKE_BUILD_TYPE STREQUAL "")
                    set(lib_file libboost_${lib_name}-mt-d${LIBSUFFIX}.a)
                else()
                    set(lib_file libboost_${lib_name}-mt${LIBSUFFIX}.a)
                endif()
            endif()

            set(lib_path "${install_dir}/${stage_dir}/lib/${lib_file}")
            list(APPEND lib_paths "${lib_path}")
            set(lib_map_${lib} "${lib_path}")
        endforeach()

        # b2 headers
        if(NOT EXISTS ${install_dir}/boost/)
            message(STATUS "Generating headers ...")
            execute_process(COMMAND ${b2_command} --ignore-site-config headers WORKING_DIRECTORY ${install_dir} RESULT_VARIABLE err OUTPUT_VARIABLE err_msg)

            if(err)
                message(FATAL_ERROR "b2 error:\n${err_msg}")
            endif(err)
        else()
            message(STATUS "Headers found.")
        endif()

        # Create a single ExternalProject to build all requested Boost libraries
        ExternalProject_Add(boost_all
            STAMP_DIR "${CMAKE_BINARY_DIR}/boost-${req_boost_version}"
            SOURCE_DIR "${install_dir}"
            BINARY_DIR "${install_dir}"
            CONFIGURE_COMMAND ""
            BUILD_COMMAND "${b2_command}" ${b2Args} --debug-configuration ${req_boost_libs}
            INSTALL_COMMAND ""
            BUILD_BYPRODUCTS ${lib_paths}
            LOG_BUILD ON
        )

        # Register each Boost library as an imported target that depends on boost_all
        foreach(lib_arg ${req_boost_libs})
            string(REPLACE "--with-" "" lib "${lib_arg}")

            if(lib STREQUAL "test")
                set(lib_name unit_test_framework)
            else()
                set(lib_name ${lib})
            endif()

            set(boost_lib boost_${lib})
            set(lib_path "${lib_map_${lib}}")

            add_library(${boost_lib} STATIC IMPORTED GLOBAL)
            set_target_properties(${boost_lib} PROPERTIES
                IMPORTED_LOCATION "${lib_path}"
                LINKER_LANGUAGE CXX
            )
            add_dependencies(${boost_lib} boost_all)

            # Setup CMake dependency tree for linking order
            foreach(dep_lib ${${lib}_dep})
                message(STATUS "Setting ${boost_lib} dependent on boost_${dep_lib}")
                add_dependencies(${boost_lib} boost_${dep_lib})
            endforeach()

            list(APPEND boost_libs ${boost_lib})
        endforeach()
    endif()


    if(boost_libs)
        message(STATUS "Boost libs scheduled for build: ${boost_libs}")
        set(Boost_LIBRARIES "${boost_libs}" PARENT_SCOPE)
        set(Boost_LIBRARY_DIR "${install_dir}/${stage_dir}/lib/" CACHE STRING "" FORCE)
    else()
        set(Boost_LIBRARIES "" PARENT_SCOPE)
        set(Boost_LIBRARY_DIR "" CACHE STRING "" FORCE)
    endif()

    set(Boost_INCLUDE_DIR "${install_dir}" CACHE STRING "" FORCE)
    set(Boost_INCLUDE_DIRS "${install_dir}" PARENT_SCOPE)
    set(Boost_FOUND TRUE PARENT_SCOPE)

endfunction(boost_lib_installer)