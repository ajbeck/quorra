---
title: "Quorra"
# All landing-page copy lives here so it can be edited without touching a
# template. The home layout renders these sections in order.
hero:
  eyebrow: "A NATIVE MAC APP FOR AWS IAM IDENTITY CENTER"
  heading: "Your Mac, with an instance profile."
  lead: "Sign in once and Quorra serves that role at the standard EC2 metadata address. The AWS CLI, the SDKs and Terraform pick it up through the ordinary provider chain — the same way they would on an instance."
  note: "macOS 26.4+ · Apple silicon\nApache-2.0 · no account needed"

path:
  label: "DWG. 01 — CREDENTIAL PATH"
  caption: "Every hop between your tools and a temporary role, and what each one is allowed to touch."
  prelude: "AWS IAM Identity Center · device authorization, once per session"
  steps:
    - group: "YOUR TOOLS"
      title: "AWS CLI · SDKs · Terraform"
      detail: "unmodified provider chain"
      notes:
        - "GET /latest/meta-data/…"
        - "no AWS_PROFILE, no endpoint override"
    - group: "MACOS"
      title: "Network Extension"
      detail: "169.254.169.254:80 only"
      notes:
        - "forwards opaque TCP bytes"
        - "never interprets, stores or logs them"
    - group: "QUORRA (SANDBOXED)"
      title: "Local IMDSv2 server"
      detail: "127.0.0.1:7114"
      highlight: true
      notes:
        - "mints IMDSv1 + IMDSv2 responses for the served profile"
        - "binds 127.0.0.1 only · never reachable from your network"
    - group: "MACOS KEYCHAIN"
      title: "Session token"
      detail: "+ role credentials"
      # The arrow before this step points back into Quorra: the keychain is
      # read from, not forwarded to.
      inbound: true
      notes:
        - "read on demand, never copied into app files"

boundaries:
  heading: "What crosses which boundary"
  lead: "Quorra asks macOS for two approvals and one folder. Nothing else. If you would rather it never touched your AWS files, turn export off and it never writes to them."
  columns: ["SURFACE", "WHAT QUORRA USES IT FOR", "SCOPE"]
  rows:
    - surface: "Your AWS folder"
      use: "Imports sessions and profiles once; writes them back only if you enable export."
      scope: "one folder you pick"
    - surface: "Network Extension"
      use: "Forwards outbound TCP for the metadata address to Quorra's local backend."
      scope: "169.254.169.254:80"
    - surface: "macOS Keychain"
      use: "Stores IAM Identity Center tokens and temporary role credentials."
      scope: "never in app files"
    - surface: "Local endpoints"
      use: "Serve a chosen profile to tools that take a custom metadata URL."
      scope: "127.0.0.1 only"
    - surface: "The app itself"
      use: "Runs in the macOS sandbox for the whole of its life."
      scope: "sandboxed"

app:
  heading: "Then it gets out of the way"
  lead: "Sessions, profiles and endpoints in one three-column window. Sign in, watch the clock on every profile, copy the exact export snippet for your shell, and switch which profile the endpoint serves — from the window, the menu bar or the CLI."
  figures:
    - image: "images/app-credentials.png"
      label: "FIG. 1"
      alt: "Quorra showing a profile's temporary credentials, the time until they expire, and the masked export snippet with a bash, zsh, fish and powershell picker"
      caption: "The Credentials card counts down to expiry and shows the exact snippet Copy env will put on the clipboard, with the secrets masked until you copy them."
    - image: "images/app-endpoint.png"
      label: "FIG. 2"
      alt: "A running Quorra IMDS endpoint on 127.0.0.1:9678 serving a profile, with its URL, export and curl snippets and its port, bind address, IMDS version and hop limit"
      caption: "Each endpoint shows its state, uptime, requests served and the IMDS versions it answers."
  features:
    - label: "SIGN IN"
      body: "Native device authorization, the session refreshed for you, expiry always on screen."
    - label: "COPY ENV"
      body: "The exact snippet for bash, zsh, fish or PowerShell, shown before you copy it."
    - label: "ENDPOINTS"
      body: "Extra listeners on 127.0.0.1 with their own port, IMDS version and hop limit."
    - label: "YOUR AWS FOLDER"
      body: "Imported once, exported back on your say-so, other sections and comments kept."

download:
  heading: "Get Quorra"
  lead: "Download the disk image, move it to Applications, and point it at your AWS folder. macOS asks you to approve the system extension the first time you enable the default endpoint; after that it stays approved."
---
