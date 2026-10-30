#!/bin/bash
# DREW-V Edge Lab: Unified VisionFive 2 & Hailo-8 Provisioning Engine
# Usage: ./forge-node.sh [flags]

set -e

# Prevent running entire script as root to avoid permission leaks in user environments
if [ "$EUID" -eq 0 ]; then
    echo "[-] Do NOT run this script with sudo."
    echo "    Run as your standard user (e.g., ./forge-node.sh --all --add-drewv-labs)."
    echo "    The script will escalate to sudo internally when needed."
    exit 1
fi

# Keep sudo credentials alive during long compilations
sudo -v
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
SUDO_PID=$!
trap 'kill $SUDO_PID 2>/dev/null' EXIT

# ==============================================================================
# ARGUMENT PARSER
# ==============================================================================
RUN_CORE=false
RUN_DRIVER=false
RUN_API=false
RUN_UV=false
RUN_TAILSCALE=false
RUN_MENDELCODE=false
RUN_CAROLINEV=false

# Default to generic core (--all behavior) if no arguments provided
if [ $# -eq 0 ]; then
    RUN_CORE=true
    RUN_DRIVER=true
    RUN_API=true
    RUN_UV=true
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            RUN_CORE=true
            RUN_DRIVER=true
            RUN_API=true
            RUN_UV=true
            ;;
        --system-core) RUN_CORE=true ;;
        --hailo-driver) RUN_DRIVER=true ;;
        --hailo-api) RUN_API=true ;;
        --astral-uv) RUN_UV=true ;;
        --tailscale) RUN_TAILSCALE=true ;;
        --mendelcode)
            RUN_UV=true
            RUN_MENDELCODE=true
            ;;
        --caroline-v)
            RUN_UV=true
            RUN_CAROLINEV=true
            ;;
        *)
            echo "Usage: ./forge-node.sh [--all | --mendelcode | --caroline-v | --tailscale]"
            echo "Standalone Stages: [--system-core | --hailo-driver | --hailo-api | --astral-uv | --tailscale]"
            exit 1
            ;;
    esac
    shift
done

# ==============================================================================
# CORE OS & LOCALE PROVISIONING
# ==============================================================================
run_core() {
    echo "=== System Locales, Sources & CLI De-bloating ==="

    cat << 'EOF' | sudo tee /etc/apt/sources.list > /dev/null
deb [trusted=yes] http://deb.debian.org/debian unstable main
deb https://debianrepo-t.starfivetech.com starfive-debian main
EOF

    sudo apt update -y
    sudo apt install -y locales
    sudo sed -i 's/^# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    sudo locale-gen
    sudo update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

    sudo rm -rf /var/lib/apt/lists/*
    sudo apt clean
    sudo apt update -y
    sudo apt install -y debian-archive-keyring

    sudo sed -i 's/\[trusted=yes\] //' /etc/apt/sources.list
    sudo apt update -y

    sudo systemctl set-default multi-user.target
    sudo apt purge -y "weston*" "wayland*" "x11-common" "libx11-*" "libgtk*" "lightdm*" "task-desktop" "plymouth"
    sudo apt autoremove --purge -y
    sudo apt clean

    # --- T64 Migration Unblock Patch ---
    echo "=== Unblocking libcurl t64 transition dependencies ==="
    if dpkg -l | grep -q "libcurl3-gnutls"; then
        sudo dpkg --remove --force-depends libcurl3-gnutls:riscv64 2>/dev/null || true
    fi

    sudo apt modernize-sources
    sudo DEBIAN_FRONTEND=noninteractive apt full-upgrade \
        -o Dpkg::Options::="--force-overwrite" \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" -y

    sudo apt install -y \
        build-essential dkms pciutils git curl wget htop jq tmux \
        linux-headers-$(uname -r) \
        golang-go \
        cmake python3-dev pybind11-dev python3-setuptools python3-wheel

    echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/010_$USER-nopasswd > /dev/null
    sudo chmod 0440 /etc/sudoers.d/010_$USER-nopasswd

    echo "=== Core OS Baseline Provisioned ==="
    echo "If a new kernel was installed, reboot now and run './forge-node.sh --driver' next."
}

# ==============================================================================
# HAILO-8 PCIE DRIVER & FIRMWARE
# ==============================================================================
run_driver() {
    echo "=== Compiling Hailo-8 PCIe Driver & Firmware ==="
    cd "$HOME"
    rm -rf hailort-drivers
    git clone -b hailo8 https://github.com/hailo-ai/hailort-drivers.git

    cd hailort-drivers/linux/pcie
    make all
    sudo make install

    cd ../../
    ./download_firmware.sh
    sudo mkdir -p /lib/firmware/hailo
    sudo mv hailo8_fw*.bin /lib/firmware/hailo/hailo8_fw.bin

    sudo rmmod hailo_pci 2>/dev/null || true
    sudo modprobe hailo_pci

    echo "=== Hailo-8 Kernel Driver Online ==="
    dmesg | grep -i hailo || true
}

# ==============================================================================
# HAILORT C++ API & PYTHON WHEEL
# ==============================================================================
run_api() {
    echo "=== Compiling HailoRT C++ Core & pyhailort Wheel ==="
    cd "$HOME"
    rm -rf hailort
    git clone https://github.com/hailo-ai/hailort.git
    cd hailort

    cmake -S. -Bbuild -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    cmake --build build -j$(nproc)

    sudo cmake --install build
    sudo ldconfig

    cd "$HOME/hailort/hailort/libhailort/bindings/python/platform"
    python3 setup.py bdist_wheel

    echo "=== HailoRT API & Python Wheel Compiled ==="
    ls -lh dist/*.whl
}

# ==============================================================================
# TAILSCALE SECURE MESH
# ==============================================================================
run_tailscale() {
    echo "=== Installing Tailscale & Enabling Zero-Trust SSH ==="

    if ! command -v tailscale &> /dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh
    else
        echo "Tailscale is already installed. Updating..."
        sudo tailscale update || true
    fi

    echo "Configuring userspace networking fallback..."
    if grep -q "^FLAGS=" /etc/default/tailscaled 2>/dev/null; then
        sudo sed -i 's/^FLAGS=.*/FLAGS="--tun=userspace-networking"/' /etc/default/tailscaled
    else
        echo 'FLAGS="--tun=userspace-networking"' | sudo tee -a /etc/default/tailscaled > /dev/null
    fi

    # Restart the daemon to apply the new flags before attempting to authenticate
    echo "Restarting Tailscale daemon..."
    sudo systemctl restart tailscaled

    echo "Initiating interactive authentication with SSH enabled..."
    sudo tailscale up --ssh

    echo "=== Tailscale Provisioning Complete! ==="
    echo "Run 'tailscale ip -4' to get your routing address."
}

# ==============================================================================
# ASTRAL UV
# ==============================================================================
run_uv() {
    echo "=== Installing Astral uv & Scaffolding DREW-V Lab Environments (MendelCode, Caroline-V) ==="

    if ! command -v uv &> /dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.local/bin:$PATH"
    fi
}

# ==============================================================================
# Hailort Wheelhouse
# ==============================================================================
run_hailort_wheelhouse() {
    WHEEL_PATH=$(find "$HOME/hailort/hailort/libhailort/bindings/python/platform/dist" -name "*.whl" | head -n 1)
    if [ -z "$WHEEL_PATH" ]; then
        echo "[-] Error: Could not locate compiled pyhailort .whl file. Did you run the API generation phase?"
        exit 1
    fi

    uv pip install "$WHEEL_PATH"
}

# ==============================================================================
# DREW-V Labs: MendelCode Environment
# ==============================================================================
run_mendelcode() {
    cd "$HOME"
    mkdir -p .venvs
    if [ -z "$(ls .venvs | grep mendelcode-env)" ]; then
        uv venv .venvs/mendelcode-env
    fi
    source .venvs/mendelcode-env/bin/activate

    run_hailort_wheelhouse
    python -c "from hailo_platform import VDevice; print('[✓] Hailo-8 User-Space API successfully imported inside .venvs/mendelcode-env!')"
}

# ==============================================================================
# DREW-V Labs: Caroline-V Environment
# ==============================================================================
run_carolinev() {
    cd "$HOME"
    mkdir -p .venvs
    if [ -z "$(ls .venvs | grep caroline-v-env)" ]; then
        uv venv .venvs/caroline-v-env
    fi
    source .venvs/caroline-v-env/bin/activate

    run_hailort_wheelhouse
    python -c "from hailo_platform import VDevice; print('[✓] Hailo-8 User-Space API successfully imported inside .venvs/caroline-v-env!')"
}

# ==============================================================================
# EXECUTION ROUTER
# ==============================================================================
if [ "$RUN_CORE" = true ]; then run_core; fi
if [ "$RUN_DRIVER" = true ]; then run_driver; fi
if [ "$RUN_API" = true ]; then run_api; fi
if [ "$RUN_UV" = true ]; then run_uv; fi
if [ "$RUN_MENDELCODE" = true ]; then run_mendelcode; fi
if [ "$RUN_CAROLINEV" = true ]; then run_carolinev; fi
if [ "$RUN_TAILSCALE" = true ]; then run_tailscale; fi

echo "=== Operation Complete! ==="

read -p "Reboot? [y/n] " REBOOT
if [ "$REBOOT" = "y" ]; then sudo reboot; fi
