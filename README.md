# ke-net-screen
Raspberry Pi 5 Image Builder for Home DNS

**NOTICE:** These instructions eventually affect your network configuration and connections. You are responsible. You may need to reset or reboot your Internet Service Provider (ISP) modem or contact ISP support to regain proper access if all goes wrong. While fixable, a certain level of patience and required planning are necessary to properly reconfigure your network. This repository was made simple over the course of multiple weekends of network up-and-down exercises.

Success will be determined through validation and testing. Your user experiences may change. You may need to learn new habits of clicking and browsing to mitigate blocked connections. Search results for example may need further scanning to get to a direct link instead of one parlayed through an advertiser!

You must review assigned values in defaults before building or deploying the resulting image. While efforts have been made to provide generic and friendly defaults, these defaults may not work in your network environment.

## Description

AdBlock and Privacy Stripped Recursive DNS Resolver image builder using rpi-image-gen, pi-hole, unbound. Additional configuration of Avahi-daemon for local services discovery such as screen cast, printers, other '.local' services.

**Repository:** devopsbob/ke-net-screen
**Purpose:** Custom Raspberry Pi image builder combining rpi-image-gen with Pi-hole, Unbound, and Avahi-daemon for a local DNS and media server.

## Table of Contents
- [Overview](#overview)
- [Hardware Requirements](#hardware-requirements)
- [Quick Start](#quick-start)
- [Initial Setup](#initial-setup)
- [Build Workflow](#build-workflow)
- [Configuration](#configuration)
- [Verification and Testing](#verification-and-testing)
- [References](#references)

## Overview

### Project Goals
- Create reproducible Raspberry Pi 5 images with Pi-hole and Unbound
- Implement DNS hardening and privacy features
- Configure systemd-resolved networking
- Enable mDNS via Avahi for local service discovery
- Provide comprehensive verification procedures

### Network Configuration
- Primary DNS: 127.0.0.1 (Pi-hole on port 53)
- Upstream DNS: Unbound on port 5335 resolving to public DNS
- Network Management: systemd-resolved
- Service Discovery: Avahi mDNS

### Access Points

- Router: <http://your-router-internal-ip/router.html>
- Development Host: <http://your-on-network-client-machine/>
- Target Server Lookup: <http://your-router-internal-ip/admin/settings/dhcp>
- Target Server: <http://your-router-dhcp-reporting-assigned-ip-of-new-host/admin/>
- SSH: `C:\Windows\System32\OpenSSH\ssh.exe localadmin@your.internal.ip.address`

The access points will be used during the build and deployment. At this point you need to know your current internal router IP and admin login credentials. The development host is likely your desktop computer. The target server lookup is when you find the new IP address for your newly plugged in Raspberry PI. Target server is the Raspberry PI machine where you will host and build this repository. This setup will assign the final Raspberry PI image a static IP address so it can be used as primary DNS server for your router and home network.

## Hardware Requirements

### Required Components
1. Raspberry Pi 5 Starter Kit
2. USB 3.0 64GB USB stick (build host)
3. MicroSD card (target deployment, comes with kit)
4. USB keyboard and mouse
5. Monitor with HDMI cable
6. Ethernet cable (required, not WiFi)

## Quick Start

For experienced users who have the prerequisites:

```bash
cd ke-net-screen
./ke-net-screen.sh
# Insert SD card when prompted
# SD card gets erased!!
# Wait 15-20 minutes for build completion
# Image is copied onto SD card
sudo shutdown now
# Remove USB, reboot, it will run from the SD card
```

## Initial Setup

### 1. Boot Initialization

1. Assemble Raspberry Pi hardware
2. Connect keyboard, mouse, and monitor
3. **Do NOT** insert microSD card
4. **Do** insert USB 3.0 64GB stick
5. Connect Ethernet cable
6. Hold Shift key and power on

This triggers NetBoot to install base OS via internet to USB stick.

We use `localadmin` as the default user with a password of our choosing. The `root` user will also exist and should be given a different password. Be sure to write down the passwords!

### 2. Initial System Upgrade

```bash
sudo apt update && sudo apt upgrade
```

#### Optional RPI-UPDATE

`rpi-update` provides newer kernels than stable APT repository. Mixing kernels during an image build process assumes risk to any incompatibilities between kernels. If this is your first time, you can skip this step.

```bash
sudo rpi-update
sudo reboot
sudo apt update && sudo apt upgrade
```

### 3. Development Environment Setup

Here we describe how the project was built and configured so that you may have greater success to build your own deployed server image.

#### VSCode Remote SSH

This repository is intended to be hosted on the target hardware for the resulting image - a RaspberryPi5 single-board-computer. Experience has shown that running WSL, Windows Subsystem Linux, does not allow running various root file system creation tools. Security measures are likely due to nested-hosting and virtualization risk vectors. You may read and trial these step on any machine but they are only proven to work on a RaspberryPI5 host accessed via SSH thru VSCode.

1. Go to VSCode extensions
2. Install **Remote Development Extension**
   1. ms-vscode-remote.vscode-remote-extensionpack
3. Go to the Raspberry PI machine
   1. Execute `sudo raspi-config`
   2. Select Interface Options > SSH
   3. Enable SSH Server
4. Go to VSCode
   1. CTL-SHIFT-P for Extension action
   2. Remote-SSH: Connect Current Window to Host
   3. Configure new host, use `username@ip.address` (localadmin@192.xx.xx.xx)
   4. Connect and authenticate using username password
5. Clone and manage repository on remote host

Verify connectivity to the remote SSH host. You may also execute these steps directly on the host in the Debian desktop on the RaspberryPI. Be aware that the final RaspberryPi image created by this repository is not GUI or Desktop enabled. It is purely a DNS server.

#### Local Development

On the remote SSH host clone this repository. Update or reconfigure the submodules to align to your repository needs.

```bash
mkdir -p ~/source/github && cd ~/source/github
git clone https://github.com/devopsbob/ke-net-screen.git
cd ke-net-screen
```

The `.gitmodules` file contains reference to the actual builder executables required. This repository provides a layering template example to enable a small lab or home network DNS server. Change the URL to match your fork repository or keep main rpi-image-gen repository.

```bash
# .gitmodules
[submodule "rpi-image-gen"]
	path = rpi-image-gen
	url = https://github.com/raspberrypi/rpi-image-gen
```

Make the submodule code available to the current repository:

```
git submodule init
git submodule update
cd rpi-image-gen
sudo ./install_deps.sh
```

##### Option A: RPI-IMAGE-GEN Submodule

The rpi-image-gen repository is its own source of truth. Any modifications or changes to the repository are bound by the maintainer(s). To respect and honor this to allow variations that can be easily contributed back to the maintainers, a targeted or forked repository configuration can be used private use.

1. Using Github credentials, fork the rpi-image-gen repository
   1. This allows for localized changes with ability to inherit upstream changes; don't forget to update your fork!
2. In your local repository add the forked repository as a submodule
   1. The local repository is created as private.
   2. The forked repository is public.
   3. The submodule treats the rpi-image-gen tool and software as an external dependency.

```bash
# Delete the current submodule setup and configuration
# rm -Rf .gitsubmodules rpi-image-gen

# Add a submodule
# git submodule add <remote_url> <destination_folder>

# Add the "rpi-image-gen" forked repository as a submodule in the project root folder
git submodule add https://github.com/your-github-id/rpi-image-gen.git rpi-image-gen
```

#### Initializing and Updating Submodules

When you clone a repository that contains submodules, the submodule directories will be present but empty. To initialize and update the submodules, run the following commands:

**Initialize the submodule configuration**

git submodule init

**Update the submodules to fetch the data and check out the appropriate commit**

git submodule update

Alternatively, you can use the --recurse-submodules option with the git clone command to automatically initialize and update the submodules during the cloning process:

**Clone the repository and initialize and update submodules**

git clone --recurse-submodules <repository_url>

**Updating Submodules**

To update an existing submodule to the latest commit from the remote repository, use the git submodule update command with the --remote and --merge options:

**Update the submodule to the latest commit and merge changes**
git submodule update --remote --merge

### 4. Configure

Before you build and test you will need to do a bit of detective work to identify your current network configuration.

#### Current Router Network Information

This is your connection to the internet. It is your 'gateway' modem. If you cannot get to or access this information you need to go to your ISP support or stop here. You may continue to review and build the image anyhow but you will not be able to reconfigure DNS for your entire home default DNS network without this access.

Below is simply an example. Your network may be 192.168.1, 10.x, or 172.x. These are all considered "private" networks. If you see other numbers, aka 68.x, 69.x, then you are looking at the WAN configuration and not the LAN configuration.

1. Navigate to Modem/Router Host
   `http://192.168.0.1/admin`

2. Login
   - username: admin
   - password: default is printed on label, otherwise recorded elsewhere

3. Navigate to LAN Setup > LAN Settings
   - DHCP Server Settings
      - Checked on/Enabled
      - Start IP: 192.168.0.2
      - End IP  : 192.168.0.254
      - Domain Name: <blank>
      - This will be turned OFF once the DNS Host is in place
   - DNS Override
      - Enable DNS Override
         - Uncheck/clear. No Custom DNS Configuration
      - Current Assigned examples:
         - DNS: 8.8.8.8 9.9.9.9

You need to know your ISP default DNS. You are free to choose other DNS if your ISP allows it. The intent here is to improve local DNS security and simultaneously take advantage of our ISP's DNS and DNS defenses.

#### Config Layer Update

Now that you have found which public DNS serverd you will use you now update the main configuration file ./config/ke-net-screen.yaml.

```yaml
# ./config/ke-net-screen.yaml excerpt
network:
  interface: eth0
  use_dhcp: n
  ipaddress: 192.168.0.53   # this will be the static IP for your DNS server
  ipnetmask: 24
  netmask: 255.255.255.0
  gateway: 192.168.0.1      # this is router.
  dns0: 127.0.0.1           # this is purposely 127.0.0.1 localhost for first-order.
  dns1: 8.8.8.8             # this is second order lookup.
  dns2: 9.9.9.9             # this is third order lookup.
  domain: lan               # this is your local domain. 
                            # Do not use 'local'!! It is reserved for Avahi-Daemon.
                            # It will be in /etc/networks for kernel lookups.
```

#### Image Size

The default image sizes work for most installations. It will not fill the entire SD disk. If you want to fill the entire SD disk you must also have enough space on the host USB key to create the image (as well as significantly more time). Once you feel comfortable and have tested your configuration you might go back and recreate the final image with larger sizes. See comments for example.

```yaml
# ./config/ke-net-screen.yaml excerpt
image:
  layer: image-rpios
  boot_part_size: 300%
  root_part_size: 200%
  name: deb13-arm64-splash
# compression=zstd
# Partition sizes cause size increase to fill device, only needed on final prod deploy build
# image_boot_part_size=512M
# image_root_part_size=115G
```

### 5. Build

The build uses the submodule rpi-image-gen executable. It utilizes configuration from the ke-net-screen config and layer folders.

The ./config/ke-net-screen.yaml provides the configuration values.

The ./layer folder utilize META dependencies and variable expansion to feed the rpi-image-gen executable.

```bash
./config/ke-net-screen   # Assigned values
./layer/ke-00-layer      # X-Env-Layer-Requires creates ordered dependencies
./layer/ke-03-knlcfg     # Set US locale, assigns kernel, cmdline, config.txt settings
./layer/ke-05-netcfg     # Variable expansion to configure network
./layer/ke-10-unbcfg     # Variable expansion to configure unbound, requires knlcfg settings
./layer/ke-15-piholecfg  # Stages and configures first boot install and configure pi-hole with unbound
./layer/ke-20-avhicfg    # Install and secure hardening of mDNS/AppleTalk/Avahi-daemon
```

**Build With Password**

Now, this is important, to NOT have your history save the password value or the command line, you start with a space in the commandline:

`  PIHOLE_PASSWORD=Chang3M@! ./ke-net-screen.sh`

The .bashrc HISTIGNORE=ignoreboth is typically a default. It includes a rule that does not record to history any command line executed that starts with a space. You generally do not want the password available in history.

The PIHOLE_PASSWORD value must meet password complexity rules: lower, upper, number, special, min 8 chars. If it does not meet these minimums you get an error. This is built into the rpi-image-gen layers. `Chang3M@!` is an example only!

This will be the host login password.

**Build Success**

Once completed you will see:

```bash
Write successful.                         ..
SD card setup complete.
```

### 6. Test

Now, shutdown the RaspberryPi host, remove the USB, and press the button to boot it again.

The SD card takes first priority. If you forget to take out the USB it will start from the SD anyway!

The first-boot will take 2-5 minutes to actually complete. You will be able to log into it almost immediately. The DNS services will not be fully available until the Pi-Hole installation completes.

You can have more than one DNS server on your network. It typically will not break your environment.

- cat /etc/os-release
- sudo pihole -up
- sudo pihole -g

#### System Checks

- journalctl -b | more
- systemctl status
- resolvectl status

#### Network Checks

- sudo ip addr show eth0
- ifconfig
- ls /etc/network/interfaces && cat /etc/network/interfaces
   - not present for pure systemd-resolved or netplan setup
- ss -tunlp
- cat /etc/nsswitch.conf
- cat /etc/mdns.allow
   - not present for pure systemd-resolved
- cat /etc/resolv.conf
   - is a link to /run/systemd/resolve/stub-resolv.conf in systemd-resolved setup

- vi /etc/dhcp/dhclient.conf
   - Not present for pure systemd-resolved setup
   - /etc/dhcp/dhclient-exit-hooks.d/timesyncd file present

#### Network Lookup Checks

- dig example.com
- dig example.com @192.168.0.124
- dig example.com @192.168.0.124#5335
- or dig example.com @192.168.0.124 -p 5335
- dig -4 example.com
- dig -6 example.com

### Workflow Steps and Description

Follow these steps to build the image on the USB host, write it to the SD card, and verify the target Raspberry Pi boots with your configured services:

1. Prepare the host and source:
   - Boot the Raspberry Pi from the USB3 stick and open a terminal.
   - Change into the `ke-net-screen` directory: `cd ke-net-screen`.

2. Run the build script:
   - Execute `./ke-net-screen.sh`.
   - The full run takes about 15–20 minutes depending on network and device speed.

3. Insert the SD card when prompted:
   - At the first prompt during the build, insert the target SD card into the Pi.

4. Build and write the image:
   - The script downloads and builds the image, wipes the SD card partitions, and writes the new image to the SD card.

5. Power down and swap media:
   - When writing completes, run `sudo shutdown now` on the USB-hosted system.
   - Remove the USB stick, connect the Ethernet (`eth0`) cable to the Pi, and insert the SD card.

6. Boot the Pi from the SD card:
   - Power the Pi on and allow it to boot from the SD card.

7. Verify services and logs:
   - Check service status: `systemctl status` (or `systemctl status <service>` for specific services).
   - Inspect boot logs: `journalctl -b | more` to confirm configuration and setup messages.

Notes:
   - You could use Docker/Podman to build images, but you would still need to convert or export the image and burn it to an SD card for the Pi. This guide uses direct image creation and SD write for simplicity and reproducibility.

- grep -v '#' /run/systemd/resolve/stub-resolv.conf
- grep -v '#' /run/systemd/resolve/resolv.conf
- grep -v '#' /lib/systemd/resolv.conf 


### V2 RPI-IMAGE-GEN CLI

```text
Usage
  rpi-image-gen build [options] [-- IGconf_key=value ...]

Options:
  [-c <config>]    Path to config file.
  [-S <src dir>]   Directory holding custom sources of config, profile, image
                   layout and layers.
  [-B <build dir>] Use this as the root directory for generation and build.
                   Sets IGconf_sys_workroot.
  [-I]             Interactive. Prompt at different stages.

  Developer Options
  [-f]             setup, build filesystem, skip image generation.
  [-i]             setup, skip building filesystem, generate image(s).

  IGconf Variable Overrides:
    Use -- to separate options from overrides.
    Any number of key=value pairs can be provided.
    Use single quotes to enable variable expansion.
```
