#!/bin/bash
# Build and install AMD XDNA NPU support (XRT + amdxdna DKMS driver) on
# Nobara Linux (Fedora-based). Tested on Nobara 44, kernel 7.1.4,
# Ryzen AI Max+ 395 (Strix Halo, device id 1022:17f0).
#
# Usage: ./setup.sh
# Requires: passwordless-or-interactive sudo (you'll be prompted), ~10GB
# free disk space in $SRC_DIR, and a working internet connection.
set -euo pipefail

SRC_DIR="${SRC_DIR:-$HOME/src/xdna-driver}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Cloning amd/xdna-driver into $SRC_DIR"
if [ ! -d "$SRC_DIR" ]; then
  git clone --recursive https://github.com/amd/xdna-driver.git "$SRC_DIR"
else
  echo "    already present, skipping clone"
fi

echo "==> Applying Nobara flavor-detection patch"
cd "$SRC_DIR/xrt"
if ! git apply --check "$REPO_DIR/patches/0001-nobara-flavor-as-fedora.patch" 2>/dev/null; then
  echo "    patch already applied or doesn't apply cleanly, check manually"
else
  git apply "$REPO_DIR/patches/0001-nobara-flavor-as-fedora.patch"
fi

echo "==> Installing build dependencies (sudo required)"
cd "$SRC_DIR"
# The upstream tools/amdxdna_deps.sh doesn't recognize "nobara" as an OS
# flavor and its "redhat-lsb" package collides with Nobara's own
# lsb_release package. Install the Fedora dependency list directly instead,
# skipping redhat-lsb (Nobara ships an equivalent already).
FD_LIST=(
  boost-devel boost-filesystem boost-program-options boost-static cmake
  cppcheck curl dkms dmidecode elfutils-devel elfutils-libs gcc gcc-c++ gdb
  git glibc-static gnuplot gnutls-devel gtest-devel json-glib-devel
  libcurl-devel libdrm-devel libffi-devel libjpeg-turbo-devel libpng12-devel
  libstdc++-static libtiff-devel libudev-devel libuuid-devel libyaml-devel
  lm_sensors make ocl-icd ocl-icd-devel opencl-headers opencv openssl-devel
  pciutils perl pkgconf-pkg-config protobuf-compiler protobuf-devel python3
  python3-devel python3-pip python3-sphinx rapidjson-devel rpm-build strace
  systemd-devel systemtap-sdt-devel unzip zlib-static
  "kernel-devel-$(uname -r)" kernel-headers
)
sudo dnf install -y "${FD_LIST[@]}"
sudo dnf install -y jq pybind11-devel python3-pybind11 rocm-hip-devel

echo "==> Building XRT (base + npu)"
cd "$SRC_DIR/xrt/build"
./build.sh -npu -opt -noctest
# -noctest skips the aiebu submodule's own CTest suite. One test there
# (aie2ps_eff_net_coal_compareelf) fails on this setup and isn't related to
# actual NPU functionality; without -noctest, `set -e` aborts before
# packaging is reached.

echo "==> Installing XRT RPMs (sudo required)"
sudo dnf install -y "$SRC_DIR"/xrt/build/Release/xrt_*-base.rpm \
                     "$SRC_DIR"/xrt/build/Release/xrt_*-base-devel.rpm \
                     "$SRC_DIR"/xrt/build/Release/xrt_*-npu.rpm

echo "==> Building the XDNA driver plugin (amdxdna.ko + XRT shim)"
cd "$SRC_DIR/build"
./build.sh -release

echo "==> Installing the XDNA plugin RPM (sudo required, builds+loads amdxdna.ko via DKMS)"
sudo dnf install -y "$SRC_DIR"/build/Release/xrt_plugin.*-amdxdna.rpm

echo "==> Installing memlock limits (Fedora/Nobara default is too low for NPU BO allocation)"
sudo mkdir -p /etc/security/limits.d
sudo cp "$REPO_DIR/config/99-amdxdna.limits.conf" /etc/security/limits.d/99-amdxdna.conf
sudo mkdir -p /etc/systemd/system/user@.service.d
sudo cp "$REPO_DIR/config/99-amdxdna-memlock.service.conf" /etc/systemd/system/user@.service.d/99-amdxdna-memlock.conf
sudo systemctl daemon-reload

cat <<'EOF'

==> Done.

IMPORTANT: the memlock limit change only applies to NEW login sessions.
Log out and back in (or reboot) before running xrt-smi as your normal user,
otherwise "xrt-smi examine"/"validate" will fail with:
  mmap(...) failed (err=-11): Resource temporarily unavailable

To validate:
  source /opt/xilinx/xrt/setup.sh
  xrt-smi examine
  xrt-smi validate
EOF
