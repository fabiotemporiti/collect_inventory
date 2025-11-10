# collect_inventory

Utility script to snapshot OS and hardware details on any Linux host (laptop, desktop, server), save them in a time-stamped TXT, and share results (e.g., with ChatGPT) without exposing the machine live.

## Quick Start (local file)

```bash
cd collect_inventory
chmod +x collect_inventory.sh
./collect_inventory.sh
```

The script writes a report such as `collect_inventory_20250218_143015.txt` in the same directory and echoes the path at the end.

## Curl + Pipe Execution

Fetch the latest version directly from GitHub (`https://github.com/fabiotemporiti/collect_inventory`) and run:

```bash
curl -fsSL https://raw.githubusercontent.com/fabiotemporiti/collect_inventory/main/collect_inventory.sh | bash
```

Add `--no-network`, `--no-gpu`, or `--skip-install` flags after `bash` to skip sections or dependency prompts:

```bash
curl -fsSL https://raw.githubusercontent.com/fabiotemporiti/collect_inventory/main/collect_inventory.sh | bash -s -- --skip-install --no-gpu
```

## Dependency Prompts

Missing helpers (`ip`, `lspci`, `dmidecode`, etc.) trigger an interactive prompt that detects your package manager (apt, pacman, dnf, yum, zypper) and asks whether to install the required package. Respond `y` to run the suggested command; press Enter to skip and proceed with reduced output.

## Sharing Results

Each TXT report begins with the timestamp and script name, followed by OS, hardware, CPU, memory, storage, GPU, and network sections. To share with ChatGPT, open the newest TXT, copy the contents, and paste them into the conversation. No automatic upload occurs; you control what is sent.
