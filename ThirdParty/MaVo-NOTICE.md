# MaVo optional QDC507 voice runtime notice

EC25 Toolbox can, only after explicit user confirmation, download three
optional runtime files directly from the MaVo repository at the immutable
commit below. These files are not copied into this repository or bundled in
the EC25 Toolbox application.

- Upstream: <https://github.com/moluncn/mavo>
- Pinned commit: `0443dfdaf8aec086fd76ba2ee9152fd908114524`
- Pinned directory: <https://github.com/moluncn/mavo/tree/0443dfdaf8aec086fd76ba2ee9152fd908114524/Resources/ModuleVoice>
- Runtime version: `qdc507-3.18.44-voice-20260712.5`

## Files and integrity

| File | Bytes | SHA-256 | Upstream licensing statement |
| --- | ---: | --- | --- |
| `qdc507_aprv3.ko` | 36,664 | `3d82d3dec4f1e323201bba87156df9d41438e08314097353f2607f9117211d4a` | GPL-2.0 kernel module |
| `qdc507_voice.ko` | 999,236 | `ed3821682d5309969a01c764192c83feff9669c61ef237c69475cd1619cf296c` | GPL-2.0 kernel module |
| `mavo-pcm-bridge.armv7` | 17,860 | `88d47c15e61d1428a59c821fed804c2e6490e82859a085062f21966b58d167fc` | MaVo MIT-licensed user-space component |

EC25 Toolbox also downloads and verifies MaVo's `manifest.json`,
`COPYING-GPL-2.0`, and `MODULE-REPORT.md` from the same commit. The files are
kept under the current user's Application Support directory and the three
runtime files are copied only to the connected module's temporary filesystem.
The application neither flashes them nor persists them to the module's boot,
MTD, DIAG, or EDL storage.

MaVo is MIT licensed; its license text is preserved in
[`MaVo-MIT-LICENSE`](MaVo-MIT-LICENSE). MaVo's upstream third-party notice says
the two loadable Linux kernel modules are derived from
`the-modem-distro/quectel_eg25_kernel` commit
`82ed00908b3e8efc3ff0de27d2b5a7c0524ecd7f` under GPL-2.0:
<https://github.com/the-modem-distro/quectel_eg25_kernel>.

The reviewed MaVo commit contains the binaries and GPL-2.0 license text, but
its `MODULE-REPORT.md` describes an older `qdc507_afe.ko` artifact and different
sizes and hashes. It therefore must not be treated as a matching reproducible
build record for the pinned `qdc507_voice.ko` runtime. The EC25 Toolbox manifest
uses the actual pinned files as its integrity identity; SHA-256 verification
does not prove source correspondence, license compliance, kernel ABI safety,
or device compatibility.

Anyone who redistributes the kernel-module binaries, including by adding them
to an application package or mirror, is responsible for independently meeting
the GPL-2.0 corresponding-source and notice obligations. EC25 Toolbox's
direct-download design is not a substitute for those obligations and this
notice is not legal advice.

EC25 Toolbox's native USB ADB client, deployment checks, lifecycle handling,
and macOS audio bridge are independently implemented. No DJOneHub source is
copied. MaVo and its contributors do not endorse EC25 Toolbox and provide the
upstream software without warranty.
