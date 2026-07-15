<div align="center">
  <!-- REMOVE THIS IF YOU DON'T HAVE A LOGO -->
    <img src="https://github.com/user-attachments/assets/309577e8-94db-431f-b8df-a53a763b4c87" alt="Logo" width="80" height="80">

<h3 align="center">Meetingnotes</h3>

  <p align="center">
    The Free, Open-Source AI Notetaker for Busy Engineers
    <br />
     <a href="https://github.com/owengretzinger/meetingnotes/releases/latest/download/Meetingnotes.dmg">Download for MacOS 14+</a>
  </p>
</div>

## Recall.ai - Meeting Transcription API

Meetingnotes runs locally, capturing two streams: system & mic.

If you’re looking for a transcription API for meetings, consider checking out [Recall.ai](
https://www.recall.ai?utm_source=github&utm_medium=sponsorship&utm_campaign=owengretzinger+meetingnotes), an API that works with Zoom, Google Meet, Microsoft Teams, and more. Recall.ai diarizes by pulling the speaker data and separate audio streams from the meeting platforms, which means 100% accurate speaker diarization with actual speaker names.

## Demo

https://github.com/user-attachments/assets/cadd4504-e9d9-4ccd-874d-41d8a84f4c9d

<!--
## Table of Contents

<details>
  <summary>Table of Contents</summary>
  <ol>
    <li>
      <a href="#about-the-project">About The Project</a>
      <ul>
        <li><a href="#key-features">Key Features</a></li>
      </ul>
    </li>
    <li><a href="#architecture">Architecture</a></li>
    <li>
      <a href="#getting-started">Getting Started</a>
      <ul>
        <li><a href="#prerequisites">Prerequisites</a></li>
        <li><a href="#installation">Installation</a></li>
      </ul>
    </li>
    <li><a href="#acknowledgments">Acknowledgments</a></li>
  </ol>
</details>

## About The Project

Brief description of the project.

### Key Features

- **Feature 1:** ...
- **Feature 2:** ...
- ...

## Architecture

![Architecture Diagram](https://github.com/user-attachments/assets/75adc7aa-7719-4c4f-a9bb-3ba847e12e9f)

(Insert the different technologies used in the project here — could split this into frontend, backend, etc)

(Don't explain what well-known technologies like React are)

## Getting Started

### Prerequisites

- Requirement 1
- Requirement 2
  ```sh
  installation command (if applicable)
  ```

### Installation

Instructions for cloning the repo, installing packages, configuring environment variables, etc:

1. Step 1
   ```sh
   command
   ```
2. Step 2
   ```sh
   command
   ```
3. ...

## Acknowledgments

- This README was created using [gitreadme.dev](https://gitreadme.dev) — an AI tool that looks at your entire codebase to instantly generate high-quality README files.
- (Only include unique things that you are sure should be specifically acknowledged. Don't include libraries or tools like React, Next.js, etc. Don't include services like Vercel, OpenAI, Google Cloud, JetBrains, etc. Stay on the safe side since more can be added later. Do not hallucinate.)

-->

## Features

Implemented:

- Recording mic & system audio
- End-of-meeting transcription through your Coder service
- Ability to also write down additional notes
- AI generated enhanced notes
- Copy functionality
- Meeting deletion functionality
- Meeting search functionality
- Abilty to edit system prompt
- Select any compatible Coder model for transcription and note generation
- Automatic start and stop from MuteDeck through a compatible local API
- Auto updates
- Text formatting
- Different note templates
- Integrate with Posthog for anonymous analytics (installs, opens, meetings created)
- Onboarding screen to enable settings and set API key

Todo:

- improve provider balance and token validation errors
- add padding to text inputs
- add confirmation when clicking the copy button

Later:

- Cool recording indicator (dancing bars)
- Connecting to your Google calendar
- AI chat for asking questions about a meeting
- Integrations for email, Slack, Notion, etc.

## Local Development

Open the project in Xcode. Command+R to build it and run it.

## Releasing a New Version

Production releases are Developer ID signed, notarized by Apple, published to
GitHub Releases, and signed for Sparkle auto-updates.

### Prerequisites

- Apple Developer Program membership
- A Developer ID Application certificate exported from Keychain Access as a
  password-protected `.p12`
- An Apple ID app-specific password for notarization
- GitHub CLI: `brew install gh`

Configure the Apple release secrets once:

```bash
./scripts/configure_github_release_secrets.sh
```

The Sparkle private key is stored only as the `SPARKLE_PRIVATE_KEY` Actions
secret. Its matching public key is committed in `meetingnotes/Info.plist`.

### Release Process

1. **Update the version number:**

   ```bash
   # For bug fixes (1.0 → 1.0.1):
   ./scripts/update_version.sh patch

   # For new features (1.0 → 1.1):
   ./scripts/update_version.sh minor

   # For major changes (1.0 → 2.0):
   ./scripts/update_version.sh major

   # For custom version:
   ./scripts/update_version.sh custom 1.2.0
   ```

2. Commit and push the version change to `main`.

3. Run the `Release` workflow from GitHub Actions and enter the version without
   the `v` prefix. The workflow signs and notarizes the app, generates the
   signed appcast, creates the version tag, and publishes both release assets.

The app checks
`https://github.com/superdooper86/meetingnotes/releases/latest/download/appcast.xml`
and installs later releases automatically through Sparkle.

### Recovering Meetings

The first Developer ID signed build may not automatically inherit data from an
older ad-hoc signed build. In Settings, use **Import Meetings...** and select the
old `Meetings` folder. After this one-time transition, the stable signing
identity keeps the same sandbox container across updates.
