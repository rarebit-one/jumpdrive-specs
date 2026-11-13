# AGENTS.md

This repo holds the wire contracts between Jumpdrive components, meant to go **public**.

- Write for an outside implementer: what to send, what to expect, what to refuse. Cite the
  implementing repo only by its public name, never by a private path or host.
- `scripts/scrub-check.sh` (CI) fails on private hostnames, private address ranges and estate
  paths. Use placeholders such as `gateway.example.com`, `203.0.113.10`, `198.51.100.0/24`
  (RFC 5737 documentation ranges).
- Examples must be complete and must never contain a real credential, token or key.
- Signed commits; squash merges; worktrees only. Commits end with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
