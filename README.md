# OpenWrt/ImmortalWrt Stable JioRouter AX6000 JIDU6x01
 
| Config | Devices |
|---|---|
| `jidu6101` | JioRouter AX6000 JIDU6101 |
| `jidu6j01` | JioRouter AX6000 JIDU6201 / 6401 / 6601 / 6701 |
 

> ⚠️ **Try at your own risk.** Incorrect flashing can permanently damage your router.

## Prerequisites

- [ ] 3.3V UART adapter (USB-to-TTL)
- [ ] UART login credentials
- [ ] Firmware images ready:
  - `*-initramfs-kernel.bin`
  - `*-factory.ubi`
  - `*-sysupgrade.bin`

---

## Step 1 — Connect the UART adapter

| UART Adapter | IDU |
|---|---|
| TX | RX |
| RX | TX |
| GND | GND |

> ⚠️ **Do not connect VCC.** This can permanently damage the board.

**Serial settings:** 115200 baud, 8 data bits, no parity, 1 stop bit (115200 8N1)

## Step 2 — Open a serial console (Windows)

Use [PuTTY](https://www.putty.org/):

- Connection type: `Serial`
- Serial line: `COMx` (check Device Manager)
- Speed: `115200`

## Step 3 — Power on and interrupt boot

Power on the IDU and press **Enter** repeatedly as boot messages scroll, to interrupt normal boot.

## Step 4 — Log in via UART

Enter your UART login credentials when prompted.

## Step 5 — Enter U-Boot Failsafe Mode

From the U-Boot menu, select:

```
8. Failsafe Mode
```

## Step 6 — Break into the U-Boot console

When `MTKBOARDBOOT` appears on screen, press **Ctrl+C** to drop into the U-Boot command console.

## Step 7 — Set up a TFTP server

Using [Tftpd64](https://pjo2.github.io/tftpd64/):

1. Run Tftpd64 as Administrator
2. Set the TFTP root directory to the folder containing `openwrt-mediatek-filogic-jrouter-6x01-initramfs-kernel.bin`

## Step 8 — Connect the network

Connect the IDU LAN port directly to your PC via Ethernet, then set a manual IP on the PC:

- IP address: `192.168.1.2`
- Subnet mask: `255.255.255.0`
- Gateway: *(leave empty)*

## Step 9 — Boot the initramfs image (U-Boot)

```
setenv ipaddr 192.168.1.1
setenv serverip 192.168.1.2
saveenv

tftpboot 0x46000000 openwrt-*-kernel.bin
fdt addr $(fdtcontroladdr)
fdt rm /signature
bootm
```

## Step 10 — Transfer the factory image (PC)

```bash
scp -O openwrt-*-factory.ubi root@192.168.1.1:/tmp/
```

## Step 11 — Flash the factory image (router)

```bash
ubidetach -m 6
ubiformat /dev/mtd6 -y -f /tmp/openwrt-*-factory.ubi
reboot
```

## Step 12 — Set the permanent boot command (U-Boot)

```
setenv bootcmd 'ubi read 46000000 kernel; fdt addr $(fdtcontroladdr); fdt rm /signature; bootm'
setenv ipaddr
setenv bootdelay 0
saveenv
reset
```

## Step 13 — Transfer the sysupgrade image (PC)

```bash
scp -O openwrt-*-sysupgrade.bin root@192.168.1.1:/tmp/
```

## Step 14 — Apply the sysupgrade image (router)

```bash
sysupgrade -n /tmp/openwrt-*-sysupgrade.bin
```

---

✅ **Flashing complete.** OpenWrt is now fully installed on the IDU.
