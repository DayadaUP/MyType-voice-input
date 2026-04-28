# MyType macOS App

This directory contains the current macOS application implementation for MyType.

## Overview

The app currently focuses on practical desktop voice input with:

- shortcut-driven recording
- local, cloud, and hybrid recognition modes
- live preview before final insertion
- personal lexicon learning and filler-word filtering
- history, usage stats, and local model management

## Run Locally

```bash
cd apps/mac-ime
swift build
swift run MyTypeIMEDemo
```

## Basic Usage

1. Keep MyType running.
2. Put the cursor in an editable text field.
3. Press the configured shortcut and start speaking.
4. When recording ends, MyType transcribes the speech and inserts text into the focused input area.

## Permissions

The app usually requires:

- Microphone permission for recording
- Accessibility permission for inserting text into other apps

## Recognition Modes

- Local mode runs on-device. Responsiveness depends on Mac performance, current system load, and selected model size.
- Cloud mode requires the user to configure their own API credentials.
- The current cloud path has mainly been validated against Doubao-style streaming speech endpoints.

## Packaging

```bash
cd apps/mac-ime
bash Scripts/package_demo_app.sh
```

Artifacts are written to `dist/`.
