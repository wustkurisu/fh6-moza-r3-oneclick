# 魔爪 R3 + ES 的《地平线 6》一键配置

适用于 Windows 上的 Steam 版《极限竞速：地平线 6》。安装包同时包含 R3 的原生模式（`346E:0005`）和地平线兼容模式（`346E:0015`）的键位与力反馈配置。

## 安装

1. 解压整个安装包。连接并开启 R3，完全退出游戏。
2. 双击解压目录里的 `Install.cmd`。安装器会查找 Steam 游戏、备份原文件、安装键位和力反馈，并选中与当前 R3 匹配的预设。你以前保存的自定义方向盘档位仍可在游戏里选用。
3. 安装完成后从 Steam 启动游戏。首次游玩还没有方案选择记录时，直接在方向盘设置中选择 R3 默认方案即可。

安装程序以当前 Windows 用户身份离线运行。启动器仅为本次 PowerShell 进程使用 `RemoteSigned`。可用文本编辑器查看 `Install.ps1`，四个键位与力反馈文件在 `presets` 文件夹。

用 `-Check` 可先检查安装条件。自动查找失败时，在解压目录打开命令提示符，用 `-GamePath` 指定包含 `media` 文件夹的游戏目录。

```bat
Install.cmd -Check
Install.cmd -GamePath "D:\SteamLibrary\steamapps\common\ForzaHorizon6"
```

如果 Windows 阻止运行下载的未签名脚本，可以先查看源码。确认来源可信后，右键原始 ZIP，打开「属性」，勾选「解除锁定」，再重新解压。受单位策略管理的电脑请联系管理员。若提示无法写入游戏，请检查当前 Windows 用户是否对 Steam 游戏库有写入权限。 [Microsoft PowerShell 执行策略说明](https://learn.microsoft.com/zh-cn/powershell/module/microsoft.powershell.core/about/about_execution_policies)

## 进游戏验证

在「设置 → 控制 → 改变输入映射 → 方向盘」查看是否选中了 R3 默认配置。按 **N** 打开地图，确认松开油门时地图保持当前缩放。驾驶时按 **Y** 倒转，再按 **A** 确认继续。分别踩下并松开油门和刹车，确认两个踏板松开时都归零。

## 恢复安装前的配置

完全退出游戏。安装备份位于游戏目录的 `media\FH6-MOZA-R3-backups\<时间戳>`。把该次备份里实际存在的 ZIP 放回 `media`。如果备份里还有 `LastUsedProfile`，按安装程序显示的原路径恢复它，再启动游戏。
