# Security & privacy policy

MindfulHours observes everything on your screen, so bugs that leak window content, screenshots, titles or URLs — to disk, to logs, or to a model provider — are treated as security vulnerabilities.

## Reporting a vulnerability

Please **do not open a public issue**. Report privately through [GitHub private vulnerability reporting](https://github.com/VikalpP/MindfulHours/security/advisories/new). Include steps to reproduce and the version or commit you tested.

You can expect an acknowledgement within a few days. Fixes ship in the next release, and reporters are credited in the release notes unless they prefer otherwise.

## Supported versions

Only the latest release receives fixes.

## In scope

- Screenshots or on-screen text reaching a model despite a privacy protection (excluded app, sensitive URL/title, password field, capture-protected window, private window, sensitive text)
- Screenshots or window content written to disk or logs
- Data reaching any host other than the configured model endpoint
- Prompt injection from on-screen content that causes harmful behavior in the app
