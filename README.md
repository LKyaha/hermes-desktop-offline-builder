# hermes-desktop-offline-builder

Automated Windows x64 offline builder for [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent).

## Goal

Produce a reproducible Windows x64 **full offline** installer for Hermes Desktop while keeping upstream Hermes source unmodified or minimally patched.

The intended final flow is:

1. Periodically detect a new upstream Hermes release.
2. Build the official Hermes Desktop application on a GitHub-hosted Windows runner.
3. Prepare an offline runtime payload (Hermes source/runtime, Python, uv, Node.js, MinGit, browser dependencies/Chromium, and required tools).
4. Reuse the upstream bootstrap installer/stage flow with a bundled offline install script.
5. Validate that installation succeeds without network access.
6. Publish the verified Windows x64 installer and SHA256 to this repository's Releases.

## Current status

The first CI stage is now enabled: `.github/workflows/windows-smoke.yml` automatically resolves the latest upstream release, builds the official Windows NSIS Desktop package, and uploads it as a short-lived Actions artifact.

This smoke artifact is **not yet the final offline installer**. It is deliberately kept separate from Releases until the bundled offline payload and no-network validation are implemented and passing.

## Automation

- Runs automatically after changes to `main`.
- Checks upstream on a 6-hour schedule.
- Can also be manually pointed at a specific upstream tag/branch/commit for debugging.

## Upstream

Hermes Agent is developed by Nous Research and is licensed under the MIT License. This builder is an independent packaging/automation project and is not an official Nous Research distribution.
