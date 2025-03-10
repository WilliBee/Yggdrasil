# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
using BinaryBuilder, Pkg

name = "Qt6Base"
version = v"6.4.2"

# Set this to true first when updating the version. It will build only for the host (linux musl).
# After that JLL is in the registyry, set this to false to build for the other platforms, using
# this same package as host build dependency.
const host_build = false

# Collection of sources required to build qt6
sources = [
    ArchiveSource("https://download.qt.io/official_releases/qt/$(version.major).$(version.minor)/$version/submodules/qtbase-everywhere-src-$version.tar.xz",
                  "a88bc6cedbb34878a49a622baa79cace78cfbad4f95fdbd3656ddb21c705525d"),
    ArchiveSource("https://github.com/phracker/MacOSX-SDKs/releases/download/11.0-11.1/MacOSX11.1.sdk.tar.xz",
                  "9b86eab03176c56bb526de30daa50fa819937c54b280364784ce431885341bf6"),
    ArchiveSource("https://sourceforge.net/projects/mingw-w64/files/mingw-w64/mingw-w64-release/mingw-w64-v10.0.0.tar.bz2",
                  "ba6b430aed72c63a3768531f6a3ffc2b0fde2c57a3b251450dcf489a894f0894")
]

script = raw"""
cd $WORKSPACE/srcdir

BIN_DIR="/opt/bin/${bb_full_target}"

mkdir build
cd build/

qtsrcdir=`ls -d ../qtbase-everywhere-src-*`

commonoptions=" \
-opensource -confirm-license \
-openssl-linked  -nomake examples -release \
"

commoncmakeoptions="-DCMAKE_PREFIX_PATH=${prefix} -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TARGET_TOOLCHAIN} -DQT_HOST_PATH=$host_prefix -DQT_FEATURE_openssl_linked=ON"

export LD_LIBRARY_PATH=$host_libdir:$LD_LIBRARY_PATH
export OPENSSL_LIBS="-L${libdir} -lssl -lcrypto"

sed -i 's/"-march=haswell"/"-mavx2" "-mf16c" "-mfma" "-mbmi2" "-mlzcnt"/' $qtsrcdir/cmake/QtCompilerOptimization.cmake

case "$bb_full_target" in

    x86_64-linux-musl-libgfortran5-cxx11)
        ../qtbase-everywhere-src-*/configure -prefix $prefix $commonoptions -fontconfig -- -DCMAKE_PREFIX_PATH=${prefix} -DCMAKE_TOOLCHAIN_FILE=${CMAKE_HOST_TOOLCHAIN}
    ;;

    *mingw*)        
        cd $WORKSPACE/srcdir/mingw*/mingw-w64-headers
        ./configure --prefix=/opt/$target/$target/sys-root --enable-sdk=all --host=$target
        make install
        
        
        cd ../mingw-w64-crt/
        if [ ${target} == "i686-w64-mingw32" ]; then
            _crt_configure_args="--disable-lib64 --enable-lib32"
        elif [ ${target} == "x86_64-w64-mingw32" ]; then
            _crt_configure_args="--disable-lib32 --enable-lib64"
        fi
        ./configure --prefix=/opt/$target/$target/sys-root --enable-sdk=all --host=$target --enable-wildcard ${_crt_configure_args}
        make -j${nproc}
        make install
        
        cd ../mingw-w64-libraries/winpthreads
        ./configure --prefix=/opt/$target/$target/sys-root --host=$target --enable-static --enable-shared
        make -j${nproc}
        make install

        cd $WORKSPACE/srcdir/build
        ../qtbase-everywhere-src-*/configure -prefix $prefix $commonoptions -opengl dynamic -- $commoncmakeoptions
    ;;

    *apple-darwin*)
        apple_sdk_root=$WORKSPACE/srcdir/MacOSX11.1.sdk
        sed -i "s!/opt/x86_64-apple-darwin14/x86_64-apple-darwin14/sys-root!$apple_sdk_root!" $CMAKE_TARGET_TOOLCHAIN
        if [[ "${target}" == x86_64-* ]]; then
            export LDFLAGS="-L${libdir}/darwin -lclang_rt.osx"
            deployarg="-DCMAKE_OSX_DEPLOYMENT_TARGET=10.14"
        fi
        ../qtbase-everywhere-src-*/configure -prefix $prefix $commonoptions -- $commoncmakeoptions -DCMAKE_SYSROOT=$apple_sdk_root -DCMAKE_FRAMEWORK_PATH=$apple_sdk_root/System/Library/Frameworks $deployarg -DCUPS_INCLUDE_DIR=$apple_sdk_root/usr/include -DCUPS_LIBRARIES=$apple_sdk_root/usr/lib/libcups.tbd
    ;;

    *freebsd*)
        sed -i 's/-Wl,--no-undefined//' $qtsrcdir/mkspecs/freebsd-clang/qmake.conf
        sed -i 's/-Wl,--no-undefined//' $qtsrcdir/cmake/QtFlagHandlingHelpers.cmake
        ../qtbase-everywhere-src-*/configure -prefix $prefix $commonoptions -fontconfig -- $commoncmakeoptions -DQT_PLATFORM_DEFINITION_DIR=$host_prefix/mkspecs/freebsd-clang
    ;;

    *)
        echo "#define ELFOSABI_GNU 3" >> /opt/$target/$target/sys-root/usr/include/elf.h
        echo "#define EM_AARCH64 183" >> /opt/$target/$target/sys-root/usr/include/elf.h
        echo "#define EM_BLACKFIN 106" >> /opt/$target/$target/sys-root/usr/include/elf.h
        ../qtbase-everywhere-src-*/configure -prefix $prefix $commonoptions -fontconfig -- $commoncmakeoptions
    ;;
esac

cmake --build . --parallel ${nproc}
cmake --install .
install_license $WORKSPACE/srcdir/qtbase-everywhere-src-*/LICENSES/LGPL-3.0-only.txt
"""

# These are the platforms we will build for by default, unless further
# platforms are passed in on the command line
if host_build
    platforms = [Platform("x86_64", "linux",cxxstring_abi=:cxx11,libc="musl")]
    platforms_macos = AbstractPlatform[]
else
    platforms = expand_cxxstring_abis(filter(!Sys.isapple, supported_platforms()))
    filter!(p -> arch(p) != "armv6l", platforms) # No OpenGL on armv6
    platforms_macos = [ Platform("x86_64", "macos"), Platform("aarch64", "macos") ]
end

# The products that we will ensure are always built
products = [
    LibraryProduct(["Qt6Concurrent", "libQt6Concurrent", "QtConcurrent"], :libqt6concurrent),
    LibraryProduct(["Qt6Core", "libQt6Core", "QtCore"], :libqt6core),
    LibraryProduct(["Qt6DBus", "libQt6DBus", "QtDBus"], :libqt6dbus),
    LibraryProduct(["Qt6Gui", "libQt6Gui", "QtGui"], :libqt6gui),
    LibraryProduct(["Qt6Network", "libQt6Network", "QtNetwork"], :libqt6network),
    LibraryProduct(["Qt6OpenGL", "libQt6OpenGL", "QtOpenGL"], :libqt6opengl),
    LibraryProduct(["Qt6PrintSupport", "libQt6PrintSupport", "QtPrintSupport"], :libqt6printsupport),
    LibraryProduct(["Qt6Sql", "libQt6Sql", "QtSql"], :libqt6sql),
    LibraryProduct(["Qt6Test", "libQt6Test", "QtTest"], :libqt6test),
    LibraryProduct(["Qt6Widgets", "libQt6Widgets", "QtWidgets"], :libqt6widgets),
    LibraryProduct(["Qt6Xml", "libQt6Xml", "QtXml"], :libqt6xml),
]

products_macos = [
    FrameworkProduct("QtConcurrent", :libqt6concurrent),
    FrameworkProduct("QtCore", :libqt6core),
    FrameworkProduct("QtDBus", :libqt6dbus),
    FrameworkProduct("QtGui", :libqt6gui),
    FrameworkProduct("QtNetwork", :libqt6network),
    FrameworkProduct("QtOpenGL", :libqt6opengl),
    FrameworkProduct("QtPrintSupport", :libqt6printsupport),
    FrameworkProduct("QtSql", :libqt6sql),
    FrameworkProduct("QtTest", :libqt6test),
    FrameworkProduct("QtWidgets", :libqt6widgets),
    FrameworkProduct("QtXml", :libqt6xml),
]

# We must use the same version of LLVM for the build toolchain and LLVMCompilerRT_jll
llvm_version = v"13.0.1"

# Dependencies that must be installed before this package can be built
dependencies = [
    BuildDependency("Xorg_libX11_jll"),
    Dependency("Xorg_libXext_jll"),
    BuildDependency("Xorg_xproto_jll"),
    BuildDependency("Xorg_glproto_jll"),
    Dependency("Xorg_libxcb_jll"),
    Dependency("Xorg_xcb_util_wm_jll"),
    Dependency("Xorg_xcb_util_image_jll"),
    Dependency("Xorg_xcb_util_keysyms_jll"),
    Dependency("Xorg_xcb_util_renderutil_jll"),
    BuildDependency("Xorg_kbproto_jll"),
    BuildDependency("Xorg_renderproto_jll"),
    Dependency("Xorg_libXrender_jll"),
    Dependency("xkbcommon_jll"),
    Dependency("Libglvnd_jll"),
    Dependency("Fontconfig_jll"),
    Dependency("Glib_jll", v"2.59.0"; compat="2.59.0"),
    Dependency("Zlib_jll"),
    Dependency("CompilerSupportLibraries_jll"),
    Dependency("OpenSSL_jll"; compat="1.1.10"),
    BuildDependency(PackageSpec(name="LLVM_full_jll", version=v"11.0.1")),
    BuildDependency(PackageSpec(name="LLVMCompilerRT_jll", uuid="4e17d02c-6bf5-513e-be62-445f41c75a11", version=llvm_version);
                    platforms=filter(p -> Sys.isapple(p) && arch(p) == "x86_64", platforms_macos)),
]

if !host_build
    push!(dependencies, HostBuildDependency("Qt6Base_jll"))
end

include("../../fancy_toys.jl")

@static if !host_build
    if any(should_build_platform.(triplet.(platforms_macos)))
        build_tarballs(ARGS, name, version, sources, script, platforms_macos, products_macos, dependencies; preferred_gcc_version = v"9", preferred_llvm_version=llvm_version, julia_compat="1.6")
    end
end
if any(should_build_platform.(triplet.(platforms)))
    build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies; preferred_gcc_version = v"9", preferred_llvm_version=llvm_version, julia_compat="1.6")
end
