# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

## [0.1.0] - 2026-02-14

### Added

- `KinyarwandaModeration.toxic?/2` and `KinyarwandaModeration.check/2`, returning
  a `KinyarwandaModeration.Result` with per-match detail and a suggested action.
- `KinyarwandaModeration.Normalizer` with four Kinyarwanda-aware rules: l/r
  folding, diacritic folding, repeated-letter collapsing, and noun-class prefix
  stripping. Every rule is individually switchable.
- `KinyarwandaModeration.Matcher`, a dependency-free Aho-Corasick automaton over
  token sequences, stored in `:persistent_term` for lock-free reads.
- `KinyarwandaModeration.Lexicon`, a JSON loader and validator driven by
  `priv/data/lexicon.schema.json`, plus the placeholder `priv/data/rw_lexicon.json`.
- A flat `priv/data/rw_hate_speech.json` sample in the simple `["word", ...]` shape.
- Redaction support via the `:redact?` and `:replacement` options.
- OTP application that installs the bundled lexicon at boot, falling back to the
  bundled default when a configured lexicon is missing or invalid.

[Unreleased]: https://github.com/niyonkuruelisa/kinyarwanda_moderation/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/niyonkuruelisa/kinyarwanda_moderation/releases/tag/v0.1.0
