# Linux 实测记录：从「能加载程序集」到「真的能跑」

这次在 **Ubuntu 24.04 真机环境**里从零走完整流程，
把上一轮**没走到的坑**挖出来了，并修好。

---

## 一、结论

**能跑。** 一条命令：

```bash
./play-pvz.sh              # 自动找 .pck → 校验 → 装 Godot/.NET → 解包 → 补依赖 → 启动
```

---

## 二、这次新发现的坑（上一轮未覆盖）

### 坑 4：发布包根本没带游戏的第三方依赖库 🔴 关键

`data_PlantsVsZombies_windows_x86_64/` 里**只有** `PlantsVsZombies.dll`。
但它的 `deps.json` 声明了 8 个第三方库，发布包里一个都没带：

| 需要的库 | 版本 | 被谁用 |
|---|---|---|
| Microsoft.Extensions.Logging.Abstractions | 8.0.0 | Global、GameSaveManager、ObjectManager… |
| Microsoft.Extensions.Logging | 8.0.0 | 日志 |
| Microsoft.Extensions.DependencyInjection(+.Abstractions) | 8.0.0 | DI 容器 |
| Microsoft.Extensions.Options / Primitives | 8.0.0 | 配置 |
| ZLogger | 2.0.0 | 游戏日志（`VersionHTTPRequestCompleted` 用到） |
| ZString / Utf8StringInterpolation | 1.0.0 / 1.3.0 | ZLogger 依赖 |
| CommunityToolkit.HighPerformance | 8.4.2 | 高性能集合 |
| System.IO.Hashing | 8.0.0 | 哈希 |

**症状**（实测日志）：

```
ERROR: System.IO.FileNotFoundException: Could not load file or assembly
       'Microsoft.Extensions.Logging.Abstractions, Version=8.0.0.0, ...'
   at Global..cctor()
   at GameSaveManager..cctor()
   at ObjectManager..cctor()
ERROR: GlobalFeatureManager requires GameSaveManager to be loaded first.
```

即：程序集加载**成功**了（`.NET: Failed to load project assembly` = 0），
但游戏的核心单例一初始化就因为缺依赖而 `..cctor()` 抛异常 →
`GlobalFeatureManager` 连锁失败 → 游戏起不来。

**Windows 上为什么没事**：自包含发布（self-contained）由
`runtimepack.Microsoft.NETCore.App.Runtime.win-x64` 提供这些库；
Linux + Godot 编辑器环境下没有这层，必须自己补。

**解法**：`fetch_deps.py` 解析 `deps.json`，从 NuGet 拉 `.nupkg` 并解出运行时 dll。

### 坑 5：补依赖时不能无脑补，会撞 .NET 框架自带的同名程序集 🔴

第一轮补完依赖后出现新错误：

```
ERROR: System.MissingMethodException: Method not found:
  '!!0 ByRef System.Runtime.InteropServices.MemoryMarshal.GetReference(System.ReadOnlySpan`1<!!0>)'
   at ZLogger.MessageSequence.LiteralList.AsBytes(ReadOnlySpan`1 literals)
```

原因：`System.Memory` 4.5.3 是给 .NET Framework / netstandard 的**垫片包**，
它里面的 `MemoryMarshal` 与 .NET 9 运行时的**签名不同**。
把它放在程序集旁边，等于把框架里的 `System.Memory` **降级**了，
于是 ZLogger 编译时看到的签名在运行时找不到。

**必须删掉的 4 个同名冲突包**（.NET 9 框架已自带，实测）：

- `System.Memory` 4.5.3
- `System.Collections.Immutable` 9.0.0
- `System.Reflection.Metadata` 9.0.0
- `System.Threading.Channels` 8.0.0

判断方法：`ls $DOTNET_ROOT/shared/Microsoft.NETCore.App/9.0.*/ | grep <名字>`
——框架里有，就删掉 NuGet 副本。

另外 `Microsoft.CodeAnalysis.*`（Roslyn 编译器）**必须保留**，我一开始误判成
「运行时不需要」删掉了，结果游戏在**创建存档之后、切场景时**崩：

```
ERROR: System.TypeInitializationException: The type initializer for
       'TransientStaticTextureRelease' threw an exception.
 ---> System.IO.FileNotFoundException: Could not load file or assembly
      'Microsoft.CodeAnalysis, Version=4.14.0.0, ...'
   at TransientStaticTextureRelease.DiscoverTextureFields()
   at ResourceManager.ReleaseTransientResources(...)
   at SceneManager.ClearObjectsForSceneChange()
```

`DiscoverTextureFields()` 会**反射遍历字段类型**，这需要 Roslyn 的元数据程序集。

另外两个坑：

- **包名 ≠ 程序集名**：包 `Microsoft.CodeAnalysis.Common` 里的 dll 叫
  `Microsoft.CodeAnalysis.dll`。按包名去包内找 dll 永远找不到，必须用
  `deps.json` 里 `runtime` 节点声明的**真实路径**。
- **多语言资源程序集**：`Microsoft.CodeAnalysis.Common` 包里有
  `lib/net9.0/cs/Microsoft.CodeAnalysis.resources.dll` 之类，会被误当成主程序集；
  必须排除 `*.resources.dll`。

**最终依赖清单（17 个 dll = 16 个依赖 + 主程序集，实测刚好够）：**

```
CommunityToolkit.HighPerformance.dll
Microsoft.CodeAnalysis.CSharp.dll
Microsoft.CodeAnalysis.dll                    ← Roslyn 元数据，反射要用
Microsoft.Extensions.DependencyInjection.Abstractions.dll
Microsoft.Extensions.DependencyInjection.dll
Microsoft.Extensions.Logging.Abstractions.dll
Microsoft.Extensions.Logging.dll
Microsoft.Extensions.Options.dll
Microsoft.Extensions.Primitives.dll
System.Collections.Immutable.dll              ← Roslyn 依赖，保留 9.0.0
System.IO.Hashing.dll
System.Reflection.Metadata.dll                ← Roslyn 依赖，保留 9.0.0
System.Threading.Channels.dll
Utf8StringInterpolation.dll
ZLogger.dll
ZString.dll
PlantsVsZombies.dll
```

> **只排除 `System.Memory` 4.5.3**：它的包版本是 4.5.3，而 .NET 9 框架自带的是
> 9.0.0，落差最大，是唯一真正把框架 API 顶掉的垫片包。
> 其余同名程序集（Immutable / Metadata / Channels）与框架版本差异很小，
> 保留它们才能满足 Roslyn 的显式依赖。

### 坑 6：清理 `bin/` 后主程序集不会自动回来 🔴

`PlantsVsZombies.dll` 只在**解包**那一步由 `setup_project.py` 放进
`.godot/mono/temp/bin/Debug/`。而解包在「工程目录已存在」时会被跳过——
所以一旦 `bin/` 被删过，主程序集就永久缺失，症状又变回
`.NET: Failed to load project assembly` + 136 条 `Cannot instantiate C# script`。

`play-pvz.sh` 现在**每次**都无条件重放主程序集，并在缺失时直接报错退出，
不再让这个问题静默发生。实测：删掉整个 `bin/` 后重跑脚本，一次通过。

---

## 三、实测证据（本机 Ubuntu 24.04）

| 检查项 | 只补部分依赖 | 最终修复后 |
|---|---|---|
| `Failed to load project assembly` | 0 / 1（bin 被清时） | **0** |
| `Cannot instantiate C# script` | 0 / **136** | **0** |
| `FileNotFoundException`（缺库） | 7 | **0** |
| `MissingMethodException`（垫片冲突） | 1 | **0** |
| `TypeInitializationException`（Roslyn 缺失） | 1 | **0** |
| 游戏自身日志 `newVersion: 0.29.0.0` | 有 | **有** |
| `checkString: 0.29.0.0https://...` | 有 | **有** |

**最终验收是在最严苛场景下做的**：删掉整个
`.godot/mono/temp/bin/` 与 `.deps-fixed` 后重跑 `play-pvz.sh --headless`，
一次通过，全部严重错误为 0，`newVersion` 正常输出。

最后两行说明：`InternetServerManager` 真实跑完了 HTTP 请求，
并用 **ZLogger** 成功写了日志——这是 C# 侧完全正常工作的硬证据。

资源包完好性：`Godot 4.7.0 packfmt=4 条目=26522 md5抽检失败=0`。

---

## 四、真机实测：已成功进入游戏 ✅

在 RedmiBook 14 II（AMD Renoir，RADV Vulkan，Ubuntu 24.04）上实测通过：

```
Vulkan 1.4.318 - Forward+ - Using Device #0: AMD - AMD Radeon Graphics (RADV RENOIR)
[SceneManager] Changing scene to: uid://7rqvcn2algju
主存档已保存到 user://Csharp/save.res
[Save] 保存掉落物: pos=(519.7, -25.0)
[Save] 保存Feature[Map]...
```

机器上真实日志的统计：

| 指标 | 次数 |
|---|---|
| `Failed to load project assembly` | **0** |
| `Cannot instantiate C# script` | **0** |
| `FileNotFoundException` | **0** |
| `Changing scene`（场景切换成功） | **10** |
| `主存档已保存` | **11** |

存档落盘：`~/.local/share/godot/app_userdata/植物大战僵尸杂交版/Csharp/save.res`（127 KB），
同级还有 `Progress/`、`DailyLevel/`、`OnlineLevel/` 目录。

---

## 五、日志里哪些报错可以无视

跑起来之后日志仍会有一些红字，**都不是环境问题**，说清楚免得白折腾：

### 1. `Cannot open file 'res://Test/BenchmarkSceneDispatcher.cs'`（6 条）

发布时把测试脚本剥掉了，但 `Global.tscn` 还留着对它的引用。Windows 版同样如此，
**无害**。

### 2. `NullReferenceException at TowerDefenseCharacter.DamagePointReach(...)`

完整调用链：

```
MultiPlayerManager._RpcReceiveMatchState
 -> TowerDefenseBattleNetworkHost.HandleLegacyMessage
 -> BattleEventReplicator.ApplyDamagePointReach
 -> TowerDefenseCharacter.DamagePointReach   ← 空引用
```

这是**多人对战**的网络消息复现逻辑：收到了「伤害点到达」的同步包，但本地找不到
对应的角色对象（单人游戏里本来就没有这个对象）。属于游戏自身对网络包的容错不足，
**与运行环境无关**，单人冒险模式不受影响。

### 3. `WARNING: [Event] Remote phase 'init'/'entry' was not received within 10 seconds`

游戏在等**远端（联机对手）**下发关卡阶段数据，等不到就超时回退，用本地关卡数据继续跑
（`executing local level data once`）。离线单人玩时必然出现，**是正常的降级行为**。

### 4. `5 ObjectDB instances were leaked at exit`

退出时的资源释放告警，Godot 常见，**无害**。

> 判断标准很简单：**只要没有 `Failed to load project assembly`、
> `Cannot instantiate C# script`、`FileNotFoundException`、`MissingMethodException`，
> 就说明运行环境（引擎/运行时/依赖）是好的**，剩下的红字都是游戏逻辑自己的事。

---

## 六、环境限制说明（开发沙箱 ≠ 你的桌面）

**开发沙箱**里没有 `/dev/dri`（设备节点被裁剪），GPU 在 sysfs 里可见但用不了，
所以图形窗口在那里起不来，只能靠 `--headless` 验证到「引擎 + 运行时 + 依赖」这一层。
headless 下游戏不进主循环，看不到 `[SceneManager] Changing scene`，属预期行为。

**真机桌面**（有显卡、有 `/dev/dri`）不受这个限制 —— 第四节的成功运行就是在真机上完成的。
直接跑 `./play-pvz.sh` 即图形启动；若 Vulkan 报错，用 `./play-pvz.sh --opengl3`。

---

## 七、为什么不用 APK（结论：不更优）

有人会想「同版本的 APK 是不是改一下就能在桌面跑？」——**不会，反而更难。**

1. **APK 里的 PCK 是 Android 平台的资源包。** 它的纹理烘焙成
   ETC2/ASTC 压缩格式；PC 版这里是 **S3TC**（实测本包内
   `FrontlawnBig.jpg-*.s3tc.ctex`、`Chapter2Building.png-*.s3tc.ctex` 等）。
   桌面 GPU 不认 Android 的纹理变体。发布版 PCK 里**没有原始 PNG**，
   要重新导入就得有完整源码工程——这条路直接断。
2. **APK 的程序集是 arm64 的。** x86_64 Ubuntu 上要靠 QEMU 转译，
   又慢又不稳；而且 Android 的 .NET 走 Mono + JNI + bionic libc，
   桌面根本不能复用。
3. **它并没有减少任何工作。** 核心矛盾是「.NET 的 `AssemblyLoadContext`
   要真实文件路径，而 PCK 是虚拟包」——换 APK 一样存在，你还是得解包。
4. **我们这条路已经端到端验证过了**（Windows 完整分发跑通，
   Linux 现在依赖也补齐了）；换 APK 等于把已知能跑的方案换成未知的。

**唯一值得做的前提**：如果那个 APK 里含有**同一套 IL 程序集**，理论上 IL 是平台无关的，
可以拿来替换 Windows 版那个——但没有任何收益，因为 Windows 版的 dll 已经在
Linux 上跑起来了，缺的只是上面那 11 个 NuGet 库。

---

## 八、存档位置

- Linux 桌面版：`~/.local/share/godot/app_userdata/植物大战僵尸杂交版/`
  （C# 存档在 `Csharp/save.res`）
- 原包外那份 `save-backup/` 是上一轮从 Windows 侧备份的（146 KB，
  被测试重写过）。根目录那份 2025/9/27 的存档完好，进度大概率还在那里。

---

## 九、故障速查

| 症状 | 处理 |
|---|---|
| `Failed to load project assembly` + 136 条 `Cannot instantiate` | 没用 `--path` 跑解包目录；或 `bin/Debug/PlantsVsZombies.dll` 不在位（删过 `bin/` 会这样，重跑脚本会自动重放） |
| `FileNotFoundException: Microsoft.Extensions.*` | 依赖没补齐，跑 `python3 fetch_deps.py "$DATA_DIR" "$BIN_DEBUG"` |
| `MissingMethodException: MemoryMarshal.GetReference` | 删掉 `System.Memory.dll`（唯一要排除的垫片包） |
| `TypeInitializationException: TransientStaticTextureRelease` + 缺 `Microsoft.CodeAnalysis` | 别删 Roslyn！恢复 `Microsoft.CodeAnalysis.dll` 与 `.CSharp.dll`（切场景时反射要用） |
| 刚进游戏卡住、之后没有任何输出 | 同上：多半是切场景时 `TransientStaticTextureRelease` 初始化失败，看 `user://logs/godot.log` 确认 |
| `Could not create directory: $HOME/.local/share/godot` 然后 signal 11 | `$HOME` 不可写；脚本会自动降级，手动可 `HOME=/可写路径 ./play-pvz.sh` |
| Vulkan 初始化失败 | `./play-pvz.sh --opengl3` |
| 场景切换但不显示 / 黑屏 | 显卡驱动或 Vulkan 层问题，先试 opengl3 |
| 想彻底重来 | `rm -rf <工程>/.godot/mono/temp/bin <工程>/.deps-fixed`，再跑脚本（会自动重建） |

---

## 十、桌面快捷方式（双击启动，无终端窗口）

一条命令装好：

```bash
cd ~/pvzhybrid && ./install-desktop.sh
```

会做三件事：① 从游戏本体 `res://icon.png` 生成多尺寸图标并装进 hicolor 主题；
② 生成 `pvz-hybrid.desktop`（`Terminal=false`，所以没有终端窗口）；
③ 放到**桌面**和**应用程序菜单**两处。

其他用法：

```bash
./install-desktop.sh --desktop     # 只放桌面
./install-desktop.sh --menu        # 只放应用程序菜单
./install-desktop.sh --uninstall   # 卸载快捷方式（游戏文件不动）
```

### 图标用的是哪个

游戏 exe 自带的图标其实只是 **Godot 默认图标**（那个 exe 就是 Godot 编辑器），
所以真正的游戏图标取自发布包里的 `res://icon.png`（256×256，花色+手套+「杂交版」），
从解包后的工程目录 `pvzproj/icon.png` 取，生成 256/128/64/48/32 五个尺寸。

### 为什么不会出现终端窗口

`Terminal=false` 意味着没有终端，于是：

- `play-pvz.sh` 检测到 stdout 不是终端（`[ ! -t 1 ]`），自动把全过程写进
  `logs/play-<时间>.log`，并维护 `logs/latest.log` 软链。**出问题看这个文件。**
- 脚本会主动补齐 `PATH`（`/usr/local/bin:/usr/bin:/bin` 等）。从 .desktop 启动时
  环境很精简，不补的话会找不到 `python3`/`curl`，表现成「双击没反应」。
- shebang 用 `/bin/bash` 而不是 `#!/usr/bin/env bash`，同样是为了不依赖 PATH。
- `run-game.sh` 在启动前和失败时用 `notify-send` 弹桌面通知，避免「双击了没反应」。

### GNOME 上图标显示成文本 / 提示未信任

GNOME（Ubuntu 默认）要求桌面启动器被显式标记为可信才会正常显示和运行：

```bash
gio set ~/桌面/植物大战僵尸杂交版.desktop metadata::trusted true
```

或者右键该文件选「**允许启动**」。装脚本时已自动尝试过这一步；
不行就直接从**应用程序菜单**搜「植物大战僵尸杂交版」启动，菜单项不受此限制。

### 实测记录

- `desktop-file-validate` **通过**
- 模拟 `.desktop` 启动条件实测（极简 `PATH` + cwd 不是工作区）：
  `run-game.sh --check` 退出码 0，日志正确落到 `logs/`
- 安装 / 卸载往返测试通过，卸载后只剩系统自动生成的 cache 文件

---

## 十一、游戏更新怎么做（重要）

Windows 上是「整个目录覆盖」，Linux 这边**不要只换 `.pck`**。

### 要覆盖哪些东西

更新时请把这几样一起覆盖到原处（保持相对位置不变）：

| 文件 | 必须？ | 说明 |
|---|---|---|
| `植物大战僵尸杂交版发布版X.Y.Z.Csharp.pck` | ✅ | 资源包 |
| `data_PlantsVsZombies_windows_x86_64/PlantsVsZombies.dll` | ✅ | **游戏主逻辑，版本必须与 PCK 匹配** |
| `data_PlantsVsZombies_windows_x86_64/PlantsVsZombies.deps.json` | ✅ | 依赖清单，新版可能增删依赖 |
| `data_PlantsVsZombies_windows_x86_64/PlantsVsZombies.runtimeconfig.json` | ✅ | 决定需要的 .NET 版本 |
| exe | ❌ | Linux 用不到（那是 Godot 编辑器 + Windows 启动器） |

> ⚠️ **只换 `.pck` 不换 dll 是最容易踩的坑**：新 PCK 会引用新版才有的 C# 类，
> 旧 dll 里没有，结果是满屏 `Cannot instantiate C# script because the associated
> class could not be found`。

### 脚本会自动处理

`play-pvz.sh` 现在用**指纹**（PCK 路径 + 文件大小 + mtime）判断是否需要重做，
所以下面两种情况都自动覆盖，**不需要手动删任何东西**：

- **改名升级**（`0.29.0` → `0.30.0`）：路径变了 → 检测到 → 重新解包 + 重新解析依赖
- **同名覆盖**（新版仍叫 `0.29.0`）：大小/时间戳变了 → 同上

重解包时会先清空工程目录，避免旧版文件残留干扰；同时删掉 `.deps-fixed`
强制按新版 `deps.json` 重解析依赖（新版可能缺新的库，也可能不再需要旧的）。

**目录里同时存在多个版本的 `.pck` 也没关系**——脚本会挑版本号最高的那个：

```
==> 资源包: .../植物大战僵尸杂交版发布版0.30.0.Csharp.pck
==> 更新/解包：资源包换了：...0.29.0.Csharp.pck -> ...0.30.0.Csharp.pck
```

（版本号比较优先于文件时间戳，所以即使旧文件的 mtime 更新也不会选错。）

### 能不能像 Windows 一样「整个文件夹覆盖/替换」

**可以。** 那个文件夹（`ext3/植物大战僵尸杂交重制版/`）里混着两类东西：

```
植物大战僵尸杂交重制版/
├── 植物大战僵尸杂交版发布版X.Y.Z.Csharp.pck   ← Windows 发布的原始文件，要覆盖
├── data_PlantsVsZombies_windows_x86_64/       ← Windows 发布的原始文件，要覆盖
├── 杂交版启动补丁.cs.hta                       ← Windows 的启动器，Linux 用不到，留着无害
└── pvzproj/                                   ← 【脚本生成】解包后的工程，可随时重建
```

`pvzproj/` 是脚本自己产出的，**不在发布包里**。所以：

- 解压时看到目录里已经有 `pvzproj/`，不用管，直接覆盖其他文件即可（不会被覆盖掉）
- 就算你把整个文件夹换掉、`pvzproj/` 一起没了，脚本也会在**新位置重新建一个**

两种情况都实测过：

| 操作 | 实测结果 |
|---|---|
| 文件覆盖到原目录 | 指纹发现变化 → 自动重解包 + 重解析依赖 ✅ |
| 整个文件夹换成新名字 | 自动在新位置重建工程、重新解包、重新解析依赖 ✅ |
| `data_*` 目录改名 | 通配符兜底自动找到 ✅ |

**唯一建议**：保持顶层文件夹名和 `.pck` 文件名里的版本号不变最省事；改了名也能跑，
只是会多花 1~2 分钟重新解包一次（因为工程目录是跟着 `.pck` 位置走的）。

### 更新检测现在按「内容」判断，不再依赖时间戳

脚本判断是否需要重解包分三层，越靠后越准、代价越大：

| 层级 | 条件 | 动作 | 代价 |
|---|---|---|---|
| 1 | `.pck` **路径**变了（0.29 → 0.30） | 直接重解包 | 无 |
| 2 | stat 签名（大小+mtime+inode+ctime）**没变** | 内容必然没变，跳过 | **零开销** |
| 3 | 签名变了 | 算一次内容哈希跟上次比：<br>哈希不同 → 重解包<br>哈希相同 → 只更新时间戳记录，**不重解包** | 读 460MB，约 1~2 秒 |

这样两类情况都不会再误判：

- **覆盖了但时间戳没变** → 第 3 层哈希不同 → **能抓到** ✅
- **时间戳变了但内容没变**（例如重新解压同一个包）→ 第 3 层哈希相同 →
  **不白重解包** ✅

所以以前那个"同名覆盖 + 时间戳没变就认不出来"的坑**没有了**，不用再特意加 `--refresh`。
第 3 层的 1~2 秒只在时间戳动过时才发生，日常启动走第 2 层，无额外开销。

### `--refresh` 现在只用于强制

```bash
./play-pvz.sh --refresh     # 无条件重新解包（想彻底重来时用）
```

### 存档不受影响

存档在 `~/.local/share/godot/app_userdata/植物大战僵尸杂交版/`，
**不在工程目录里**，重解包不会碰它。更新后进度照旧。

### 如果新版换了引擎/.NET 版本

看 `data_*/PlantsVsZombies.runtimeconfig.json` 里的 `tfm`：

```json
"tfm": "net9.0"        ← 需要 .NET 9
```

如果新版要 .NET 10（`net10.0`），改 `play-pvz.sh` 里的
`DOTNET_MAJOR=10` 再跑即可。Godot 引擎版本同理：若新版 PCK 的
`pack_format` 超出 Godot 4.7 能读的范围，需要换对应版本的 Godot
（脚本里的 `GODOT_VER` / `GODOT_HASH_NAME`）。

### 想彻底重来

```bash
rm -rf "<工程目录>/pvzproj"        # 或
./play-pvz.sh --refresh
```

---

## 十二、搬到新 Ubuntu 系统（解压就能用）

### 怎么打包

```bash
./make-dist.sh              # 产出 dist/pvzhybrid-linux-<日期>.tar.gz（约 710 MB）
./make-dist.sh --dry-run    # 只列出会打包什么
```

**用 tar.gz 而不是 zip**：tar.gz 保留可执行权限，zip 常常丢。丢了虽然脚本有权限
自愈，但用户得先用 `bash xxx.sh` 才能触发，不友好。

### 目标机器上怎么用

```bash
tar -xzf pvzhybrid-linux-<日期>.tar.gz
cd pvzhybrid-linux
./play-pvz.sh --check      # 首次：初始化快捷方式 + 自检（一条命令搞定）
```

跑完这一步，桌面和应用程序菜单里就都有「植物大战僵尸杂交版」了，
之后**双击图标即可**，不用再开终端。

> **为什么首次要先跑一条终端命令？**
> `.desktop` 规范**不支持相对路径**（这是格式本身的限制）。所以快捷方式的
> `Exec` 指向一个固定路径的启动器
> `~/.local/bin/pvz-hybrid`，而那个符号链接需要被创建一次 —— 由上面这条命令完成。
>
> 好处是：**项目之后解压/移动到哪都无所谓**，启动器链接会自动跟上
> （`run-game.sh` 每次启动都会核对修正）。

### 快捷方式是怎么做到「位置无关」的

```
.desktop 的 Exec  ──►  ~/.local/bin/pvz-hybrid  （固定路径，符号链接）
                              │
                              ▼
                        <项目>/pvz-hybrid-bootstrap.sh
                              │
                              ▼
                        <项目>/run-game.sh
```

- `Icon=pvz-hybrid`：用**图标主题名**而不是绝对路径，同样与位置无关
- 项目被移动后，`run-game.sh` 启动时会重指链接（实测：移动目录后快捷方式照常可用）
- 链接坏了（项目被删）会给桌面通知，不会静默失败

### 为什么能做到「解压就能用」

分发包里已经带了全部运行环境，**目标机器不需要装任何东西、也不需要联网**：

| 已打包内容 | 作用 | 体积 |
|---|---|---|
| `tools/Godot_v4.7-stable_mono_linux_x86_64/` | 引擎（138 MB 可执行） | 220 MB |
| `tools/dotnet/` | .NET 9 运行时 | 75 MB |
| `ext3/.../pvzproj/` | **已解包**的工程 + 17 个依赖 dll + `.deps-fixed` | 650 MB |
| `ext3/.../*.pck` + `data_*` | 游戏本体 | 490 MB |

`.pvz-state` 和 `.deps-fixed` 特意**没有**排除，所以首次启动能直接跳过解包和依赖
解析，几秒进游戏。

### 那个 `.desktop` 是怎么自愈的

`.desktop` 规范**不支持相对路径**，所以项目里那份必然带着打包机的绝对路径。
处理办法：

1. 打包时把项目自带 `.desktop` 里的路径换成占位符 `__PROJECT_DIR__`
2. `run-game.sh` 每次启动核对一次：路径不对（比如是占位符、或是别的机器路径）
   → 按当前位置重新生成，并重装桌面/菜单快捷方式

所以**首次双击**就会自动修好，之后正常使用。实测：

```
解压出来的:  Exec=__PROJECT_DIR__/run-game.sh
首次运行后:  Exec=/home/wdf/pvzhybrid/.dist-test/解压位置/run-game.sh
```

### 顺带修掉的其他部署坑

| 坑 | 处理 |
|---|---|
| `zip`/U 盘拷贝丢掉可执行位 | `play-pvz.sh` 启动时检测并 `chmod 755` 修回（用 755 不用 `+x`，避免 umask 造出不可读的 `--x--x--x`）|
| `.desktop` 启动时 PATH 很精简 | 脚本主动补齐标准目录；shebang 用 `/bin/bash` 而非 `env bash` |
| 从符号链接目录启动导致路径误判 | `run-game.sh` 用 `readlink -f` 解析成真实路径再比较，避免反复重装 |
| 反复重装/反复弹通知 | 自愈带 10 分钟节流标记 `logs/.desktop-repair-tried` |
| GNOME 要「信任」才能双击运行 | 安装时自动 `gio set metadata::trusted true`；不行就从应用菜单启动 |
| 包里的路径写成项目外 | `make-dist.sh` 默认输出到项目内 `dist/` |

### 新系统上可能仍要装的东西

绝大多数情况什么都不用装（Ubuntu 24.04 桌面版自带 python3、curl、libvulkan1、
libfontconfig1、CJK 字体、`gio`、`xdg-user-dir`）。只有极少数情况需要注意：

| 缺少 | 影响 | 解决 |
|---|---|---|
| `notify-send`（libnotify-bin） | 不弹启动通知，游戏照常 | `sudo apt install libnotify-bin` |
| 显卡驱动 / Vulkan | 起不来 | `./play-pvz.sh --opengl3` |
| 不是 x86_64（如 arm64） | 完全跑不了 | 需要 arm 版引擎与运行时 |

---

## 十三、Dock/任务栏图标与名称（乱码问题）

### 症状

游戏窗口在 GNOME 侧边栏/Dock 上**没有游戏图标**（用通用图标），
鼠标悬停显示的名字是**乱码**，例如：

```
æ¤ç©å¤§æ...ç... æ··äº¤ç...
```

### 为什么会这样

Dock 不是直接读窗口标题，而是先把窗口**关联**到一个 `.desktop`，再从那里取
图标和名称。关联靠「窗口标识」：

| 窗口类型 | 标识 |
|---|---|
| Wayland 原生窗口 | xdg-toplevel 的 **app_id** |
| XWayland 窗口 | **WM_CLASS** |

`.desktop` 里对应的字段是 `StartupWMClass=`。**关联不上时**，Dock 只能
退回显示窗口标题（标题若有问题就是乱码）+ 一个通用图标。

原来的 `.desktop` 写的是 `StartupWMClass=Godot`，而 Godot 引擎设置 app_id 用的是

```
libdecor_frame_set_app_id(..., "Godot_Engine")     ← 在 godot 二进制里可见
```

两者对不上，于是图标和名字都不正常。现已改为 `StartupWMClass=Godot_Engine`。

### ⚠️ 不能靠改应用名来解决乱码

`project.binary` 里 `application/config/name` 是「植物大战僵尸杂交版」。
把窗口标题弄成 ASCII 看起来是个办法，但**绝对不能改这个名字**，因为
**Godot 用它派生用户数据（存档）目录**：

```
user://  ->  ~/.local/share/godot/app_userdata/<应用名>/
```

实测把应用名改成 `PvZ Hybrid Remastered v0.29` 后，Godot 立刻去找
`app_userdata/PvZ Hybrid Remastered v0.29/`，**原存档目录就找不到了**。
所以名字必须保持原样，`patch-appname.py` 只保留作研究/应急用途。

### 如果改了 StartupWMClass 图标还是不对

用附带脚本查真实标识（**先启动游戏**，让它停在主界面，然后另开终端）：

```bash
cd ~/pvzhybrid && ./diagnose-dock.sh
```

它会打印：
- X11/XWayland 下游戏窗口的 `WM_CLASS` 与 `_NET_WM_NAME`
- Wayland 原生窗口的 app_id（通过 GNOME Shell，若被禁用会给出替代命令）
- 当前 `.desktop` 里的 `StartupWMClass` 值

把 `WM_CLASS`（第二个值）发我，改 `lib-desktop.sh` 里那一行再跑
`./install-desktop.sh` 即可。

### 名称乱码的次要处理

即使窗口关联对了，窗口标题本身可能仍是乱码（那是 Godot 把 UTF-8 应用名
传给窗口系统时的编码问题，Windows 版同样存在）。**关联修好后，Dock 显示的
是 `.desktop` 里的正常中文名，乱码只在个别悬停提示里出现**，不影响游戏。

---

## 十四、脚本语法均已校验

`bash -n play-pvz.sh` 通过；`setup_project.py` / `fetch_deps.py` 均 `python3 -m py_compile` 通过；
`play-pvz.sh --check` 与 `--headless` 全流程实跑通过。

