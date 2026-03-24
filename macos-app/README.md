# Poke PC macOS App

Native SwiftUI wrapper for Poke PC with app-first onboarding, menubar controls, runtime status management, and one-shot DMG packaging.

## Implemented

- Native onboarding for non-technical users
- Credentials flow based on existing JSON path: `~/.config/poke/credentials.json`
- Native browser device login with automatic polling and credentials save
- Copy-login-link fallback for manual approval flows
- Runtime orchestration with backend detection:
	- Apple `container` CLI required
- Runtime health monitoring (`/health`) with degraded-state handling
- Dashboard with:
	- Status panel
	- Live app log feed
	- Settings panel
- Menubar icon + status + controls:
	- Start/Stop runtime
	- Refresh credentials
	- Open dashboard
- Packaging scripts for `.app` and `.dmg`

## Development Build

```bash
cd macos-app
swift build
swift run
```

## Release Build (.app + .dmg)

```bash
cd macos-app
./scripts/release.sh
```

Artifacts:

- `build/Poke PC.app`
- `build/Poke-PC.dmg`

## Script Details

- `scripts/build-macos-app.sh`: builds release binary and creates `.app` bundle
- `scripts/build-dmg.sh`: packages `.app` into DMG
- `scripts/release.sh`: runs both scripts end-to-end

## Runtime Notes

- The app mirrors credentials into app runtime state for container use.
- No keychain integration is used; credentials remain in JSON style consistent with existing Poke PC behavior.
- If Apple container CLI commands differ on your host version, runtime startup may need command flag adjustments in `Sources/ContainerizationRuntimeService.swift`.
