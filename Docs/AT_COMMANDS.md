# EC25Toolbox AT 指令清单 | AT Command Inventory

> 本文档按当前工作区源码、测试夹具和终端快捷命令整理，集中说明 EC25Toolbox 中可静态识别的 AT 指令、参数形态、用途和代码位置。
>
> This document inventories the AT commands statically identifiable from the current EC25Toolbox source, tests, and terminal shortcuts, including their parameter forms, purposes, and code locations.

## 1. 范围与约定 | Scope and conventions

### 1.1 清单边界 | Inventory boundary

| 项目 | 说明 |
| --- | --- |
| 当前版本 | 文档与当前工作区代码对应；版本号以项目现有发布文档为准。 |
| 覆盖范围 | 主动发送给 EC25/兼容模块的命令、模块返回的最终响应、URC（Unsolicited Result Code，非请求结果码），以及测试中用于验证协议解析的命令样例。 |
| 动态终端命令 | Terminal 页面允许用户输入任意 AT 文本，因此无法从静态源码枚举未来由用户输入的全部命令；本文列出应用内置快捷命令和动态命令入口。 |
| 参数占位符 | &lt;...&gt; 表示运行时参数；&lt;PIN&gt;、&lt;APN&gt;、&lt;AID&gt;、电话号码和 APDU 等敏感或动态值不写入固定值。 |
| 设备上报 | URC 不一定由应用主动发送，而是由模块异步上报；仍按独立章节列出，便于协议和事件映射查阅。 |
| 测试命令 | 测试专用或合成占位符单独列出，不将其误认为产品业务功能。 |
| 硬件边界 | 本清单是源码和静态契约整理，不等同于真实模块、SIM、运营商网络、VoLTE/VoWiFi 或 DJI Cellular 模块的现场验收。 |

### 1.2 调用与日志约定 | Invocation and logging

| 调用入口 | 用途 | 日志/安全注意事项 |
| --- | --- | --- |
| ModemStore.send(...) | 普通模块命令、查询、配置和业务流程。 | 会按当前项目的传输与日志策略执行。 |
| ModemStore.sendUnlogged(...) | PIN、QDC507 派生响应等敏感值命令。 | 用于避免敏感参数进入普通命令日志。 |
| executeTerminalCommand(...) | Terminal 页面发送用户自定义命令。 | 动态命令不在静态清单中展开；应按用户输入和设备响应处理。 |
| EC25Transport.transact(...) | 底层串口/USB 传输、超时和重试。 | 负责传输层行为，不改变上层命令语义。 |

## 2. 命令分组总览 | Command groups

| 章节 | 主题 | 主要命令族 |
| --- | --- | --- |
| 3 | 连接、初始化与终端快捷操作 | AT、ATE0、ATI、AT+CMEE、ATS0、AT+CNMI、AT+CLIP |
| 4 | 设备身份、SIM 状态与温度 | AT+CGMI、AT+CGMM、AT+CGMR、AT+CGSN、AT+CIMI、AT+QCCID、AT+CNUM、AT+QSIMSTAT、AT+QTEMP |
| 5 | SIM PIN 与安全状态 | AT+CPIN、AT+CLCK、AT+QPINC、AT+CPWD |
| 6 | 网络注册、PDP 与恢复 | AT+CSQ、AT+COPS、AT+CREG、AT+CGREG、AT+CEREG、AT+CGATT、AT+CGACT、AT+CGPADDR、AT+QNWINFO、AT+QENG、AT+QCAINFO、AT+CGDCONT、AT+QCFG="usbnet"、AT+CFUN |
| 7 | SMS 短信 | AT+CMGF、AT+CSCS、AT+CPMS、AT+CMGL、AT+CMGR、AT+CMGD、AT+CMGS、AT+CNMI |
| 8 | 语音呼叫、DTMF 与电话簿 | ATD、ATA、ATH、AT+CHUP、AT+CLCC、AT+VTS、AT+CPBS、AT+CPBR、AT+CPBW |
| 9 | GNSS/GPS | AT+QGPS、AT+QGPSCFG、AT+QGPSLOC、AT+QGPSGNMEA、AT+QGPSEND |
| 10 | 模块配置、USB、IMS、VoLTE 与音频 | AT+QCFG、AT+QPCMV、AT+CFUN=1,1 |
| 11 | eSTK/eUICC 与 VoWiFi SIM 访问 | AT+CCHO、AT+CCHC、AT+CGLA、AT+CSIM |
| 12 | QDC507 专用管理 | AT+QADBKEY |
| 13 | Terminal 与远程命令入口 | 内置快捷命令、任意命令转发 |
| 14 | 最终响应与 URC | OK、ERROR、+CME ERROR、+CMS ERROR、电话/SMS/网络/生命周期 URC |
| 15 | 测试专用命令样例 | AT+CMD*、AT+TESTTERMINAL 等 |

## 3. 连接、初始化与终端快捷命令 | Connection, initialization, and terminal shortcuts

### 3.1 基础连接与初始化 | Basic connection and initialization

| 命令 | 用途 | 代码位置 |
| --- | --- | --- |
| AT | 基础连通性探测；底层传输建立和部分恢复流程使用。 | [EC25Transport.swift](../Sources/EC25Toolbox/EC25Transport.swift)、[ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| ATE0 | 关闭模块命令回显，减少终端解析中的回显干扰。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| ATI | 查询模块识别信息，用于终端快捷操作。 | [TerminalView.swift](../Sources/EC25Toolbox/Views/Terminal/TerminalView.swift) |
| AT+CMEE=2 | 启用扩展错误报告，便于显示更具体的模块错误。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| ATS0? | 查询自动接听铃响次数。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[ModemStore+Phone.swift](../Sources/EC25Toolbox/Features/Phone/ModemStore+Phone.swift) |
| ATS0=0 | 关闭自动接听。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[ModemStore+Phone.swift](../Sources/EC25Toolbox/Features/Phone/ModemStore+Phone.swift) |
| AT+CNMI=2,1,0,0,0 | 配置新短信指示方式；短信流程和初始化流程使用。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[ModemStore+SMS.swift](../Sources/EC25Toolbox/Features/SMS/ModemStore+SMS.swift) |
| AT+CLIP=1 | 启用来电号码显示。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |

### 3.2 内置 Terminal 快捷命令 | Built-in Terminal shortcuts

Terminal 页面提供以下常用查询快捷项；它们最终仍通过通用终端命令入口发送。

| 快捷命令 | 用途 |
| --- | --- |
| AT | 测试模块是否响应。 |
| ATI | 查询模块识别信息。 |
| AT+CPIN? | 查询 SIM PIN 状态。 |
| AT+QCCID | 查询 SIM ICCID。 |
| AT+CIMI | 查询 IMSI。 |
| AT+CNUM | 查询本机号码。 |
| AT+CSQ | 查询信号质量。 |
| AT+QNWINFO | 查询当前无线接入和网络信息。 |
| AT+COPS? | 查询运营商选择/注册信息。 |
| AT+CGATT? | 查询分组域附着状态。 |
| AT+CGDCONT? | 查询 PDP 上下文配置。 |
| AT+CGPADDR | 查询 PDP 地址。 |
| AT+QENG="servingcell" | 查询服务小区工程信息。 |
| AT+QCAINFO | 查询载波聚合信息。 |
| AT+QCFG="usbnet" | 查询 USB 网络模式。 |

## 4. 设备身份、SIM 状态与温度 | Device identity, SIM status, and temperature

| 命令 | 用途 | 代码位置 |
| --- | --- | --- |
| AT+CGMI | 查询制造商。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| AT+CGMM | 查询模块型号。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| AT+CGMR | 查询固件版本。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| AT+CGSN | 查询设备序列号/IMEI。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| AT+CIMI | 查询 IMSI。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[TerminalView.swift](../Sources/EC25Toolbox/Views/Terminal/TerminalView.swift) |
| AT+QCCID | 查询 SIM ICCID。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[ModemStore+SIMPIN.swift](../Sources/EC25Toolbox/Features/SIM/ModemStore+SIMPIN.swift) |
| AT+CNUM | 查询订户/本机号码；部分设备不返回时触发电话簿回退。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| AT+QSIMSTAT? | 查询 Quectel SIM 检测状态。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| AT+QTEMP | 查询模块温度。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| AT+CPBS="ON" | 切换到本机/设备电话簿存储区，用于号码回退读取。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| AT+CPBR=? | 查询电话簿可读范围。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| AT+CPBR=&lt;start&gt;,&lt;end&gt; | 读取指定电话簿范围。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |

## 5. SIM PIN 与安全状态 | SIM PIN and security state

| 命令 | 用途 | 参数/安全说明 | 代码位置 |
| --- | --- | --- | --- |
| AT+CPIN? | 查询 SIM PIN/PUK 等当前安全状态。 | 不包含敏感值。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[ModemStore+SIMPIN.swift](../Sources/EC25Toolbox/Features/SIM/ModemStore+SIMPIN.swift) |
| AT+CPIN="&lt;PIN&gt;" | 提交 SIM PIN。 | &lt;PIN&gt; 为运行时值；通过敏感参数路径发送。 | [ModemStore+SIMPIN.swift](../Sources/EC25Toolbox/Features/SIM/ModemStore+SIMPIN.swift) |
| AT+CLCK="SC",2 | 查询 SIM PIN 锁定状态。 | 不包含 PIN 值。 | [ModemStore+SIMPIN.swift](../Sources/EC25Toolbox/Features/SIM/ModemStore+SIMPIN.swift) |
| AT+CLCK="SC",&lt;1\|0&gt;,"&lt;PIN&gt;" | 启用或关闭 SIM PIN 锁。 | &lt;1\|0&gt; 表示启用/关闭；&lt;PIN&gt; 为敏感值。 | [ModemStore+SIMPIN.swift](../Sources/EC25Toolbox/Features/SIM/ModemStore+SIMPIN.swift) |
| AT+QPINC="SC" | 查询 SIM PIN/PUK 剩余尝试次数。 | 不包含 PIN 值。 | [ModemStore+SIMPIN.swift](../Sources/EC25Toolbox/Features/SIM/ModemStore+SIMPIN.swift) |
| AT+CPWD="SC","&lt;currentPIN&gt;","&lt;newPIN&gt;" | 修改 SIM PIN。 | 当前 PIN 和新 PIN 均为敏感运行时值；通过敏感参数路径发送。 | [ModemStore+SIMPIN.swift](../Sources/EC25Toolbox/Features/SIM/ModemStore+SIMPIN.swift) |

## 6. 网络注册、PDP 与恢复 | Network registration, PDP, and recovery

### 6.1 网络状态查询 | Network status queries

| 命令 | 用途 | 代码位置 |
| --- | --- | --- |
| AT+CSQ | 查询接收信号强度和质量。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[TerminalView.swift](../Sources/EC25Toolbox/Views/Terminal/TerminalView.swift) |
| AT+COPS? | 查询当前运营商选择和注册信息。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[TerminalView.swift](../Sources/EC25Toolbox/Views/Terminal/TerminalView.swift) |
| AT+CREG? | 查询电路域网络注册状态。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| AT+CGREG? | 查询分组域网络注册状态。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| AT+CEREG? | 查询 EPS/LTE 网络注册状态。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| AT+CGATT? | 查询 GPRS/分组域附着状态。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[ModemStore+Recovery.swift](../Sources/EC25Toolbox/Features/Network/ModemStore+Recovery.swift) |
| AT+CGACT? | 查询 PDP 上下文激活状态。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| AT+CGPADDR | 查询 PDP 上下文 IP 地址。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[TerminalView.swift](../Sources/EC25Toolbox/Views/Terminal/TerminalView.swift) |
| AT+QNWINFO | 查询当前无线接入技术、运营商和频段等网络信息。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[TerminalView.swift](../Sources/EC25Toolbox/Views/Terminal/TerminalView.swift) |
| AT+QENG="servingcell" | 查询服务小区工程信息。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[TerminalView.swift](../Sources/EC25Toolbox/Views/Terminal/TerminalView.swift) |
| AT+QCAINFO | 查询载波聚合状态。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[TerminalView.swift](../Sources/EC25Toolbox/Views/Terminal/TerminalView.swift) |
| AT+CGDCONT? | 查询 PDP 上下文及 APN 配置。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[TerminalView.swift](../Sources/EC25Toolbox/Views/Terminal/TerminalView.swift) |
| AT+QCFG="usbnet" | 查询 USB 网络接口模式。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[TerminalView.swift](../Sources/EC25Toolbox/Views/Terminal/TerminalView.swift) |

### 6.2 网络配置与恢复 | Network configuration and recovery

| 命令 | 用途 | 影响/注意事项 | 代码位置 |
| --- | --- | --- | --- |
| AT+COPS=2 | 取消当前运营商注册，用于网络研究/切换前置流程。 | 可能造成短时离网。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| AT+COPS=0 | 请求模块自动选择运营商并重新注册。 | 注册结果受 SIM、运营商和现场信号影响。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[ModemStore+Recovery.swift](../Sources/EC25Toolbox/Features/Network/ModemStore+Recovery.swift) |
| AT+CGATT=1 | 请求分组域附着。 | 需要模块和运营商网络支持。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[ModemStore+Recovery.swift](../Sources/EC25Toolbox/Features/Network/ModemStore+Recovery.swift) |
| AT+CFUN=0 | 将模块切换到低功能状态，作为恢复流程的一步。 | 会暂时停止部分无线功能。 | [ModemStore+Recovery.swift](../Sources/EC25Toolbox/Features/Network/ModemStore+Recovery.swift) |
| AT+CFUN=1 | 将模块恢复到全功能状态。 | 之后仍需等待网络重新注册。 | [ModemStore+Recovery.swift](../Sources/EC25Toolbox/Features/Network/ModemStore+Recovery.swift) |
| AT+CFUN=1,1 | 重启模块/应用功能。 | 会断开当前会话和网络；配置修改后由恢复流程使用。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[ModemStore+Recovery.swift](../Sources/EC25Toolbox/Features/Network/ModemStore+Recovery.swift)、[ModemStore+ModuleConfig.swift](../Sources/EC25Toolbox/Features/ModuleConfig/ModemStore+ModuleConfig.swift) |
| AT+CGDCONT=1,"IPV4V6","&lt;APN&gt;" | 修改 PDP 上下文 1 的 APN 和 IP 类型。 | &lt;APN&gt; 为运行时配置；实际联网能力取决于运营商和模块。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| AT+QCFG="usbnet",&lt;mode&gt; | 修改 USB 网络接口模式。 | &lt;mode&gt; 由模块固件支持范围决定；修改后通常需要重启。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[ModuleConfigModels.swift](../Sources/EC25Toolbox/Features/ModuleConfig/ModuleConfigModels.swift) |

## 7. SMS 短信 | SMS messaging

### 7.1 文本模式、存储和读取 | Text mode, storage, and reading

| 命令 | 用途 | 代码位置 |
| --- | --- | --- |
| AT+CMGF=1 | 切换到文本短信模式。 | [ModemStore+SMS.swift](../Sources/EC25Toolbox/Features/SMS/ModemStore+SMS.swift) |
| AT+CMGF=0 | 切换到 PDU 短信模式，用于 PDU 列表读取。 | [ModemStore+SMS.swift](../Sources/EC25Toolbox/Features/SMS/ModemStore+SMS.swift) |
| AT+CSCS="UCS2" | 设置短信字符集为 UCS2。 | [ModemStore+SMS.swift](../Sources/EC25Toolbox/Features/SMS/ModemStore+SMS.swift) |
| AT+CPMS="&lt;storage&gt;","&lt;storage&gt;","&lt;storage&gt;" | 选择短信读取、写入和接收存储区。 | &lt;storage&gt; 为运行时存储区名称。 | [ModemStore+SMS.swift](../Sources/EC25Toolbox/Features/SMS/ModemStore+SMS.swift) |
| AT+CMGL="ALL" | 以文本模式列出短信。 | 用于文本短信刷新和自动清理流程。 | [ModemStore+SMS.swift](../Sources/EC25Toolbox/Features/SMS/ModemStore+SMS.swift) |
| AT+CMGL=4 | 以 PDU 模式列出全部短信。 | 用于设备仅支持 PDU 列表读取时的回退路径。 | [ModemStore+SMS.swift](../Sources/EC25Toolbox/Features/SMS/ModemStore+SMS.swift) |
| AT+CMGR=&lt;index&gt; | 读取指定索引的短信，并用于标记为已读的流程。 | &lt;index&gt; 为短信存储索引。 | [ModemStore+SMS.swift](../Sources/EC25Toolbox/Features/SMS/ModemStore+SMS.swift) |
| AT+CMGD=&lt;index&gt; | 删除指定索引的短信。 | &lt;index&gt; 为短信存储索引。 | [ModemStore+SMS.swift](../Sources/EC25Toolbox/Features/SMS/ModemStore+SMS.swift) |

### 7.2 发送和新短信指示 | Sending and new-message indications

| 命令/交互 | 用途 | 参数/说明 | 代码位置 |
| --- | --- | --- | --- |
| AT+CMGS="&lt;UCS2 destination&gt;" | 开始发送文本短信。 | 命令成功后发送 UCS2 编码正文，最后发送 Ctrl-Z（0x1A）。 | [ModemStore+SMS.swift](../Sources/EC25Toolbox/Features/SMS/ModemStore+SMS.swift) |
| AT+CMGS="&lt;UCS2 destination&gt;" + payload + Ctrl-Z | 完成一次文本短信发送交互。 | 目标号码和正文均由运行时输入生成；文档不固定真实号码或内容。 | [ModemStore+SMS.swift](../Sources/EC25Toolbox/Features/SMS/ModemStore+SMS.swift) |
| AT+CNMI=2,1,0,0,0 | 配置新短信到达时的模块提示方式。 | 到达事件由 +CMTI: 等 URC 表示。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[ModemStore+SMS.swift](../Sources/EC25Toolbox/Features/SMS/ModemStore+SMS.swift) |

> 当前源码包含 PDU 模式的短信列表读取回退，但未将固定的 PDU 发送流程列为独立业务命令；不要将 AT+CMGF=0 误解为应用已经实现 PDU 发送。

## 8. 语音呼叫、DTMF 与电话簿 | Voice calls, DTMF, and phonebook

### 8.1 呼叫控制 | Call control

| 命令 | 用途 | 代码位置 |
| --- | --- | --- |
| ATD&lt;number&gt;; | 发起语音呼叫。 | &lt;number&gt; 会经过运行时号码清理；[ModemStore+Phone.swift](../Sources/EC25Toolbox/Features/Phone/ModemStore+Phone.swift) |
| ATA | 接听来电。 | [ModemStore+Phone.swift](../Sources/EC25Toolbox/Features/Phone/ModemStore+Phone.swift) |
| ATH | 挂断或释放当前呼叫；也用于后台释放残留呼叫。 | [ModemStore+Phone.swift](../Sources/EC25Toolbox/Features/Phone/ModemStore+Phone.swift)、[ModemStore+CallEvents.swift](../Sources/EC25Toolbox/Features/Phone/ModemStore+CallEvents.swift) |
| AT+CHUP | 请求挂断当前呼叫；拒接流程随后补发 ATH。 | [ModemStore+Phone.swift](../Sources/EC25Toolbox/Features/Phone/ModemStore+Phone.swift) |
| AT+CLCC | 查询当前呼叫列表和状态。 | [ModemStore+CallEvents.swift](../Sources/EC25Toolbox/Features/Phone/ModemStore+CallEvents.swift) |
| ATS0? | 查询自动接听设置。 | [ModemStore+Phone.swift](../Sources/EC25Toolbox/Features/Phone/ModemStore+Phone.swift) |
| ATS0=0 | 关闭自动接听。 | [ModemStore+Phone.swift](../Sources/EC25Toolbox/Features/Phone/ModemStore+Phone.swift) |

### 8.2 DTMF | Dual-tone multi-frequency

| 命令 | 用途 | 参数/说明 | 代码位置 |
| --- | --- | --- | --- |
| AT+VTS=? | 探测模块是否支持 DTMF。 | 能力探测，不代表现场网络支持语音业务。 | [ModemCapabilities.swift](../Sources/EC25Toolbox/ModemCapabilities.swift) |
| AT+VTS=&lt;tone&gt; | 在通话中发送一个 DTMF 音。 | &lt;tone&gt; 为运行时按键值。 | [ModemStore+Phone.swift](../Sources/EC25Toolbox/Features/Phone/ModemStore+Phone.swift) |

### 8.3 电话簿 | Phonebook

| 命令 | 用途 | 代码位置 |
| --- | --- | --- |
| AT+CPBS=? | 查询可用电话簿存储区。 | [ModemStore+Phone.swift](../Sources/EC25Toolbox/Features/Phone/ModemStore+Phone.swift)、[ModemCapabilities.swift](../Sources/EC25Toolbox/ModemCapabilities.swift) |
| AT+CPBS? | 查询当前电话簿存储区。 | [ModemStore+Phone.swift](../Sources/EC25Toolbox/Features/Phone/ModemStore+Phone.swift) |
| AT+CPBS="ON" | 选择设备/本机电话簿。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[ModemStore+Phone.swift](../Sources/EC25Toolbox/Features/Phone/ModemStore+Phone.swift) |
| AT+CPBR=? | 查询电话簿索引范围和容量。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift)、[ModemStore+Phone.swift](../Sources/EC25Toolbox/Features/Phone/ModemStore+Phone.swift) |
| AT+CPBR=&lt;start&gt;,&lt;end&gt; | 批量读取电话簿条目。 | &lt;start&gt;、&lt;end&gt; 为运行时索引。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| AT+CPBW=&lt;index&gt;,"&lt;number&gt;",&lt;type&gt;,"EC25 Toolbox" | 写入或更新电话簿条目。 | &lt;index&gt;、&lt;number&gt;、&lt;type&gt; 为运行时值；固定名称由应用生成。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| AT+CSCS="IRA" | 切换到 IRA 字符集，配合电话簿号码/名称写入。 | 保存或恢复电话簿读写前后的字符集状态。 | [ModemStore.swift](../Sources/EC25Toolbox/ModemStore.swift) |
| AT+CSCS="UCS2" | 恢复短信流程使用的 UCS2 字符集。 | 主要由短信流程使用。 | [ModemStore+SMS.swift](../Sources/EC25Toolbox/Features/SMS/ModemStore+SMS.swift) |

## 9. GNSS/GPS | GNSS/GPS

| 命令 | 用途 | 参数/说明 | 代码位置 |
| --- | --- | --- | --- |
| AT+QGPS=? | 探测 GNSS 命令能力。 | 能力探测。 | [ModemStore+GNSS.swift](../Sources/EC25Toolbox/Features/GNSS/ModemStore+GNSS.swift)、[ModemCapabilities.swift](../Sources/EC25Toolbox/ModemCapabilities.swift) |
| AT+QGPS? | 查询 GNSS 开关状态。 | 启动前后用于确认状态。 | [ModemStore+GNSS.swift](../Sources/EC25Toolbox/Features/GNSS/ModemStore+GNSS.swift) |
| AT+QGPSCFG="nmeasrc",1 | 配置 NMEA 数据源。 | 具体支持范围由模块固件决定。 | [ModemStore+GNSS.swift](../Sources/EC25Toolbox/Features/GNSS/ModemStore+GNSS.swift) |
| AT+QGPS=1 | 启动 GNSS。 | 可能需要等待模块定位。 | [ModemStore+GNSS.swift](../Sources/EC25Toolbox/Features/GNSS/ModemStore+GNSS.swift) |
| AT+QGPSLOC=2 | 查询 GNSS 定位结果。 | 当前定位读取优先使用带参数形式。 | [ModemStore+GNSS.swift](../Sources/EC25Toolbox/Features/GNSS/ModemStore+GNSS.swift) |
| AT+QGPSLOC | 查询 GNSS 定位结果的兼容/回退形式。 | 具体返回格式由固件决定。 | [ModemStore+GNSS.swift](../Sources/EC25Toolbox/Features/GNSS/ModemStore+GNSS.swift) |
| AT+QGPSGNMEA | 查询 GNSS NMEA 数据。 | 用于模块命令路径的 NMEA 读取。 | [ModemStore+GNSS.swift](../Sources/EC25Toolbox/Features/GNSS/ModemStore+GNSS.swift) |
| AT+QGPSEND | 停止 GNSS。 | 释放 GNSS 运行状态。 | [ModemStore+GNSS.swift](../Sources/EC25Toolbox/Features/GNSS/ModemStore+GNSS.swift) |

> GNSS 还存在 USB NMEA endpoint 的非 AT 数据路径；该路径不属于 AT 指令，因而不在本表伪装成 AT 命令。

## 10. 模块配置、USB、IMS、VoLTE 与音频 | Module configuration, USB, IMS, VoLTE, and audio

### 10.1 QCFG 配置与恢复 | QCFG configuration and restoration

| 命令 | 用途 | 参数/说明 | 代码位置 |
| --- | --- | --- | --- |
| AT+QCFG="usbcfg" | 读取 USB 配置字段。 | 用于保存修改前快照、能力识别和管理。 | [ModemStore+ModuleConfig.swift](../Sources/EC25Toolbox/Features/ModuleConfig/ModemStore+ModuleConfig.swift) |
| AT+QCFG="usbcfg",&lt;VID&gt;,&lt;PID&gt;,&lt;flag1&gt;,...,&lt;flagN&gt; | 修改 USB 配置、VID/PID 或接口标志。 | 字段数量和接口标志按设备原始响应保留，不在文档中硬编码固件差异。 | [ModemStore+ModuleConfig.swift](../Sources/EC25Toolbox/Features/ModuleConfig/ModemStore+ModuleConfig.swift)、[ModuleConfigModels.swift](../Sources/EC25Toolbox/Features/ModuleConfig/ModuleConfigModels.swift) |
| AT+QCFG="usbnet" | 读取 USB 网络模式。 | 用于配置页面和 Terminal 查询。 | [ModemStore+ModuleConfig.swift](../Sources/EC25Toolbox/Features/ModuleConfig/ModemStore+ModuleConfig.swift) |
| AT+QCFG="usbnet",&lt;mode&gt; | 修改 USB 网络模式。 | 修改后由管理流程决定是否重启并重新发现设备。 | [ModemStore+ModuleConfig.swift](../Sources/EC25Toolbox/Features/ModuleConfig/ModemStore+ModuleConfig.swift)、[ModuleConfigModels.swift](../Sources/EC25Toolbox/Features/ModuleConfig/ModuleConfigModels.swift) |
| AT+QCFG="ims" | 读取 IMS 配置。 | 用于修改前快照和修改后管理。 | [ModemStore+ModuleConfig.swift](../Sources/EC25Toolbox/Features/ModuleConfig/ModemStore+ModuleConfig.swift) |
| AT+QCFG="ims",1 | 启用 IMS。 | 是当前配置动作中的启用形式；实际业务能力仍取决于固件、网络和运营商。 | [ModemStore+ModuleConfig.swift](../Sources/EC25Toolbox/Features/ModuleConfig/ModemStore+ModuleConfig.swift)、[ModuleConfigModels.swift](../Sources/EC25Toolbox/Features/ModuleConfig/ModuleConfigModels.swift) |
| AT+QCFG="ims",&lt;value&gt; | 按原始值恢复 IMS 配置。 | &lt;value&gt; 来自修改前快照。 | [ModuleConfigModels.swift](../Sources/EC25Toolbox/Features/ModuleConfig/ModuleConfigModels.swift) |
| AT+QCFG="volte_disable" | 读取 VoLTE 禁用配置。 | 用于修改前快照。 | [ModemStore+ModuleConfig.swift](../Sources/EC25Toolbox/Features/ModuleConfig/ModemStore+ModuleConfig.swift) |
| AT+QCFG="volte_disable",0 | 解除 VoLTE 禁用。 | 仅表示写入模块配置，不表示已完成运营商 VoLTE 验证。 | [ModemStore+ModuleConfig.swift](../Sources/EC25Toolbox/Features/ModuleConfig/ModemStore+ModuleConfig.swift)、[ModuleConfigModels.swift](../Sources/EC25Toolbox/Features/ModuleConfig/ModuleConfigModels.swift) |
| AT+QCFG="volte_disable",&lt;value&gt; | 按原始值恢复 VoLTE 配置。 | &lt;value&gt; 来自修改前快照。 | [ModuleConfigModels.swift](../Sources/EC25Toolbox/Features/ModuleConfig/ModuleConfigModels.swift) |
| AT+CFUN=1,1 | 在配置修改后重启模块，使部分配置生效。 | 会中断连接；之后需要重新发现、重新连接和重新读取状态。 | [ModemStore+ModuleConfig.swift](../Sources/EC25Toolbox/Features/ModuleConfig/ModemStore+ModuleConfig.swift) |

### 10.2 音频路径 | Audio path

| 命令 | 用途 | 参数/说明 | 代码位置 |
| --- | --- | --- | --- |
| AT+QPCMV=? | 探测模块是否支持 QPCMV 音频配置。 | 能力探测。 | [ModemCapabilities.swift](../Sources/EC25Toolbox/ModemCapabilities.swift) |
| AT+QPCMV? | 读取当前 QPCMV 音频参数。 | 用于能力和配置读取。 | [ModemStore+ModuleConfig.swift](../Sources/EC25Toolbox/Features/ModuleConfig/ModemStore+ModuleConfig.swift) |
| AT+QPCMV=1,2 | 设置标准模块语音运行时的音频参数。 | 每次发起或接听呼叫前由标准音频路径使用；QDC507 路径有独立处理。 | [ModemStore+ModuleVoiceRuntime.swift](../Sources/EC25Toolbox/Features/CallAudio/ModemStore+ModuleVoiceRuntime.swift) |

### 10.3 DJI Cellular 模块管理说明 | DJI Cellular module management

EC25Toolbox 的模块配置能力覆盖 USB 配置读取/修改、USB 网络模式、IMS/VoLTE 相关配置快照，以及修改后的重启、重新发现和状态管理流程。对于 DJI Cellular 模块（TD-LTE 无线数据终端，DJI Cellular module / TD-LTE wireless data terminal），本文中的 AT+QCFG="usbcfg"、AT+QCFG="usbnet"、AT+QCFG="ims"、AT+QCFG="volte_disable" 和 AT+CFUN=1,1 是与“修改及修改后管理”直接相关的命令入口。

这段说明表达的是源码具备相应命令编排和状态管理路径，不替代具体 DJI 固件版本、运营商网络或设备现场验证。

## 11. eSTK/eUICC 与 VoWiFi SIM 访问 | eSTK/eUICC and VoWiFi SIM access

### 11.1 能力探测 | Capability probes

| 命令 | 用途 | 代码位置 |
| --- | --- | --- |
| AT+CCHO=? | 探测逻辑通道打开命令能力。 | [ModemStore+ESTK.swift](../Sources/EC25Toolbox/Features/ESTK/ModemStore+ESTK.swift) |
| AT+CGLA=? | 探测逻辑通道 APDU 命令能力。 | [ModemStore+ESTK.swift](../Sources/EC25Toolbox/Features/ESTK/ModemStore+ESTK.swift) |
| AT+CCHC=? | 探测逻辑通道关闭命令能力。 | [ModemStore+ESTK.swift](../Sources/EC25Toolbox/Features/ESTK/ModemStore+ESTK.swift) |
| AT+CSIM=? | 探测直接 SIM APDU 命令能力；在逻辑通道路径不可用时作为回退。 | [ModemStore+ESTK.swift](../Sources/EC25Toolbox/Features/ESTK/ModemStore+ESTK.swift) |

### 11.2 逻辑通道和 APDU | Logical channel and APDU

| 命令 | 用途 | 参数/说明 | 代码位置 |
| --- | --- | --- | --- |
| AT+CCHO="&lt;AID&gt;" | 打开指定应用标识符的 SIM/eUICC 逻辑通道。 | &lt;AID&gt; 为运行时应用标识符。 | [ModemStore+ESTK.swift](../Sources/EC25Toolbox/Features/ESTK/ModemStore+ESTK.swift)、[VoWiFiSIMAccess.swift](../Sources/EC25Toolbox/Features/VoWiFi/VoWiFiSIMAccess.swift) |
| AT+CCHC=&lt;channel&gt; | 关闭逻辑通道。 | &lt;channel&gt; 为模块返回的通道号。 | [ModemStore+ESTK.swift](../Sources/EC25Toolbox/Features/ESTK/ModemStore+ESTK.swift)、[VoWiFiSIMAccess.swift](../Sources/EC25Toolbox/Features/VoWiFi/VoWiFiSIMAccess.swift) |
| AT+CGLA=&lt;channel&gt;,&lt;length&gt;,"&lt;APDU-hex&gt;" | 通过逻辑通道发送 APDU。 | &lt;length&gt; 与 APDU 长度由运行时计算；APDU 使用十六进制字符串。 | [ModemStore+ESTK.swift](../Sources/EC25Toolbox/Features/ESTK/ModemStore+ESTK.swift)、[VoWiFiSIMAccess.swift](../Sources/EC25Toolbox/Features/VoWiFi/VoWiFiSIMAccess.swift) |
| AT+CSIM=&lt;length&gt;,"&lt;APDU-hex&gt;" | 通过直接 SIM 接口发送 APDU。 | 仅作为 eSTK/逻辑通道不可用时的回退路径。 | [ModemStore+ESTK.swift](../Sources/EC25Toolbox/Features/ESTK/ModemStore+ESTK.swift) |

## 12. QDC507 专用管理 | QDC507-specific management

| 命令 | 用途 | 参数/安全说明 | 代码位置 |
| --- | --- | --- | --- |
| AT+QADBKEY? | 查询 QDC507 ADB key 状态或当前值。 | 查询流程按模块路径处理。 | [ModemStore+ModuleVoiceRuntime.swift](../Sources/EC25Toolbox/Features/CallAudio/ModemStore+ModuleVoiceRuntime.swift) |
| AT+QADBKEY="&lt;derived-response&gt;" | 写入 QDC507 派生的 ADB key 响应。 | &lt;derived-response&gt; 为运行时派生值；使用不记录普通日志的发送路径。 | [ModemStore+ModuleVoiceRuntime.swift](../Sources/EC25Toolbox/Features/CallAudio/ModemStore+ModuleVoiceRuntime.swift) |

## 13. Terminal 与远程命令入口 | Terminal and remote command entry points

### 13.1 内置命令 | Built-in commands

内置命令完整列表见第 3.2 节。TerminalView 使用统一发送入口，不为每个快捷项复制一套传输逻辑。

### 13.2 任意命令与远程转发 | Arbitrary commands and remote forwarding

| 入口 | 行为 | 清单边界 |
| --- | --- | --- |
| Terminal 自定义输入 | 将用户输入的任意 AT 文本发送到当前模块并显示响应。 | 无法静态列出用户未来输入的全部命令；本文只列应用内置命令。 |
| 远程命令转发 | 复用模块命令发送/响应处理，向远程控制层返回结果。 | 远程请求的命令内容属于运行时数据，不硬编码为固定清单。 |

## 14. 最终响应与 URC | Final responses and unsolicited result codes

### 14.1 最终响应 | Final responses

| 响应 | 含义/用途 | 代码位置 |
| --- | --- | --- |
| OK | 命令成功完成或模块确认。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| ERROR | 通用命令错误。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| +CME ERROR: | 扩展设备/移动终端错误。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| +CMS ERROR: | 短信相关错误。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |

### 14.2 呼叫与短信 URC | Call and SMS URCs

| URC | 用途/含义 | 代码位置 |
| --- | --- | --- |
| RING | 来电振铃提示。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift)、[ModemEvent.swift](../Sources/EC25Toolbox/ModemEvent.swift) |
| +CLIP: | 来电号码显示。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift)、[ModemEvent.swift](../Sources/EC25Toolbox/ModemEvent.swift) |
| +CLCC: | 当前呼叫列表/状态变化。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift)、[ModemEvent.swift](../Sources/EC25Toolbox/ModemEvent.swift) |
| +CCWA: | 呼叫等待提示。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift)、[ModemEvent.swift](../Sources/EC25Toolbox/ModemEvent.swift) |
| NO CARRIER | 呼叫或数据连接断开。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift)、[ModemEvent.swift](../Sources/EC25Toolbox/ModemEvent.swift) |
| BUSY | 对端忙。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift)、[ModemEvent.swift](../Sources/EC25Toolbox/ModemEvent.swift) |
| NO ANSWER | 呼叫无应答。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift)、[ModemEvent.swift](../Sources/EC25Toolbox/ModemEvent.swift) |
| DELAYED | 呼叫请求被延迟。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| BLACKLISTED | 呼叫号码或请求被列入黑名单。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| +CMTI: | 新短信到达并给出存储索引。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift)、[ModemEvent.swift](../Sources/EC25Toolbox/ModemEvent.swift) |
| +CMT: | 直接上报短信内容。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| +CDS: | 短信状态报告。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| +CBM: | 小区广播短信。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |

### 14.3 SIM、网络与模块生命周期 URC | SIM, network, and lifecycle URCs

| URC | 用途/含义 | 代码位置 |
| --- | --- | --- |
| +SIM: | SIM 状态变化。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift)、[ModemEvent.swift](../Sources/EC25Toolbox/ModemEvent.swift) |
| +QSIMSTAT: | Quectel SIM 状态变化。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift)、[ModemEvent.swift](../Sources/EC25Toolbox/ModemEvent.swift) |
| +QSIMDET: | Quectel SIM 检测事件。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift)、[ModemEvent.swift](../Sources/EC25Toolbox/ModemEvent.swift) |
| +CREG: | 电路域网络注册异步通知。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| +CGREG: | 分组域网络注册异步通知。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| +CEREG: | EPS/LTE 网络注册异步通知。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| +CTZV: | 时区变化通知。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| +CTZE: | 时区事件通知。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| +CTZR: | 时区报告通知。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| +CIEV: | 通用模块状态/指标事件。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift)、[ModemEvent.swift](../Sources/EC25Toolbox/ModemEvent.swift) |
| +CSCON: | 分组数据连接状态变化。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| +QIND: | Quectel 指示事件。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| +CFUN: | 功能状态变化通知。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| ^MODE: | 模块模式变化。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| ^RESET: | 模块复位通知。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift)、[ModemEvent.swift](../Sources/EC25Toolbox/ModemEvent.swift) |
| ^DSD: | 数据服务域状态变化。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| ^BOOT: | 模块启动阶段通知。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| ^DOWNLOAD: | 模块下载/升级模式通知。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| RDY | 模块准备就绪。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift)、[ModemEvent.swift](../Sources/EC25Toolbox/ModemEvent.swift) |
| SMS READY | SMS 子系统准备就绪。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift)、[ModemEvent.swift](../Sources/EC25Toolbox/ModemEvent.swift) |
| CALL READY | 呼叫子系统准备就绪。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift)、[ModemEvent.swift](../Sources/EC25Toolbox/ModemEvent.swift) |
| POWERED DOWN | 模块已关机或下电。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift)、[ModemEvent.swift](../Sources/EC25Toolbox/ModemEvent.swift) |

### 14.4 解析器识别但未单独映射业务事件的 URC | Parser-recognized URCs without a dedicated business event

| URC | 说明 | 代码位置 |
| --- | --- | --- |
| +COLP: | 连接号码/远端号码提示；由通用行分类器识别。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| +CCVM: | 语音信箱相关提示；由通用行分类器识别。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| +CCWE: | 呼叫/网络相关扩展提示；由通用行分类器识别。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |
| +CSSI: | 补充业务信号；由通用行分类器识别。 | [ATLineClassifier.swift](../Sources/EC25Toolbox/AT/ATLineClassifier.swift) |

## 15. 测试专用或合成命令样例 | Test-only and synthetic command examples

以下内容出现在测试夹具或协议测试中，用于验证命令收集、脱敏、行分类或终端入口，不应当直接当作生产功能列表。

| 命令/样例 | 测试用途 | 说明 |
| --- | --- | --- |
| AT+CMD3 | 命令收集/顺序测试。 | 合成命令，不对应已知模块功能。 |
| AT+CMD7 | 命令收集/顺序测试。 | 合成命令，不对应已知模块功能。 |
| AT+CMD&lt;index&gt; | 参数化命令收集测试。 | &lt;index&gt; 为测试占位符。 |
| AT+TESTTERMINAL | Terminal 命令入口测试。 | 合成命令，不是内置快捷功能。 |
| AT+QGPSLOC=0 | AT 行分类/错误或回退测试样例。 | 不代表 GNSS 业务路径使用该固定参数。 |
| ATD*99#; | 命令脱敏/敏感数据处理测试样例。 | 不代表应用已实现该拨号数据业务。 |
| AT+CMGS=17 | 命令收集器测试中的短信发送占位。 | 测试协议交互，不替代实际 AT+CMGS 文本发送流程。 |
| AT+CMGS="&lt;test value&gt;" | 短信命令脱敏测试。 | &lt;test value&gt; 为测试占位符。 |

## 16. 维护与核对方法 | Maintenance and verification

当源码新增、删除或修改 AT 命令时，应同步检查以下位置：

| 核对项 | 目的 |
| --- | --- |
| Sources/EC25Toolbox/ 中的 ModemStore 扩展 | 确认业务流程主动发送的命令和参数形态。 |
| Sources/EC25Toolbox/AT/ATLineClassifier.swift | 确认最终响应和 URC 分类是否变化。 |
| Sources/EC25Toolbox/ModemEvent.swift | 确认 URC 是否新增业务事件映射。 |
| Sources/EC25Toolbox/Views/Terminal/TerminalView.swift | 确认内置 Terminal 快捷命令是否变化。 |
| Tests/ 中的命令契约和协议夹具 | 区分真实业务命令与测试合成命令。 |
| 模块配置模型和恢复流程 | 确认配置修改、原始值保存、重启、重新发现和修改后管理是否同步。 |

本文件不承诺任何未在当前源码或测试中出现的 Quectel、DJI Cellular、运营商专用或供应商私有 AT 指令；如需扩展，必须以对应模块固件手册、实际源码调用和验证证据为依据。
