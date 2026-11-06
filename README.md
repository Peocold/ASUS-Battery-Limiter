# ASUS-Battery-Limiter

[![CI](https://github.com/Peocold/ASUS-Battery-Limiter/actions/workflows/ci.yml/badge.svg)](https://github.com/Peocold/ASUS-Battery-Limiter/actions/workflows/ci.yml)

在 Linux 下为 ASUS 笔记本启用**电池充电上限**（如 80%），并在开机、睡眠唤醒后自动维持。无需 asusctl / TLP，也不依赖任何第三方守护进程。

同时修复一个 Ubuntu 22.04（内核 6.8 HWE）上的具体 bug：`amd_pmf` 抢先注册 ACPI `platform_profile`，导致 `asus-wmi` 探针以 `-EEXIST` 失败，`/sys/class/power_supply/BAT0/charge_control_end_threshold` 根本不出现——这时 asusctl、TLP、手写 udev 规则全都无效，因为它们只是往一个不存在的文件写值。

> English README: [README.en.md](README.en.md)

## 验证环境

| 项 | 值 |
|---|---|
| 机型 | ASUS 天选 Air FA401UM（2025，`TX Air FA401UM_FA401UM`） |
| BIOS | `FA401UM.311`（2026-06-03） |
| 系统 | Ubuntu 22.04.5 LTS |
| 内核 | `6.8.0-138-generic`（jammy HWE） |
| 电池 | `GA40347`，设计 73 Wh / 满充 70.243 Wh（健康度 96.2%） |

已在上述机器上完整验证：开机自动设 80%、睡眠唤醒后重设 80%、电量高于 80% 时插电 `power_now = 0`（完全不充电）。

**其他机器**：如果你的 `BAT0` 已经有 `charge_control_end_threshold`，那不需要诊断和修复，直接 `install 80` 即可（本文档的“工作原理/命令”部分仍然适用）。如果节点不存在但 `dmesg` 里没有本文所述的 `-17`，请先跑 `diagnose` 再判断。

## 症状

```console
$ ls /sys/class/power_supply/BAT0/
capacity  charge_control_end_threshold  ← 没有这个文件
```

```console
$ sudo dmesg | grep -i asus
asus_wmi: Initialization: 0x1
asus_wmi: SFUN value: 0x21
asus-nb-wmi asus-nb-wmi: Detected ATK, not ASUSWMI, use DSTS
asus-nb-wmi asus-nb-wmi: Using throttle_thermal_policy for platform_profile support
asus-nb-wmi: probe of asus-nb-wmi failed with error -17
```

`-17` 就是 `-EEXIST`。`asus_wmi_add()` 在 `platform_profile_setup()` 失败后直接 `goto fail_platform_profile_setup`，排在后面的 `asus_wmi_battery_init()` 没有执行，而这个函数才负责通过 `acpi_battery_hook` 创建充电阈值节点。

完整推导（含内核源码行号、6.8→6.12 的版本对照）见 [docs/root-cause.md](docs/root-cause.md)。

## 快速开始

```bash
git clone https://github.com/Peocold/ASUS-Battery-Limiter.git
cd asus-battery-limit

sudo ./asus-battery-limit diagnose          # 确认是同一个问题
sudo ./asus-battery-limit try-now           # 临时验证：卸载 amd_pmf 并重载 asus 驱动，不必重启
sudo ./asus-battery-limit fix-kernel-conflict   # 永久屏蔽 amd_pmf（写 modprobe.d）
sudo reboot

cd asus-battery-limit
sudo ./asus-battery-limit install 80        # 安装开机/唤醒自动应用的服务
sudo ./asus-battery-limit status            # 应显示“充电上限: 80%”
```

如果 `try-now` 直接成功，说明硬件支持（RSOC `0x00120057`）没问题，剩下的只是让它每次开机都成立。

> `fix-kernel-conflict` 会写入 `/etc/modprobe.d/zz-asus-battery-limit.conf`（只有一行 `blacklist amd_pmf`）。
> 回滚：`sudo ./asus-battery-limit revert-kernel-conflict && sudo reboot`。

## 命令

| 命令 | 作用 |
|---|---|
| `status` | 显示电池设备、当前上限、电量/状态、设计/满充容量与健康度 |
| `set <40-100>` | 立即设置上限（100 = 关闭保护） |
| `install [pct]` | 安装并启用 systemd 服务（默认 80），当前立即生效 |
| `uninstall` | 停用并删除服务 |
| `diagnose` | 节点不存在时取证：模块加载、dmesg、platform_profile 占用者 |
| `try-now` | 运行时验证：卸载 `amd_pmf` → 重载 `asus_nb_wmi` → 检查节点 |
| `fix-kernel-conflict` | 写入 `blacklist amd_pmf` 并更新 initramfs |
| `revert-kernel-conflict` | 删除上述 blacklist |

## 工作原理

1. 内核 `asus-wmi` 在电池注册时创建一个 `charge_control_end_threshold` 属性（`dev_attr`），只对 `BAT0/BAT1/BATC/BATT` 生效。
2. 向该文件写入 `40..100` 会调用 `asus_wmi_set_devstate(ASUS_WMI_DEVID_RSOC /* 0x00120057 */, value)`，`rv == 1` 才算成功，由 EC 保持该值。
3. 驱动在每次 probe（开机）时会把 RSOC 重置为 **100**，所以必须有一个开机服务把它改回来；睡眠/休眠后 EC 也可能复位，因此服务同时挂到 `suspend.target` / `hibernate.target` / `hybrid-sleep.target`。

安装出来的 unit：

```ini
[Unit]
Description=ASUS battery charge limit (80%)
After=suspend.target hibernate.target hybrid-sleep.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/asus-battery-limit set 80

[Install]
WantedBy=multi-user.target suspend.target hibernate.target hybrid-sleep.target
```

`multi-user.target` 负责开机；`WantedBy=suspend.target` + `After=suspend.target` 利用 systemd 的语义——`systemd-suspend.service` 是 oneshot，唤醒后才返回，因此挂在 `suspend.target` 上的 unit 会在恢复之后执行。

## 行为说明（实测）

- **电量高于上限时插电**：`status` 变为 `Not charging`，`power_now = 0`，电脑由适配器供电，电池不充电（不会“补到 100”）。
- **电量低于上限时插电**：充到 80% 后转为 `Not charging`。
- 华硕 EC 通常有约 5% 回差：掉到 ~75% 才会再补到 80%，所以 78~80% 的小幅波动是正常的。
- 阈值只管“充”不管“放”，不会为了让电量降到 80% 而主动放电。

需要满电出门时：

```bash
sudo ./asus-battery-limit set 100     # 临时关闭保护
# 回来后再恢复
sudo ./asus-battery-limit set 80
```

## 风险与回滚

- 脚本需要 root：修改 `/etc/modprobe.d/`、`/etc/systemd/system/`、`/usr/local/sbin/`，并调用 `update-initramfs`。
- 屏蔽 `amd_pmf` 的代价：失去 AMD PMF 的自动电源策略，`platform_profile` 档位从 `low-power/balanced/performance` 变为 `quiet/balanced/performance`。本机 BIOS 本来就没广告 PMF Smart PC（`dmesg` 有 `PMF Smart PC not advertised in BIOS!:-22`），实际几乎无感；`power-profiles-daemon` 仍正常工作。
- 完全回滚：

```bash
sudo ./asus-battery-limit uninstall
sudo ./asus-battery-limit revert-kernel-conflict
sudo reboot
```

## 其他选择（不屏蔽 amd_pmf）

- **内核 ≥ 6.12**：上游 `asus-wmi` 已改为容忍 `-EEXIST`（`platform_profile_setup()` 里 `if (err == -EEXIST) ... return 0;`）。但 6.12 起 jammy 没有官方 HWE；自编主线内核会让 NVIDIA 预编译模块（`linux-modules-nvidia-*-6.8.0-*`）失配。
- **给 6.8 打 3 行补丁（DKMS）**：保留 `amd_pmf`，但每次内核升级都要重建。步骤与 diff 见 [docs/kernel-backport.md](docs/kernel-backport.md)。
- **直接操作 EC**（`ec_sys` / `acpi_call`）：偏移量未文档化，写错可能影响充电/风扇配置，不建议。

## 测试

无需 root、无需真机：

```bash
./tests/test.sh
```

用假 sysfs 覆盖 `status` / `set` 的参数校验与写入逻辑；GitHub Actions 会在每次 push 时跑 `shellcheck` + 该测试。

## License

[MIT](LICENSE)
