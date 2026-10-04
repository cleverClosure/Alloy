<!-- Author: Timur Isaev -->

# Public repository protections

Task #157 configures features available without a paid subscription on Alloy's
public repository. CodeQL uses standard GitHub-hosted Ubuntu and macOS runners.

## Repository settings

- Secret scanning alerts and repository push protection are enabled.
- Dependabot alerts and security updates are enabled. Weekly grouped version
  updates in `dependabot.yml` maintain GitHub Actions references, including SHA
  pins. The runtime forks remain managed by their dedicated inventory tooling.
- The main branch ruleset requires pull requests, passing `Lint and test` and
  all four `CodeQL (...)` checks plus the `CodeQL` findings check, and disallows
  force pushes and deletion.
  It requires no human approvals. There are no bypass actors.
- The existing automatic squash merge still checks Estimate and Actual before
  merging. It reevaluates after either CI or CodeQL completes, so the slower
  workflow cannot leave an otherwise ready pull request stranded.
- Private vulnerability reporting and Pages remain disabled at the founder's
  request. Native auto-merge and paid Copilot features are not enabled.

## Scan coverage

`codeql.yml` scans pull requests, main pushes, and a weekly schedule. Actions,
Python, and C/C++ use build mode `none`; Swift builds the library and executable
targets of every tracked first-party package in a fresh scratch directory.
Swift test targets are outside this scan; normal CI builds and executes them.

The configuration includes `.github`, `runtime`, `spikes`, `tools`, and
`scripts`. It excludes third-party sources, downloaded toolchains, scratch
work directories, package build output, and node modules. Checkouts do not
fetch submodules or runtime sources. For Swift, the explicit build selection
enforces that boundary because path filters do not limit manual extraction.

C/C++ analysis without a build can miss platform-specific details, and CodeQL
does not provide full coverage for Objective-C, Metal shaders, assembly, or
shell scripts. This complements the existing compiler, lint, and test checks;
it does not replace them or certify the external Wine/FEX/DXMT forks.

Standard Copilot Autofix suggestions for supported code-scanning alerts are
free on public repositories and require no Copilot subscription. They are
reviewed changes, never automatically applied. Copilot cloud-agent sessions
and agentic autofix are separate paid features and are outside this setup.

## Operations

CodeQL job success means extraction, analysis, and upload completed. The
separate required `CodeQL` findings check enforces GitHub's pull-request alert
threshold. Review remaining findings in the Security and quality tab;
an analysis job succeeding is not a claim that no vulnerabilities exist.

The branch ruleset is recorded in `main-ruleset.json` and applied through
GitHub's repository settings/API. Verify
its required check names after renaming jobs. Keep the source of required
analysis checks bound to the GitHub Actions app and the findings check to the
GitHub Code Scanning app. A new required check must run on the
pull request before adding it to the ruleset.

Dependabot does not maintain our custom fork inventory or reproduce the
corresponding-source release bundle. Its dependency alerts also do not cover
every manually downloaded binary or SHA-pinned Action advisory. Version
updates keep those Action pins current while existing CI checks the changes.
