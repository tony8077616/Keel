# Keel

Shared helper modules for [Slipway](https://github.com/tony8077616/Slipway), which refreshes Windows 10/11 ISOs from UUP packages.
Runtime: **Windows PowerShell 5.1** (`powershell.exe`). PowerShell 7 Preview cannot create DISM image sessions (`0x80040154`).

| Path | Purpose |
|------|---------|
| `Common/WinMediaProcess.psm1` | `Invoke-WinMediaExternal`, with optional `-StandardInputPath` |
| `Common/WinMediaOperation.psm1`, `Common/WinMediaLog.psm1` | Operation and log wrappers |
| `Common/WinMediaDownload.psm1`, `Common/PathSanitize.psm1` | Download and log-safe path helpers |
| `Imaging/WinMediaWimlib.psm1` | Finds or downloads `wimlib-imagex` (SHA-256 checked) and runs it |
| `Imaging/WinMediaEsd.psm1`, `Imaging/WinMediaDism.psm1`, `Imaging/WinMediaImage.psm1` | ESD/WIM conversion and DISM session helpers |
| `Imaging/WinMediaAdk.psm1`, `Imaging/WinMediaVirtualEdition.psm1` | ADK discovery and virtual editions |

`wimlib-imagex` is not shipped here. Resolution order: `Config.Wimlib.Path`, then `%LOCALAPPDATA%\WinMediaRefresh\tools\wimlib-1.14.5\`, then download `wimlib-1.14.5-windows-x86_64-bin.zip` and verify its SHA-256. A mismatch stops the run.

License: MIT. See [LICENSE](LICENSE).
