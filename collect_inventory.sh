#!/usr/bin/env bash
#
# Collects OS and hardware information and stores it in a timestamped report.
# Can be fetched remotely, e.g.:
#   curl -fsSL https://raw.githubusercontent.com/fabiotemporiti/collect_inventory/main/collect_inventory.sh | bash
#   fetch -o - https://raw.githubusercontent.com/fabiotemporiti/collect_inventory/main/collect_inventory.sh | bash

set -u
IFS=$'\n\t'

SCRIPT_LABEL="collect_inventory"
UNAME_S=$(uname -s 2>/dev/null || echo "Unknown")

case "$UNAME_S" in
  Linux)
    PLATFORM="linux"
    BASE_COMMANDS=(hostname uname uptime lsblk lscpu awk sed grep cat date)
    ;;
  FreeBSD)
    PLATFORM="freebsd"
    BASE_COMMANDS=(hostname uname uptime sysctl awk sed grep cat date ifconfig pciconf geom kenv swapinfo)
    ;;
  *)
    PLATFORM="unknown"
    BASE_COMMANDS=(hostname uname uptime awk sed grep cat date)
    ;;
esac

detect_raspberry_model() {
  local model=""
  if [[ $PLATFORM == "linux" ]]; then
    for f in /sys/firmware/devicetree/base/model /proc/device-tree/model; do
      if [[ -r $f ]]; then
        model=$(tr -d '\0' < "$f")
        break
      fi
    done
    if [[ -z $model && -r /proc/cpuinfo ]]; then
      model=$(grep -i 'model' /proc/cpuinfo | awk -F: '{print $2}' | head -n1 | sed 's/^ *//')
    fi
  elif [[ $PLATFORM == "freebsd" ]]; then
    model=$(sysctl -n hw.model 2>/dev/null || true)
  fi
  if [[ -n $model && "$model" =~ [Rr]aspberry ]]; then
    echo "$model"
  fi
}

RASPBERRY_MODEL=$(detect_raspberry_model 2>/dev/null || echo "")

declare -A CMD_PACKAGE_MAP=(
  [lsblk]="util-linux"
  [lscpu]="util-linux"
  [lspci]="pciutils"
  [ip]="iproute2"
  [dmidecode]="dmidecode"
  [pciconf]="pciconf"
  [ifconfig]="net-tools"
  [geom]="geom"
  [kenv]="kenv"
  [sysctl]="procps"
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
  elif command_exists pkg; then
    echo "pkg"
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
      local runner="sudo"
      if [[ $PLATFORM == "freebsd" && -x /usr/local/bin/doas ]]; then
        runner="doas"
      fi
      case $pm in
        apt|apt-get)
          if [[ $APT_UPDATED == false ]]; then
            "$runner" "$pm" update
            APT_UPDATED=true
          fi
          "$runner" "$pm" install -y "$pkg"
          ;;
        dnf|yum|zypper)
          "$runner" "$pm" install -y "$pkg"
          ;;
        pacman)
          "$runner" pacman -Sy --noconfirm "$pkg"
          ;;
        pkg)
          "$runner" pkg install -y "$pkg"
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
  if [[ $PLATFORM == "linux" ]]; then
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
  elif [[ $PLATFORM == "freebsd" ]]; then
    local fb_version
    fb_version=$(freebsd-version 2>/dev/null || echo "")
    print_kv "OS Version" "${fb_version:-$kernel}"
    print_kv "Kernel" "$kernel ${arch}"
    print_kv "Uptime" "$(uptime 2>/dev/null || echo "n/a")"
    print_kv "Timezone" "$(date +%Z 2>/dev/null || echo "n/a")"
  else
    print_kv "Kernel" "$kernel ${arch}"
    print_kv "Uptime" "$(uptime 2>/dev/null || echo "n/a")"
  fi
}

hardware_info() {
  print_section "Hardware"

  if [[ $PLATFORM == "linux" ]]; then
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
    if [[ -n $RASPBERRY_MODEL ]]; then
      print_kv "Raspberry Pi" "$RASPBERRY_MODEL"
    fi
  elif [[ $PLATFORM == "freebsd" ]]; then
    local vendor model serial bios
    vendor=$(kenv -q smbios.system.maker 2>/dev/null || sysctl -n hw.vendor 2>/dev/null || echo "n/a")
    model=$(kenv -q smbios.system.product 2>/dev/null || sysctl -n hw.product 2>/dev/null || echo "n/a")
    serial=$(kenv -q smbios.system.serial 2>/dev/null || echo "(run as root with dmidecode for serial)")
    bios=$(kenv -q smbios.bios.version 2>/dev/null || echo "n/a")
    print_kv "Vendor" "$vendor"
    print_kv "Model" "$model"
    print_kv "BIOS" "$bios"
    print_kv "Serial" "$serial"
    if [[ -n $RASPBERRY_MODEL ]]; then
      print_kv "Raspberry Pi" "$RASPBERRY_MODEL"
    fi
  else
    print_kv "Info" "Unsupported platform for hardware details."
  fi
}

cpu_info() {
  print_section "CPU"

  if [[ $PLATFORM == "linux" ]]; then
    if command_exists lscpu; then
      print_kv "Model" "$(lscpu | awk -F: '/Model name/ {print $2; exit}' | sed 's/^ *//')"
      print_kv "Architecture" "$(lscpu | awk -F: '/Architecture/ {print $2; exit}' | sed 's/^ *//')"
      print_kv "Cores" "$(lscpu | awk -F: '/^CPU\(s\)/ {print $2; exit}' | sed 's/^ *//')"
      print_kv "Threads/Core" "$(lscpu | awk -F: '/Thread\(s\) per core/ {print $2; exit}' | sed 's/^ *//')"
      print_kv "Sockets" "$(lscpu | awk -F: '/Socket\(s\)/ {print $2; exit}' | sed 's/^ *//')"
    else
      print_kv "Model" "$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//')"
      print_kv "Logical CPUs" "$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "n/a")"
    fi
  elif [[ $PLATFORM == "freebsd" ]]; then
    print_kv "Model" "$(sysctl -n hw.model 2>/dev/null || echo "n/a")"
    print_kv "Architecture" "$(uname -m 2>/dev/null || echo "n/a")"
    print_kv "Logical CPUs" "$(sysctl -n hw.ncpu 2>/dev/null || echo "n/a")"
    local cores threads
    cores=$(sysctl -n kern.smp.cores 2>/dev/null || echo "")
    threads=$(sysctl -n kern.smp.threads_per_core 2>/dev/null || echo "")
    [[ -n $cores ]] && print_kv "Cores/Socket" "$cores"
    [[ -n $threads ]] && print_kv "Threads/Core" "$threads"
  else
    print_kv "Model" "$(uname -p 2>/dev/null || echo "n/a")"
  fi
}

memory_info() {
  print_section "Memory"

  if [[ $PLATFORM == "linux" ]]; then
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
  elif [[ $PLATFORM == "freebsd" ]]; then
    local physmem usermem swap_total page_size free_pages
    physmem=$(sysctl -n hw.physmem 2>/dev/null || echo 0)
    usermem=$(sysctl -n hw.usermem 2>/dev/null || echo 0)
    page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
    free_pages=$(sysctl -n vm.stats.vm.v_free_count 2>/dev/null || echo 0)
    swap_total=$(sysctl -n vm.swap_total 2>/dev/null || swapinfo -k 2>/dev/null | awk 'NR==2 {print $2*1024}')
    local free_mem=$((free_pages * page_size))
    print_kv "RAM Total" "$(bytes_to_gib "$physmem")"
    print_kv "RAM User" "$(bytes_to_gib "$usermem")"
    print_kv "RAM Free" "$(bytes_to_gib "$free_mem")"
    print_kv "Swap Total" "$(bytes_to_gib "${swap_total:-0}")"
  else
    print_kv "Status" "Memory metrics not implemented for this OS."
  fi
}

storage_info() {
  print_section "Storage"

  if [[ $PLATFORM == "linux" ]]; then
    if command_exists lsblk; then
      lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL -e7
    else
      echo "  lsblk missing; install util-linux to display block devices."
    fi
  elif [[ $PLATFORM == "freebsd" ]]; then
    if command_exists geom; then
      geom disk list
    elif command_exists gpart; then
      gpart show
    else
      echo "  geom/gpart missing; install base utilities to display disks."
    fi
  else
    echo "  Storage inspection not implemented for this OS."
  fi
}

gpu_info() {
  print_section "Graphics"

  if [[ $PLATFORM == "linux" ]]; then
    if command_exists lspci; then
      lspci | grep -iE 'vga|3d|display'
    else
      echo "  lspci missing; install pciutils to detect GPUs."
    fi
  elif [[ $PLATFORM == "freebsd" ]]; then
    if command_exists pciconf; then
      pciconf -lv | awk 'BEGIN { RS=""; FS="\n" } /class=0x03/ { print; print "" }'
    else
      echo "  pciconf missing; install pciutils to detect GPUs."
    fi
  else
    echo "  GPU inspection not implemented for this OS."
  fi
}

network_info() {
  print_section "Network Interfaces"

  if [[ $PLATFORM == "linux" ]]; then
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
  elif [[ $PLATFORM == "freebsd" ]]; then
    local ifconfig_bin route_bin
    ifconfig_bin=$(command -v ifconfig 2>/dev/null || command -v /sbin/ifconfig 2>/dev/null || echo "")
    route_bin=$(command -v route 2>/dev/null || command -v /sbin/route 2>/dev/null || echo "")

    if [[ -n $ifconfig_bin ]]; then
      local default_if tailscale_if
      [[ -n $route_bin ]] && default_if=$("$route_bin" -n get default 2>/dev/null | awk '/interface:/{print $2}' | head -n1)
      tailscale_if=$("$ifconfig_bin" -a | awk -F: '/^tailscale[0-9]+:/ {print $1}' | head -n1)

      "$ifconfig_bin" -a | awk -v def="$default_if" -v tail="$tailscale_if" '
        /^[a-zA-Z0-9_.-]+:/ {
          iface=$1
          sub(/:$/,"",iface)
          if (iface ~ /^lo/ && status != "active") next
          if (have_iface) print ""
          have_iface=1
          role=""
          if (iface==def) role="LAN/Default"
          else if (iface==tail) role="Tailscale"
          else if (iface ~ /^(tail|ts|wg|tun)/) role="Tunnel"
          printf("  Interface: %s", iface)
          if (role!="") printf(" (%s)", role)
          printf("\n")
          next
        }
        /ether[ \t]+([0-9a-f:]+)/ {
          printf "    MAC: %s\n", $2
        }
        /inet[ \t]+([0-9.]+)/ {
          printf "    IPv4: %s\n", $2
        }
        /inet6[ \t]+([0-9a-f:]+)/ {
          printf "    IPv6: %s\n", $2
        }
        /status:[ \t]+/ {
          printf "    status %s\n", $2
        }
      '
    else
      echo "  ifconfig missing; install net-tools to list interfaces."
    fi
  else
    echo "  Network inspection not implemented for this OS."
  fi
}

bytes_to_gib() {
  local bytes=${1:-0}
  if [[ -z $bytes || $bytes -eq 0 ]]; then
    echo "0 GiB"
    return
  fi
  awk -v b="$bytes" 'BEGIN { printf "%.2f GiB", b/1024/1024/1024 }'
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
if [[ $PLATFORM == "linux" ]]; then
  $INCLUDE_NETWORK && ALL_COMMANDS+=("ip")
  $INCLUDE_GPU && ALL_COMMANDS+=("lspci")
elif [[ $PLATFORM == "freebsd" ]]; then
  $INCLUDE_GPU && ALL_COMMANDS+=("pciconf")
fi
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
