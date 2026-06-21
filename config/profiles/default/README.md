# `default` — fallback profile assets

Shared defaults a profile inherits when its own folder does not provide them.
Resolution: a profile uses `config/profiles/<name>/devcontainer/` if present,
otherwise `config/profiles/default/devcontainer/`.

Empty for now (placeholder). When a generic, toolchain-agnostic default
devcontainer is needed (for a profile that ships none of its own), add it here as
`default/devcontainer/`. Profile-specific devcontainers live in their own profile
folder — e.g. `config/profiles/openclaw/devcontainer/`.
