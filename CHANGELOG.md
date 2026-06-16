## [0.148.0] - 2026-06-16

- feat(install): serve install.sh, samples, and binaries from GitHub Pages
- fix(changelog): derive commit range from the previous tag, not the new one
- ci(release): glob checksum inputs so the build matrix can't drift
- test(install): isolate bats from install.sh shell options; drop dead jq stub
- fix: tag exact merged commit, decouple changelog from tagging
- add bats tests, release checksums, changelog automation
- add auto-tag workflow — creates patch tag on every merge to main
- remove releases folder — binaries now in GitHub Releases, config in samples/
- fix: use gitleaks Docker image directly — no license required
- sync: gitleaks fix, install.sh improvements, lint pipeline, samples
- ci: drop Helm tooling; align gitleaks with usezombie practice
- ci: run gitleaks via CLI instead of licensed action
- ci: add lint pipeline (shellcheck, lint-go, helm lint/validate)
- fix: opt into Node.js 24 for GitHub Actions before June 16 deadline
- remove pushlogs_exporter — not used in VM binary (VM uses otlp/gateway)
- fix: bump Go to 1.26 — required by pushlogs_exporter go.mod
- add pushlogs_exporter source and update CI to mirror e2e-observability-platform build
- fix: bump actions to Node.js 24, disable go cache (no go.sum pre-OCB)
- remove lint-charts workflow — no Helm charts in this repo
- remove Helm chart — belongs in e2e-observability-platform

