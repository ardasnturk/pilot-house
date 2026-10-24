# Roadmap

Ideas for after 1.0, roughly in order of value. None of them is promised;
contributions are welcome (see [CONTRIBUTING.md](../CONTRIBUTING.md)).

## Next

* **Approve from the notification.** Pilothouse notifies through ntfy and macOS
  (D-095); approving right from the notification still needs Pilothouse's own
  push (an optional, self-hostable relay that only sees an opaque,
  end-to-end-encrypted wake-up).
* **Live Activities / Dynamic Island** showing the running turn and pending
  approvals.
* **`auto` and `dontAsk` permission modes** once their behaviour in headless
  mode is documented by Claude Code (D-006).
* **Plan mode review**: render a proposed plan as a checklist with
  approve / revise buttons.
* **Image and file attachments from the Files app** (photos already work).

## Later

* **Multiple Macs in one list** (sessions of all paired Macs side by side,
  today one Mac is active at a time — D-051).
* **Apple Watch** companion for approvals.
* **Shortcuts / App Intents**: "Ask Claude on my Mac to …".
* **Session search** across transcripts on the Mac.
* **Git view**: branch, status and a commit button for the session folder.
* **Mac App Store edition** of the Mac app — blocked by the sandbox: the app
  must start the user's own `claude` binary with the user's environment
  (D-080).
* **More languages** — the String Catalogs are generated from
  `scripts/l10n/*.py`; adding a language is a pull request away.

## Not planned

* Talking to Anthropic's API directly or handling Claude account credentials —
  Pilothouse only drives the official CLI (the optional API key is passed to
  the CLI and never used by Pilothouse itself).
* Accounts, cloud sync or analytics.
