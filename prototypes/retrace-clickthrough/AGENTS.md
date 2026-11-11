# Standalone Retrace click-through

This directory is an independent demonstration and documentation package. Keep all runtime files and links inside this directory, use relative paths, and require no build, server, package installation or network. Sample data only; never connect to the live Retrace library. State stays in memory and resets on reload. No native app changes belong here.

`index.html` is the package directory. `app.html` loads `assets/app.css`, `assets/app.js`, and the settings/monitor files. `docs/` holds the full specification, chronological issues journal, provenance snapshots, validation and session log. `bundle-manifest.json` records hashes. `output/playwright/` contains review screenshots.

Validate navigation, keyboard/dialog handling, cross-view identities and layout. Copy the entire directory outside the project and test the copy directly using `file://` with networking disabled. Native recording, audio recognition, MCP, destructive operations, companion access and measurements must remain clearly simulated. Source verification, installation and acceptance are separate states.
