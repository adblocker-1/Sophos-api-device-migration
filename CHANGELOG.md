# Changelog

## 2.0

### New: graphical user interface (`Sophos-DeviceMigration-GUI.ps1`)

- Modern WPF wizard in four steps: **Sign-in → Tenants → Devices → Migration**,
  with a step list in the sidebar.
- **Sign-in** with tenant API keys (source and target tenant) or with a
  partner/organization API key. The tool checks the key type, rejects identical
  tenants and verifies that both tenants are in the same data region.
- **Tenant selection** (partner sign-in) in two searchable lists, with a live
  warning when both entries are the same tenant or the regions differ.
- **Device list** with a Servers/Clients switch, search (hostname, OS, user),
  checkboxes, *Select all* / *Clear selection*, sorting, color-coded health,
  and ticking several highlighted rows at once with the Space key.
- **Migration** with a summary, confirmation prompt, live status per device
  (color-coded badges), counters (succeeded / failed / pending), progress bar,
  log, manual status check and **CSV export** of the result.
- All API calls run in the background, so the window stays responsive.
- Access tokens are renewed automatically during long sessions.
- Clear error messages that include the error text from the Sophos API.
- `Start-GUI.cmd` starts the GUI with a double-click, without a console window.

### Changed

- Both scripts and all documentation are now in **English**.
- The README has screenshots and step-by-step instructions.
- The console script keeps the same features as before.

## 1.0

- Interactive console script that migrates servers or clients between Sophos
  Central tenants: tenant API keys or partner sign-in, device selection with
  Out-GridView, status polling per device.
