# Contributing to Skilly

Three ways to contribute:

## 1. Author a new SKILL.md

The most leveraged contribution. See [Skills/SPEC.md](./Skills/SPEC.md) for the format. Most-requested apps are tracked as `good first issue` — pick one from the [issues list](https://github.com/tryskilly/skilly/issues?q=is%3Aissue+label%3A%22good+first+issue%22) or request a new one via the skill-request template.

Skills are graded on:
- **Source fidelity** — must be sourced from the app's official documentation. Cite the URL.
- **Cadence match** — follow the section ordering of an existing skill (Blender Fundamentals is the reference).
- **Honest scope** — better to teach 4 things well than 20 things shallowly.

## 2. Fix a bug or ship a feature

Open an issue first (templates available). For non-trivial changes, drop a `WIP:` PR early so I can flag any architecture concerns before you sink time.

The codebase is small enough to read top-to-bottom:
- `leanring-buddy/` — the Mac app (Swift)
- `Skills/` — community curricula (Markdown)
- `worker/` — Cloudflare Worker for the hosted tier
- `scripts/release.sh` — the full release pipeline

## 3. Use it and tell me what broke

Send Reddit DMs to u/engmsaleh, X DMs to @moelabs_dev, or open an issue. Honest "this is frustrating" feedback is more useful than polished feature requests.

## Code style

- Swift: standard conventions, no opinionated linter
- Markdown skills: 80-column soft wrap, frontmatter validated against SPEC

## License

By contributing you agree your contribution is licensed under Apache-2.0 (same as the project).
