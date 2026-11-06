# ASUS-Battery-Limiter

Battery charge-limit control for ASUS laptops on Linux: set a maximum charge level (e.g. 80%) and keep it applied across boots, suspend and hibernate cycles. No asusctl, no TLP, no background daemon.

It also works around a specific Ubuntu 22.04 / kernel 6.8 (HWE) bug: `amd_pmf` registers the ACPI `platform_profile` first, so the `asus-wmi` probe fails with `-EEXIST`, and `/sys/class/power_supply/BAT0/charge_control_end_threshold` never appears. In that state asusctl, TLP and any udev rule are useless, because they only write to a file that does not exist.

中文说明: [README.md](README.md)

## Verified on

| Item | Value |
|---|---|
| Laptop | ASUS TUF "TX Air" FA401UM (2025, `TX Air FA401UM_FA401UM`) |
| BIOS | `FA401UM.311` (2026-06-03) |
| OS | Ubuntu 22.04.5 LTS |
| Kernel | `6.8.0-138-generic` (jammy HWE) |
| Battery | `GA40347`, 73 Wh design / 70.243 Wh full (96.2% health) |

Confirmed on this machine: limit applied at boot, re-applied after resume, `power_now = 0` when plugged in above the limit.

If your `BAT0` already exposes `charge_control_end_threshold`, skip the diagnosis/fix steps and go straight to `install 80`.

## Quick start

```bash
git clone https://github.com/Peocold/ASUS-Battery-Limiter.git
cd asus-battery-limit

sudo ./asus-battery-limit diagnose
sudo ./asus-battery-limit try-now                 # live test, no reboot
sudo ./asus-battery-limit fix-kernel-conflict     # blacklist amd_pmf
sudo reboot

cd asus-battery-limit
sudo ./asus-battery-limit install 80
sudo ./asus-battery-limit status
```

Rollback: `sudo ./asus-battery-limit uninstall && sudo ./asus-battery-limit revert-kernel-conflict && sudo reboot`.

## Commands

| Command | Description |
|---|---|
| `status` | Show device, current limit, charge level/state, design/full capacity, health |
| `set <40-100>` | Apply a limit immediately (100 disables protection) |
| `install [pct]` | Install + enable the systemd unit (default 80) |
| `uninstall` | Disable and remove the unit |
| `diagnose` | Collect evidence when the sysfs node is missing |
| `try-now` | Unload `amd_pmf`, reload `asus_nb_wmi`, check the node — no reboot |
| `fix-kernel-conflict` | Write `blacklist amd_pmf` and refresh initramfs |
| `revert-kernel-conflict` | Remove that blacklist |

## How it works

The kernel driver creates `charge_control_end_threshold` via `acpi_battery_hook` (only for `BAT0/BAT1/BATC/BATT`). Writing `40..100` calls `asus_wmi_set_devstate(ASUS_WMI_DEVID_RSOC /* 0x00120057 */, value)`; the EC holds the value.

The driver resets RSOC to **100** on every probe, so a boot-time service is required; resume from suspend can also reset it, hence the unit is also wired to `suspend.target`, `hibernate.target` and `hybrid-sleep.target`.

## Behaviour

- Plugged in above the limit: `Not charging`, `power_now = 0`, the machine runs from the adapter. The battery is not charged to 100%.
- Plugged in below the limit: charges up to the limit, then stops.
- ASUS ECs typically use a ~5% hysteresis: charging resumes around 75% and stops again at 80%.
- The limit only stops charging; it never forces discharge down to the limit.

Need a full charge before a trip: `sudo ./asus-battery-limit set 100`, then `set 80` afterwards.

## Trade-off

Blacklisting `amd_pmf` removes AMD's automatic power policy; `platform_profile` choices change from `low-power/balanced/performance` to `quiet/balanced/performance`. On this machine the BIOS does not advertise PMF Smart PC (`PMF Smart PC not advertised in BIOS!:-22` in dmesg), so the practical impact is negligible and `power-profiles-daemon` keeps working.

Alternatives (kernel ≥ 6.12, or a 3-line DKMS backport that keeps `amd_pmf`) are described in [docs/root-cause.md](docs/root-cause.md) and [docs/kernel-backport.md](docs/kernel-backport.md).

## Tests

```bash
./tests/test.sh    # fake sysfs, no root required
```

## License

[MIT](LICENSE)
