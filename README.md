# Jumpdrive specs

The wire contracts between Jumpdrive's pieces, written so that anyone can build a compatible
component. Jumpdrive is shaped like a network: an open **data plane** that runs where the work is,
a **coordination plane** that holds identity links, policy and audit, and **identity** borrowed
from the organisation's own provider. These documents are the seams between them.

| Spec | Between | Status |
| --- | --- | --- |
| [Runner protocol](runner/) | coordination plane → runner | stable (v1–v6) |
| [Gateway](gateway/) | callers, coordinator and credential sources ↔ jumpdrive-gateway | stable (run tokens, trusted issuers); draft (policy by reference) |
| [Broker](broker/) | broker ↔ self-hosted machines that dial out | stable |
| [Voidbind](voidbind/) | devices ↔ an organisation's Void-Which-Binds broker | stable |

## Conventions

- **Status** is per section: *stable* (implemented and relied on; changes are versioned), *draft*
  (proposed; may change without a version bump).
- **Versioning**: each spec states its version field and what a receiver must do with an unknown
  version (normally: refuse).
- **Examples** are complete and fully populated, so a parser can be tested against every field.
  Values are placeholders; no example holds a real credential.
- **Key words** MUST, SHOULD and MAY are used as in RFC 2119.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
