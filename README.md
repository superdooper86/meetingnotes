<div align="center">
  <!-- REMOVE THIS IF YOU DON'T HAVE A LOGO -->
    <img src="https://github.com/user-attachments/assets/309577e8-94db-431f-b8df-a53a763b4c87" alt="Logo" width="80" height="80">

<h3 align="center">Meetingnotes</h3>

  <p align="center">
    The Free, Open-Source AI Notetaker for Busy Engineers
  </p>
</div>

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

## Releasing a New Version

Production releases are Developer ID signed, notarized by Apple, published to
GitHub Releases, and signed for Sparkle auto-updates.

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
