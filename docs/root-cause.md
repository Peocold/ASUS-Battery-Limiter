# 根因分析：为什么 Ubuntu 22.04 上 ASUS 电池充电上限节点不存在

本文记录一次完整的定位过程，结论基于 **Ubuntu 22.04.5 + 内核 6.8.0-138-generic（jammy HWE）** 与 **ASUS 天选 Air FA401UM**。不同机型/内核版本的现象可能不同，请先用 `./asus-battery-limit diagnose` 确认。

## 1. 现象

```console
$ ls /sys/class/power_supply/
ADP0  BAT0  ucsi-source-psy-USBC000:001  ucsi-source-psy-USBC000:002

$ ls /sys/class/power_supply/BAT0/ | grep -i charge
（无输出）
```

asusctl 的 `asusctl battery` 与 TLP 的 `START_CHARGE_THRESH_BAT0/STOP_CHARGE_THRESH_BAT0` 都无效。原因很简单：**它们只是向 `charge_control_end_threshold` 写值**，而这个文件不存在。问题在驱动层，用户态无解。

## 2. 关键证据

### 2.1 驱动探针失败

```console
$ sudo dmesg | grep -iE 'asus|platform_profile|amd.pmf'
asus_wmi: Initialization: 0x1
asus_wmi: SFUN value: 0x21
asus-nb-wmi asus-nb-wmi: Detected ATK, not ASUSWMI, use DSTS
asus-nb-wmi asus-nb-wmi: Detected ATK, enable event queue
asus-nb-wmi asus-nb-wmi: Using throttle_thermal_policy for platform_profile support
asus-nb-wmi: probe of asus-nb-wmi failed with error -17
amd-pmf AMDI0102:00: PMF Smart PC not advertised in BIOS!:-22
amd-pmf AMDI0102:00: registered PMF device successfully
```

`-17` = `-EEXIST`。注意失败点在 “Using throttle_thermal_policy for platform_profile support” **之后**，说明失败发生在 `platform_profile_setup()` 内部。

### 2.2 platform_profile 已被别人占用

```console
$ cat /sys/firmware/acpi/platform_profile
balanced
$ cat /sys/firmware/acpi/platform_profile_choices
low-power balanced performance
```

`low-power/balanced/performance` 是 **amd_pmf** 的档位集合；asus-wmi 自己的是 `quiet/balanced/performance`。`amd_pmf` 绑定在 ACPI 设备 `AMDI0102:00`（驱动别名 `AMDI0100/0102/0103`）。

## 3. 内核源码推导（v6.8）

`drivers/platform/x86/asus-wmi.c`（v6.8）：

```c
/* asus-wmi.c:3582 */
static int platform_profile_setup(struct asus_wmi *asus)
{
	...
	if (!asus->throttle_thermal_policy_available)
		return 0;

	dev_info(dev, "Using throttle_thermal_policy for platform_profile support\n");
	...
	err = platform_profile_register(&asus->platform_profile_handler);  /* :3604 */
	if (err)
		return err;

	asus->platform_profile_support = true;
	return 0;
}
```

而 `platform_profile_register()` 只允许一个注册者（`drivers/acpi/platform_profile.c:145-147`）：

```c
	if (cur_profile) {
		pr_err("platform-profile already in use\n");
		return -EEXIST;
	}
```

于是 `asus_wmi_add()` 在 `:4513` 拿到错误，直接跳走：

```c
	err = platform_profile_setup(asus);
	if (err)
		goto fail_platform_profile_setup;   /* :4515 */

	err = asus_wmi_sysfs_init(asus->platform_device);
	...
	err = asus_wmi_input_init(asus);
	...
	asus_wmi_battery_init(asus);                /* :4587，永远到不了 */
```

`asus_wmi_battery_init()`（`:1311`）负责注册电池钩子：

```c
static void asus_wmi_battery_init(struct asus_wmi *asus)
{
	if (!asus_wmi_dev_is_present(asus, ASUS_WMI_DEVID_RSOC))
		return;
	...
	acpi_battery_hook_register(&battery_hook);
}
```

钩子的 `add_battery` 回调（`:1271`）才是创建属性的地方：

```c
static int asus_wmi_battery_add(struct power_supply *battery, struct acpi_battery_hook *hook)
{
	...
	if (device_create_file(&battery->dev, &dev_attr_charge_control_end_threshold))
	...
	/* 同时把 RSOC 写成 100 */
}
```

写入路径（`:1235`）就是 ASUS WMI：

```c
static ssize_t charge_control_end_threshold_store(...)
{
	...
	ret = asus_wmi_set_devstate(ASUS_WMI_DEVID_RSOC, value, &rv);
	if (ret || rv != 1)
		return -EIO;
	...
}
```

`ASUS_WMI_DEVID_RSOC = 0x00120057`。注意 `_show()` 不读硬件，只返回驱动缓存的 `charge_end_threshold`（DSDT 里没有读方法），因此“显示 80%”不代表 EC 真的一定是 80%——不过 `power_now == 0` 实测能佐证。

## 4. 为什么用户态工具全都失效

| 工具 | 实际行为 | 为什么无效 |
|---|---|---|
| asusctl | 写 `charge_control_end_threshold` | 文件不存在 |
| TLP | 同上（`STOP_CHARGE_THRESH_BAT0`） | 文件不存在 |
| udev 规则 / 手写脚本 | 同上 | 文件不存在 |
| `acpi_call` 直接调 WMI | 需要自己构造 GUID/method | 可行但脆弱，且不同 BIOS 参数不同 |

## 5. 修复方式与验证

### 5.1 在线验证（`try-now`）

```bash
sudo modprobe -r amd_pmf          # 释放 platform_profile
sudo modprobe -r asus_nb_wmi      # 真正触发 probe 的模块
sudo modprobe asus_nb_wmi         # 重新 probe
ls /sys/class/power_supply/BAT0/charge_control_end_threshold
```

**关键细节**：触发 probe 的是 `asus_nb_wmi` 的 `module_init` → `asus_wmi_register_driver()`（`asus-wmi.c:4792`，内部 `platform_create_bundle()`）；`asus_wmi` 自己的 `module_init` 是空的：

```c
static int __init asus_wmi_init(void)
{
	pr_info("ASUS WMI generic driver loaded\n");
	return 0;
}
```

所以**不需要卸载 `asus_wmi`**。实测中 `asus_wmi` 常被 `mfd_aaeon` 引用（`lsmod` 显示 `asus_wmi 1 mfd_aaeon`），卸载会失败，但这无关紧要。

卸载 `amd_pmf` 后重新 probe，`platform_profile_register()` 无人竞争，probe 走完，节点出现，`BAT0/charge_control_end_threshold` 可写。

### 5.2 永久化

`blacklist amd_pmf` 写入 `/etc/modprobe.d/`（并 `update-initramfs`）。因为 `amd_pmf` 是模块（`CONFIG_AMD_PMF=m`），udev 按 ACPI modalias 自动加载时会遵守 blacklist。

代价：失去 AMD PMF 的自动电源策略；本机 BIOS 并未广告 PMF Smart PC（`-22`），实际影响可忽略。

### 5.3 实测结果

```
充电上限 80%，插电时：
ADP0/online = 1
BAT0/status = Not charging
BAT0/power_now = 0          ← 电池完全不进电
BAT0/capacity = 85%         ← 高于上限，停住（EC 不会主动放电）
```

## 6. 内核版本对照（同一文件的不同 tag）

| 版本 | `asus-wmi.c` 大小 | 是否容忍 `-EEXIST` | 说明 |
|---|---|---|---|
| 6.8（Ubuntu HWE） | 127466 | ❌ | 本文环境，probe 失败 |
| 6.9 | 125669 | ❌ | |
| 6.10 | 130551 | ❌ | |
| 6.11 | 132062 | ❌ | |
| 6.12 | 134746 | ✅ | 首次加入 `if (err == -EEXIST) { pr_warn(...); return 0; }` |
| 6.15 | — | ✅ | 重构为 `devm_platform_profile_register(...)` |

Ubuntu 22.04 的 `linux-image-generic-hwe-22.04` 最新只到 `6.8.0-138`，`linux-oem-22.04` 止步于 `22.04d`，因此**等官方内核等不到修复**；本机 `asus-wmi.ko` 的字符串里也没有 “already registered”，确认未回合。

## 7. 方案对比

| 方案 | 保留 amd_pmf | 风险 | 结论 |
|---|---|---|---|
| A. blacklist `amd_pmf`（本项目 `fix-kernel-conflict`） | ❌ | 极低，可回滚 | ✅ 采用 |
| B. 6.8 打 3 行补丁（DKMS） | ✅ | 每次内核升级需重建；见 [kernel-backport.md](kernel-backport.md) | 备选 |
| C. 升级到 6.12+ 主线内核 | ✅ | NVIDIA 是预编译模块（`linux-modules-nvidia-615-open-6.8.0-138-generic`，非 DKMS），换内核直接失配 | ❌ |
| D. `ec_sys`/`acpi_call` 直接写 EC | ✅ | 偏移未文档化，可能破坏充电/风扇配置 | ❌ |

## 8. 复现与排查命令

```bash
# 1) 是否有节点
ls /sys/class/power_supply/BAT0/

# 2) 探针是否 -17
sudo dmesg | grep -E 'asus-nb-wmi|amd-pmf'

# 3) 谁占了 platform_profile
cat /sys/firmware/acpi/platform_profile /sys/firmware/acpi/platform_profile_choices

# 4) 模块归属
lsmod | grep -E 'asus|amd_pmf|platform_profile'
ls /sys/module/asus_wmi/holders/

# 5) 一键诊断
sudo ./asus-battery-limit diagnose
```

## 参考

- `drivers/platform/x86/asus-wmi.c`（v6.8 / v6.12 tag）
- `drivers/acpi/platform_profile.c`（单注册者限制）
- `drivers/platform/x86/amd/pmf/core.c`
- Ubuntu jammy `linux-meta-hwe-6.8` 包列表
- 上游 v6.12 `platform_profile_setup()` 的 `-EEXIST` 容错
