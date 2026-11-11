# Prototype verification

Completed 11 November 2026. This validates the portable browser package only.

## Result

The click-through passes 66 automated browser journey/layout checks in Chrome on macOS. The same 66 checks pass after copying the complete directory outside the repository and opening `app.html` directly with `file://`, with the browser context offline. No external requests, page errors, console errors or persistent browser-storage entries were observed.

- [Original-package browser receipt](browser-checks.json)
- [Independent-copy browser receipt](portable-browser-checks.json)
- [Documentation browser receipt: 21 checks](document-browser-checks.json)
- [Documentation and package checks](package-checks.json)
- [Source provenance and original-byte checksums](sources/provenance.json)
- [Implementation and failure journal](session-log.html)

## Exercised journeys

- Live transcript selection maps to the same screenshot/time; Screenshot/Text switch; keyboard resize divider.
- Automatic older-page loading crosses days; Reset restores top and Following live.
- Mark now anchors demo now even when an older row is selected; edit title/note; add and pin a context range; review its linked recordings; delete/Undo; marker badges update.
- Speaker correction, copy-context preview and Escape dismissal.
- Search after a conflicting Timeline application filter opens the correct source and filmstrip identity.
- Timeline tags, inert text comments, audio panel and date jump.
- Dictation flow, App Usage grid/session links, Screenshots/OCR.
- All nine Settings sections; empty phrase validation, disabled new rule, phrase demonstration, companion state shared with Live, Audio history deep link.
- MCP sample token reveal, client creation/revoke, retention preview/confirmation.
- System Monitor Process now/cancel and baseline restart.
- Desktop (1440×1050), tablet (820×1180), phone (390×844). No horizontal page overflow on the main views. Compact Screen hides the transcript pane.
- No localStorage/sessionStorage changes or network use.

Additional documentation checks cover the 50-entry journal's search/subsystem/status filters and clear action, specification navigation, all local file references and fragments, source provenance and absence of symlinks. The application main anchor is created by JavaScript and checked in the running page. Documentation/source text never executes historical commands.

## Visual receipts

- [Live desktop](../output/playwright/live-desktop.png)
- [Live phone](../output/playwright/live-mobile.png)
- [Live tablet](../output/playwright/live-tablet.png)
- [System Monitor](../output/playwright/monitor-desktop.png)
- [Package directory](../output/playwright/directory.png)
- [Issues journal](../output/playwright/issues-journal.png)

## Review and limits

One review pass covered JavaScript functionality, HTML/CSS, accessibility and package/documentation boundaries. Marker state, reset scrolling, recording-scoped speakers, filtered navigation and primary-button contrast were corrected and checked. Source documentation states its historical scope and preserves disputed authorisation rather than asserting it as settled fact.

This is sample UI acceptance, not native Retrace acceptance. No recordings were made or played, no models were run, no real timings or CPU readings were measured, and no client token or companion connection was created. Browser clipboard permission can vary for local files; explicit-copy actions offer a manual fallback. Source histories, support-file counts and tests are not proof of complete real-world history or speech accuracy. Safari and Firefox have not been separately exercised.

All app state resets on reload or Reset demo. Runtime requirements are a modern browser with JavaScript; no server, package manager, installation or parent-project files. The entire directory is the deliverable.
