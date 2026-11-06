# 备选方案：给 6.8 内核打补丁，保留 `amd_pmf`

如果你不想屏蔽 `amd_pmf`（例如需要它的自动电源策略），可以让 `asus-wmi` 在 `platform_profile` 注册冲突时**不失败**，而是继续 probe。这正是上游 v6.12 的做法。

代价：这是树外/自编译模块，**每次内核升级都要重新构建**；Secure Boot 必须关闭（本机已关闭），否则模块无法加载。

## 上游 v6.12 的改动

`drivers/platform/x86/asus-wmi.c`，`platform_profile_setup()` 末尾：

```diff
 	err = platform_profile_register(&asus->platform_profile_handler);
-	if (err)
-		return err;
+	if (err == -EEXIST) {
+		pr_warn("%s, a platform_profile handler is already registered\n", __func__);
+		return 0;
+	} else if (err) {
+		return err;
+	}

 	asus->platform_profile_support = true;
 	return 0;
 }
```

对 v6.8（Ubuntu 6.8.0-138 同源）而言，这段在 `asus-wmi.c:3604` 附近：

```c
	err = platform_profile_register(&asus->platform_profile_handler);
	if (err)
		return err;

	asus->platform_profile_support = true;
	return 0;
```

`return 0` 之后，`asus_wmi_add()` 会继续执行 `asus_wmi_sysfs_init()`、`asus_wmi_input_init()` … 直到 `asus_wmi_battery_init()`，节点就出现了。

> 注意：v6.12 的 `platform_profile_setup()` 还包含 `throttle_thermal_policy_set_default()` 等改动，不要整段照抄，只打上面这 4 行语义。

## 构建步骤（概要）

Ubuntu 的 `asus-wmi` 是树内模块，单独编译它需要内核源码树和内部头文件（`include/linux/platform_data/x86/asus-wmi.h` 不在 `linux-headers-*` 里），所以只能走“完整源码树 + 只编译该模块”的路线：

```bash
# 1) 取与运行内核完全一致的源码
sudo apt-get install -y dpkg-dev
sudo apt-get source linux-image-unsigned-$(uname -r)   # 需要 deb-src 源
# 或 apt-get source linux  然后 git 切换到对应版本

# 2) 应用上面的 4 行补丁
cd linux-*/
patch -p1 < ../asus-wmi-eexist.patch

# 3) 准备构建环境（使用已安装的 config）
cp /boot/config-$(uname -r) .config
make olddefconfig
make modules_prepare

# 4) 只编 asus-wmi.ko
make M=drivers/platform/x86 asus-wmi.ko

# 5) 替换并测试（保留原模块以便回滚）
sudo cp drivers/platform/x86/asus-wmi.ko /lib/modules/$(uname -r)/kernel/drivers/platform/x86/
sudo depmod -a
sudo modprobe -r asus_nb_wmi && sudo modprobe asus_nb_wmi
ls /sys/class/power_supply/BAT0/charge_control_end_threshold
```

如果第 4 步报缺少头文件，说明源码版本与运行内核不一致；用 `apt-get source` 拿到的版本必须与 `uname -r` 对应（`6.8.0-138.138`）。

## 升级内核后

模块会被包管理器覆盖，节点重新消失。可以用 `dkms` 包一层，或在内核升级后重跑上面的步骤。

## 与方案 A 的取舍

| | 方案 A：blacklist `amd_pmf` | 方案 B：补丁 |
|---|---|---|
| 保留 AMD PMF | ❌ | ✅ |
| 内核升级后失效 | 不会 | 会 |
| 维护成本 | 零 | 每次升级重建 |
| 风险 | 极低 | 自编译模块，Secure Boot 需关闭 |

多数用户（包括本机）用方案 A 即可：`amd_pmf` 在这台机器上本来就没广告任何 PMF 功能。
