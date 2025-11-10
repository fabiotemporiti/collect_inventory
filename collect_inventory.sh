#!/usr/bin/env bash
#
# Collects OS and hardware information and stores it in a timestamped report.
# Can be fetched remotely, e.g.:
#   curl -fsSL https://example.com/collect_inventory.sh | bash

set -u
IFS=$'\n\t'

SCRIPT_LABEL="collect_inventory"
BASE_COMMANDS=(hostname uname uptime lsblk lscpu awk sed grep cat)

declare -A CMD_PACKAGE_MAP=(
  [lsblk]="util-linux"
  [lscpu]="util-linux"
  [lspci]="pciutils"
  [ip]="iproute2"
  [dmidecode]="dmidecode"
)

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

print_section() {
  printf "\n== %s ==\n" "$1"
}

print_kv() {
  local key=$1
  local value=${2:-"n/a"}
  printf "  %-18s %s\n" "${key}:" "${value}"
}

usage() {
  cat <<'EOF'
Usage: collect_inventory.sh [--no-network] [--no-gpu] [--skip-install]

Creates a hardware/OS inventory report saved to a timestamped .txt file.
  --no-network     Skip interface details (avoid needing iproute2).
  --no-gpu         Skip GPU detection (avoid needing pciutils).
  --skip-install   Do not attempt to install missing helper packages.
  -h, --help       Show this help text.
EOF
}

detect_pkg_manager() {
  if command_exists apt; then
    echo "apt"
  elif command_exists apt-get; then
    echo "apt-get"
  elif command_exists dnf; then
    echo "dnf"
  elif command_exists yum; then
    echo "yum"
  elif command_exists pacman; then
    echo "pacman"
  elif command_exists zypper; then
    echo "zypper"
  else
    echo ""
  fi
}

APT_UPDATED=false
prompt_install() {
  local cmd=$1
  local pkg=$2
  local pm=$3

  if [[ -z $pm ]]; then
    echo "Missing command '$cmd'. Install package '$pkg' manually and rerun." >&2
    return
  fi

  read -r -p "Install package '$pkg' with $pm to enable '$cmd'? [y/N]: " answer
  case $answer in
    [yY][eE][sS]|[yY])
      case $pm in
        apt|apt-get)
          if [[ $APT_UPDATED == false ]]; then
            sudo "$pm" update
            APT_UPDATED=true
          fi
          sudo "$pm" install "$pkg"
          ;;
        dnf|yum|zypper)
          sudo "$pm" install "$pkg"
          ;;
        pacman)
          sudo pacman -Sy "$pkg"
          ;;
        *)
          echo "Package manager '$pm' not handled automatically. Install '$pkg' manually."
          ;;
      esac
      ;;
    *)
      echo "Skipping installation of '$pkg'. Some sections may be incomplete." >&2
      ;;
  esac
}

ensure_command() {
  local cmd=$1
  local allow_install=$2
  if command_exists "$cmd"; then
    return 0
  fi
  local pkg=${CMD_PACKAGE_MAP[$cmd]:-"$cmd"}
  echo "Dependency '$cmd' is missing." >&2
  if [[ $allow_install == true ]]; then
    prompt_install "$cmd" "$pkg" "$PKG_MANAGER"
    if ! command_exists "$cmd"; then
      echo "  -> '$cmd' still unavailable after attempted install." >&2
    fi
  fi
}

os_info() {
  print_section "Operating System"

  local hostname kernel arch
  hostname=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo "n/a")
  kernel=$(uname -sr 2>/dev/null || echo "n/a")
  arch=$(uname -m 2>/dev/null || echo "")

  print_kv "Hostname" "$hostname"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    print_kv "Distribution" "${PRETTY_NAME:-$NAME $VERSION_ID}"
  else
    print_kv "Distribution" "Unknown"
  fi
  print_kv "Kernel" "$kernel ${arch}"
  print_kv "Uptime" "$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo "n/a")"
  print_kv "Timezone" "$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "n/a")"
}

hardware_info() {
  print_section "Hardware"

  local vendor model bios serial_file serial
  vendor=$(cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null || echo "n/a")
  model=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo "n/a")
  bios=$(cat /sys/devices/virtual/dmi/id/bios_version 2>/dev/null || echo "n/a")
  serial_file="/sys/devices/virtual/dmi/id/product_serial"

  print_kv "Vendor" "$vendor"
  print_kv "Model" "$model"
  print_kv "BIOS" "$bios"

  if command_exists dmidecode && [[ $EUID -eq 0 ]]; then
    serial=$(dmidecode -s system-serial-number 2>/dev/null || echo "n/a")
  elif [[ -r $serial_file ]]; then
    serial=$(cat "$serial_file")
  else
    serial="(run with sudo and install dmidecode to fetch serial)"
  fi
  print_kv "Serial" "$serial"
}

cpu_info() {
  print_section "CPU"

  if command_exists lscpu; then
    print_kv "Model" "$(lscpu | awk -F: '/Model name/ {print $2; exit}' | sed 's/^ *//')"
    print_kv "Architecture" "$(lscpu | awk -F: '/Architecture/ {print $2; exit}' | sed 's/^ *//')"
    print_kv "Cores" "$(lscpu | awk -F: '/^CPU\(s\)/ {print $2; exit}' | sed 's/^ *//')"
    print_kv "Threads/Core" "$(lscpu | awk -F: '/Thread\(s\) per core/ {print $2; exit}' | sed 's/^ *//')"
    print_kv "Sockets" "$(lscpu | awk -F: '/Socket\(s\)/ {print $2; exit}' | sed 's/^ *//')"
  else
    print_kv "Model" "$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//' )"
    print_kv "Logical CPUs" "$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "n/a")"
  fi
}

memory_info() {
  print_section "Memory"

  if [[ -r /proc/meminfo ]]; then
    local mem_total mem_available swap_total
    mem_total=$(awk '/MemTotal/ {printf "%.2f GiB", $2/1024/1024}' /proc/meminfo)
    mem_available=$(awk '/MemAvailable/ {printf "%.2f GiB", $2/1024/1024}' /proc/meminfo)
    swap_total=$(awk '/SwapTotal/ {printf "%.2f GiB", $2/1024/1024}' /proc/meminfo)
    print_kv "RAM Total" "$mem_total"
    print_kv "RAM Available" "$mem_available"
    print_kv "Swap Total" "$swap_total"
  else
    print_kv "Status" "Cannot read /proc/meminfo"
  fi
}

storage_info() {
  print_section "Storage"

  if command_exists lsblk; then
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL -e7
  else
    echo "  lsblk missing; install util-linux to display block devices."
  fi
}

gpu_info() {
  print_section "Graphics"
  if command_exists lspci; then
    lspci | grep -iE 'vga|3d|display'
  else
    echo "  lspci missing; install pciutils to detect GPUs."
  fi
}

network_info() {
  print_section "Network Interfaces"

  if command_exists ip; then
    echo "  Links:"
    ip -o link show | awk -F': ' '{printf "    %-12s %s\n", $2, $3}'

    local ipv4_output ipv6_output
    ipv4_output=$(ip -o -4 addr show 2>/dev/null || true)
    if [[ -n ${ipv4_output// /} ]]; then
      echo "  IPv4:"
      awk '{printf "    %-12s %s\n", $2, $4}' <<<"$ipv4_output"
    fi

    ipv6_output=$(ip -o -6 addr show 2>/dev/null || true)
    if [[ -n ${ipv6_output// /} ]]; then
      echo "  IPv6:"
      awk '{printf "    %-12s %s\n", $2, $4}' <<<"$ipv6_output"
    fi
  else
    echo "  ip command missing; install iproute2 to list interfaces."
  fi
}

collect_report() {
  os_info
  hardware_info
  cpu_info
  memory_info
  storage_info
  $INCLUDE_GPU && gpu_info
  $INCLUDE_NETWORK && network_info
}

INCLUDE_NETWORK=true
INCLUDE_GPU=true
ALLOW_INSTALL=true

while [[ $# -gt 0 ]]; do
  case $1 in
    --no-network)
      INCLUDE_NETWORK=false
      ;;
    --no-gpu)
      INCLUDE_GPU=false
      ;;
    --skip-install)
      ALLOW_INSTALL=false
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

PKG_MANAGER=$(detect_pkg_manager)

declare -a ALL_COMMANDS=("${BASE_COMMANDS[@]}")
$INCLUDE_NETWORK && ALL_COMMANDS+=("ip")
$INCLUDE_GPU && ALL_COMMANDS+=("lspci")
ALL_COMMANDS+=("dmidecode")

if [[ $ALLOW_INSTALL == true ]]; then
  for cmd in "${ALL_COMMANDS[@]}"; do
    ensure_command "$cmd" true
  done
else
  for cmd in "${ALL_COMMANDS[@]}"; do
    if ! command_exists "$cmd"; then
      echo "Warning: '$cmd' unavailable; skip-install mode active." >&2
    fi
  done
fi

timestamp=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="${SCRIPT_LABEL}_${timestamp}.txt"

{
  echo "# Inventory Snapshot - $(date -Iseconds)"
  echo "# Script: ${SCRIPT_LABEL}"
  echo
  collect_report
  echo
  echo "# End of report"
} | tee "$OUTPUT_FILE"

echo
echo "Report stored in $OUTPUT_FILE"
