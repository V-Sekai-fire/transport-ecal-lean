#!/bin/sh
# Build eCAL's core and C binding in .ecal/, at the pinned tag, without its apps, Qt, HDF5,
# protobuf or samples.
set -eu
TAG=v6.1.1
COMMIT=bf0bc5734dd31c6315ebad907c92c2bb1edc1851
cd "$(dirname "$0")/.."
if [ ! -d .ecal/src ]; then
	git clone -q --depth 1 -b "$TAG" https://github.com/eclipse-ecal/ecal .ecal/src
fi
got=$(git -C .ecal/src rev-parse HEAD)
[ "$got" = "$COMMIT" ] || { echo "eCAL $TAG is $got, expected $COMMIT" >&2; exit 1; }
git -C .ecal/src submodule update --init --depth 1 \
	thirdparty/asio/asio thirdparty/ecaludp/ecaludp thirdparty/tcp_pubsub/tcp_pubsub \
	thirdparty/recycle/recycle thirdparty/tclap/tclap thirdparty/tsl-robin-map/tsl-robin-map \
	thirdparty/yaml-cpp/yaml-cpp thirdparty/spdlog/spdlog thirdparty/termcolor/termcolor \
	thirdparty/protozero/protozero thirdparty/tinyxml2/tinyxml2 >/dev/null
cmake -S .ecal/src -B .ecal/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_PROJECT_TOP_LEVEL_INCLUDES=cmake/submodule_dependencies.cmake \
	-DECAL_USE_HDF5=OFF -DECAL_USE_QT=OFF -DECAL_USE_CURL=OFF -DECAL_USE_FTXUI=OFF \
	-DECAL_USE_PROTOBUF=OFF -DECAL_BUILD_APPS=OFF -DECAL_BUILD_APP_SDK=OFF -DECAL_BUILD_SAMPLES=OFF \
	-DECAL_BUILD_TIMEPLUGINS=OFF -DECAL_BUILD_C_BINDING=ON -DECAL_BUILD_TESTS=OFF \
	-DECAL_CORE_CONFIGURATION=OFF -DECAL_INSTALL_SAMPLE_SOURCES=OFF \
	-DECAL_CPACK_PACK_WITH_INNOSETUP=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null
ninja -C .ecal/build core_c >/dev/null
ls .ecal/build/lib/ | grep -E "ecal_core"
