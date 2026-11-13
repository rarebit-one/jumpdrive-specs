# Runner protocol

**Protocol version: 6.** How a coordination plane (the *control plane*) hands one workflow run to
a *runner*, how the runner reports progress while it executes, and how it hands back the result.

The runner is stateless between runs. Everything it needs arrives in one self-contained *run
payload*; everything it produced leaves in one *run result*. It keeps no shared disk with the
control plane, clones nothing for the workspace itself, and stores no transcript.

| Section | Status |
| --- | --- |
| [1. Overview](#1-overview): parties, transports, authentication, versioning | stable |
| [2. The run payload](#2-the-run-payload) (v1 core) | stable |
| [3. Payload versions 2–6](#3-payload-versions-26): `environment`, `gateway`, git sources, git write, conversations | stable |
| [4. The run result](#4-the-run-result), including `suspended` | stable |
| [5. Heartbeats and cancel](#5-heartbeats-and-cancel) | stable |
| [5.6 Steering over the heartbeat](#56-steering-over-the-heartbeat-draft) | **draft** |
| [6. Errors and refusals](#6-errors-and-refusals) | stable |
| [7. Security considerations](#7-security-considerations) | stable |
| [8. Out of scope: private runs](#8-out-of-scope-private-runs) | not specified here |

Key words MUST, SHOULD and MAY are used as in RFC 2119. Examples are under
[`examples/`](examples/); every value in them is a placeholder.

---

## 1. Overview

### 1.1 Parties

- **Control plane.** Owns the workspace, the workflow definitions, secrets, connectors and
  policy. It resolves everything a run needs (model, credentials, secrets, connector tokens, the
  environment), publishes a snapshot of the workspace tree, builds the payload, and applies the
  result (commits the change set, holds it for approval, files issues, and so on).
- **Runner.** Downloads the snapshot into a throwaway sandbox, runs the workflow's setup steps,
  drives an agent *engine* over it, runs verify steps, diffs the sandbox against the input
  manifest, and reports. The reference runner drives engines through the
  `@rarebit-one/harness-kernel` package, which defines the shapes of `permissions`,
  `connectors` and conversation messages used below.

### 1.2 Transports

A run reaches a runner in one of two ways. The payload and result shapes are identical in both.

**Push (warm pool).** The control plane calls a long-lived runner over HTTP:

| Request | Answer |
| --- | --- |
| `POST /runs` with the payload as a JSON body | `200` with the RunResult (synchronous), or `202` with a RunAccepted (asynchronous, when the payload carries `callbacks.result_url`) |
| `GET /health` | `200` with the health body ([§1.5](#15-health)) |

Any other method or path answers `404 {"error":"not found"}`.

**Pull (per-run worker).** A one-shot worker is started for exactly one run (in a container, a
microVM, or on a machine the organisation runs itself). It is given three values by whatever
launched it: the run id, the control plane's base URL, and a run-callback token. How the launcher
delivers them is placement-specific and outside this spec (for the microVM lane, see the
[broker spec](../broker/)). The worker then:

1. `GET {base}/api/v1/runs/{run_id}/payload` with `Authorization: Bearer <run token>` and
   receives the payload.
2. Executes the run (heartbeating if the payload asks, [§5](#5-heartbeats-and-cancel)).
3. `POST {base}/api/v1/runs/{run_id}/result` with the RunResult as the JSON body and the same
   bearer.
4. Exits `0` if both calls succeeded. A failure to fetch the payload or to post the result is a
   *transport failure*: the worker exits non-zero so its launcher notices. A run that failed is
   not a transport failure; it is reported as a normal result with `status: "error"`.

**Callbacks.** In either transport the payload's `callbacks` block may name a `heartbeat_url`
and a `result_url` ([§2.9](#29-callbacks)). The runner POSTs heartbeats and (asynchronous warm
pool only) the result to those URLs.

### 1.3 Authentication

| Hop | Credential | Rules |
| --- | --- | --- |
| Control plane → runner (`POST /runs`) | `Authorization: Bearer <runner token>`, a shared secret configured on both sides | The runner MUST compare in constant time and answer `401 {"error":"unauthorized"}` on a mismatch or a missing header. A runner MUST NOT start serving `/runs` without a token configured unless an operator explicitly opted out for a local, single-machine deployment. `GET /health` is unauthenticated. |
| Runner → control plane (`/payload`, `/result`, heartbeat, `result_url`) | `Authorization: Bearer <run-callback token>` | The token is opaque to the runner. It arrives as `callbacks.token` in the payload, or (per-run worker) from its launcher. A worker uses `callbacks.token` for heartbeats when present, else its launcher's token; `/payload` and `/result` always use the launcher's token. |

The reference control plane mints the run-callback token as a signed, expiring, purpose-scoped
reference to **one run and one execution attempt**. Its lifetime is at least the largest of: a
configured TTL (default 30 minutes), the supervisor's running window plus 5 minutes, and the
run's `limits.max_duration_ms` plus 5 minutes. Once a retry or re-dispatch claims a newer attempt,
every callback carrying an older attempt's token is answered `409`. A control plane implementing
this protocol SHOULD bind its callback credential to the attempt in the same way, so a delayed
result from attempt *N* can never be applied as attempt *N+1*'s.

### 1.4 Versioning

The payload carries `protocol_version`, an integer. This document describes version **6**.

- **Absent means 1.** A value that is not a JSON number is also read as 1 by the reference runner,
  so senders MUST send an integer.
- **Newer than supported → refuse.** A runner MUST refuse a payload whose `protocol_version` is
  greater than the highest version it supports, *before* checking any other field (a newer
  payload may not carry what this runner considers required):
  - warm pool: `422 {"error":"unsupported protocol_version <n> (supported: <max>)"}`, and nothing
    executes;
  - per-run worker: a transport failure (non-zero exit, no result posted).
- **Older is accepted.** A runner MUST accept every version from 1 up to its own.
- **A block needs its version.** Each optional block below names the version that introduced it.
  A payload that carries the block MUST declare at least that version. A runner that receives the
  block under a lower declared version MUST fail the run (`status: "error"`) before it downloads
  the snapshot. This is what makes an older runner refuse a block it would otherwise silently
  ignore.
- **Declare the minimum.** A sender SHOULD declare the lowest version that covers every block it
  sends, so the payload still runs on older runners when it can. The reference control plane
  starts at 1 and raises the version only for the blocks it adds.
- **Echo.** Every reply (RunAccepted, heartbeat, RunResult) carries the payload's declared version,
  not the runner's maximum.

| Version | Adds | Section |
| --- | --- | --- |
| 1 | The core payload, plus the additive fields `agent_secrets`, `runner.isolation`, `limits.max_steps` / `limits.max_duration_ms` and `callbacks` | [§2](#2-the-run-payload) |
| 2 | `environment` | [§3.1](#31-environment-v2) |
| 3 | `gateway` | [§3.2](#32-credential-gateway-v3) |
| 4 | `{kind: "git"}` entries in `environment.sources` | [§3.3](#33-git-sources-v4) |
| 5 | `write: true` on a git source | [§3.4](#34-git-write-v5) |
| 6 | `conversation`, `external_tools`, `limits.consumed`, `limits.budget_visible`; result fields `pending_calls`, `messages`, `consumed` | [§3.5](#35-conversations-and-suspension-v6) |

**What changes the version.** A change in what a runner accepts or rejects (a new required
field, a removed field, or an optional field a current runner must not ignore because ignoring it
would run the wrong work) bumps the version, in both planes together. An additive optional field
that a current runner may safely ignore does not. A change in an existing field's meaning does not
bump the version either; it is recorded with a date in the implementing repository's contract
notes, and the consumer of the field changes first.

**Unknown members.** A runner MUST ignore unknown top-level payload members. Inside the
`environment` and `gateway` blocks, unknown members are ignored (and SHOULD be logged). An unknown
*value* where a closed set is defined (a source `kind`, `environment.tools`, a gateway route
provider) MUST fail the run, never be skipped. A control plane MUST ignore unknown result and
heartbeat members, and MUST treat enumerated result strings (`outcome`, `stop_reason`,
`finish_reason`) as open sets.

### 1.5 Health

`GET /health` → `200`:

```json
{ "status": "ok", "plane": "execution",
  "capabilities": { "environment_spec": true, "credential_gateway": true } }
```

`capabilities` is additive. `environment_spec` is true only when the runner's operator enabled the
environment block ([§3.1](#31-environment-v2)); a dispatcher SHOULD check it before sending an
`environment`. `credential_gateway` is true on every runner that implements version 3. A consumer
MUST NOT require `capabilities` to be present (older runners omit it). See
[`examples/health.json`](examples/health.json).

---

## 2. The run payload

Example: [`examples/run-payload.v1.json`](examples/run-payload.v1.json).

### 2.1 Top-level fields

| Field | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `protocol_version` | integer | no (absent = 1) | [§1.4](#14-versioning). |
| `run_id` | string | **yes** | The run's id (a UUID in the reference control plane). Missing → `422`. |
| `workspace_id` | string | yes | The workspace the run belongs to. Opaque to the runner. |
| `workflow_path` | string | **yes** | Path, inside the snapshot, of the workflow YAML to run. Missing → `422`. See [§3.1](#31-environment-v2) for a run whose environment carries the prompt and no file exists. |
| `tarball_url` | string | **yes** | Short-lived HTTPS GET URL (typically presigned object storage) of a `.tar.gz` of the input tree. Missing → `422`. [§2.2](#22-the-snapshot). |
| `input_manifest` | object | yes | The full input tree: `{ "<relative path>": "<sha256 hex of the file bytes>" }`. [§2.2](#22-the-snapshot). |
| `repo_snapshot` | integer or null | yes | Opaque snapshot sequence the run executes against. Logged only. |
| `permissions` | object | yes | [§2.3](#23-permissions). |
| `context_bundle` | object | yes | `{ "mode": "explicit" \| "curated" \| "hybrid", "inputs": { … } }`. `mode` selects how the runner assembles file context from the workflow; `inputs` is a free-form map handed to the engine as the run's inputs. |
| `provider` | object | yes | [§2.4](#24-provider). |
| `secrets` | object | yes | `{ "<NAME>": "<value>" }`: the workflow's declared secrets, already resolved. Exposed as environment variables to setup and verify steps, and to the agent per `agent_secrets`. |
| `agent_secrets` | array of string or null | no | Names of the `secrets` the agent phase may see ([§2.5](#25-secrets-and-agent_secrets)). |
| `runner` | object or null | no | `{ "isolation": "none" \| "container" \| "vm" }` ([§2.6](#26-isolation)). |
| `connectors` | array | no (default `[]`) | External tool servers the run may use ([§2.7](#27-connectors)). |
| `limits` | object or null | no | Budget overrides ([§2.8](#28-limits)). v6 adds two members. |
| `callbacks` | object or null | no | Heartbeat and result endpoints ([§2.9](#29-callbacks)). |
| `environment` | object or null | no, **v2** | [§3.1](#31-environment-v2). |
| `gateway` | object or null | no, **v3** | [§3.2](#32-credential-gateway-v3). |
| `conversation` | object or null | no, **v6** | [§3.5](#35-conversations-and-suspension-v6). |
| `external_tools` | array or null | no, **v6** | [§3.5](#35-conversations-and-suspension-v6). |

Two further members exist in the reference implementation and are not part of this public
contract: `vault` ([§8](#8-out-of-scope-private-runs)) and `steering_history`
([§5.6](#56-steering-over-the-heartbeat-draft), draft). A runner that does not implement them
ignores them as unknown members.

### 2.2 The snapshot

The runner MUST download `tarball_url` and extract it into a fresh, private directory; that
directory *is* the workspace for the run. Entries are forward-slash relative paths with no leading
`./`.

- The runner MUST reject the whole archive if any entry's normalised path is absolute or contains
  a `..` segment (tar-slip).
- The reference runner caps the download at 1 GiB and 120 s by default, re-validates every
  redirect hop (at most 5) against its outbound-address guard, and accepts `file://` URLs only
  when its operator has enabled them for local development.
- The control plane MUST list in `input_manifest` exactly the files the archive contains. A path
  listed but absent from the archive is reported back as deleted.

When the run finishes, the runner walks the sandbox (regular files only) and builds the change
set ([§4.2](#42-change_set)) by comparing each file's SHA-256 against `input_manifest`.

### 2.3 Permissions

Defined by the harness kernel. All members are optional arrays of strings; other members are
carried through untouched for engines that read them.

| Member | Meaning |
| --- | --- |
| `read` | Path prefixes the run may read. |
| `write` | Path prefixes the run may write. |
| `tools` | Allow-list of tool names (the engine's primitives and the runner's own emission tools). An **empty or absent list means no restriction**. To withhold every tool, see `environment.tools` ([§3.1](#31-environment-v2)). |
| `hosts` | Egress allow-list (`host[:port]`) for the HTTP-fetch primitive. |

### 2.4 Provider

| Member | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `preferred` | string or null | no | Provider the workflow prefers: `anthropic`, `openai`, `openrouter`, or `local` (an on-machine model). Null = no preference. |
| `model` | string or null | no | Model id of the **orchestrator** (the model that drives the agent loop). Null → the runner's configured default. There is deliberately one model here; perception models a runner registers itself are invoked as tools and are not selected through the payload. |
| `engine` | string or null | no | Agent harness: `native` (default; the kernel's in-process loop), or an out-of-process adapter such as `claude-code` or `codex`. |
| `credentials` | object | no | Bring-your-own provider keys `{ "anthropic"?, "openai"?, "openrouter"? }`, resolved by the control plane. A provider with no key here falls back to the runner host's own key. With a `gateway` block, no raw key reaches the engine at all ([§3.2](#32-credential-gateway-v3)). |

If the selected provider has no usable credential the run MUST fail (`status: "error"`) rather
than silently run on a mock model. The reference runner checks this for the native engine before
downloading the snapshot.

### 2.5 Secrets and `agent_secrets`

Setup and verify steps always receive every secret in `secrets` as environment variables. The
agent phase (and so every model-driven code execution) receives only the secrets named in
`agent_secrets`:

- absent or null → every secret (the behaviour before the field existed);
- `[]` → none;
- a name not present in `secrets` is ignored.

A control plane SHOULD always send `agent_secrets`, even when empty.

### 2.6 Isolation

`runner.isolation` is the control plane's claim about where it placed the run: `none` (a shared
warm-pool process, or the owner's own machine), `container` (an ephemeral container of its own) or
`vm` (a microVM of its own). The runner MUST take the **weaker** of this claim and its own
configured isolation level, so the payload can only lower isolation, never raise it. Absent, null
or an unknown value means `none`. An out-of-process engine (a vendor CLI or other agent binary)
MUST NOT run below `container`; a warm-pool runner is `none` by construction, whatever its
environment or the payload says.

### 2.7 Connectors

Each entry is a kernel `ConnectorConfig`:

| Member | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `name` | string | yes | The connector's name; namespaces its tools. |
| `kind` | `"mcp"` \| `"http"` | yes | A Model Context Protocol server, or a plain HTTP service. |
| `transport` | `"stdio"` \| `"streamable_http"` \| `"sse"` | yes | Wire transport. |
| `endpoint` | string | for `streamable_http`, `sse` | Server URL. |
| `command`, `args` | string, array of string | for `stdio` | Process to spawn. |
| `auth` | object | no | `{ "type": "bearer", "token": "<token>" }` or `{ "type": "none" }`. The token is already resolved; the runner treats it as opaque. |
| `clientInfo` | object | no | `{ "name", "version"? }` announced to the server. Not sent by the reference control plane. |
| `tools` | array of string | no | The server's own tool names this run may see and call; absent = all, `[]` = none. An engine that cannot enforce it MUST refuse the run. Not sent by the reference control plane. |

Connectors are not gated by `permissions.tools`: the control plane already selected them.

### 2.8 Limits

| Member | Type | Meaning |
| --- | --- | --- |
| `max_steps` | positive integer | Maximum model steps the agent may take. |
| `max_duration_ms` | positive integer | Wall-clock budget for the agent phase, in milliseconds. |
| `consumed` | object, **v6** | [§3.5](#35-conversations-and-suspension-v6). |
| `budget_visible` | boolean, **v6** | [§3.5](#35-conversations-and-suspension-v6). |

Each member is independent. An absent `max_steps` / `max_duration_ms` keeps the runner's default
(the reference kernel: 12 steps, 10 minutes). A value that is not a positive integer is ignored
with a log line, not a failure. Engines that cannot honour a budget ignore it. A control plane
that has its own deadline for the run (a supervisor timeout, a synchronous HTTP read timeout)
SHOULD clamp `max_duration_ms` below it, leaving headroom for setup, verify and the result post.

### 2.9 Callbacks

| Member | Type | Meaning |
| --- | --- | --- |
| `heartbeat_url` | string | Where to POST heartbeats ([§5](#5-heartbeats-and-cancel)). Absent → no heartbeats. |
| `result_url` | string | Where to POST the RunResult. On a warm-pool `POST /runs`, its presence switches the runner to asynchronous mode ([§4.5](#45-delivering-the-result)). |
| `token` | string | Sent as `Authorization: Bearer <token>` on both. |
| `interval_ms` | integer | Heartbeat cadence; default 10000. A value that is not a positive integer means the default; values below 100 are raised to 100. |

The reference control plane sends `https://<control plane>/api/v1/runs/<run_id>/heartbeat` and
`…/result`, the same endpoints the per-run worker uses.

---

## 3. Payload versions 2–6

### 3.1 Environment (v2)

Example: [`examples/run-payload.v2.json`](examples/run-payload.v2.json).

`environment` is the run's **resolved** environment: the control plane has already merged the
environment version, the workflow and any inline overrides, and the runner merges nothing.
Environment settings that already have a home elsewhere in the payload travel there and are not
repeated here: tool allow-lists in `permissions.tools` and `connectors`, network allow-lists in
`permissions.hosts` (intersected, never unioned), the timeout in `limits`, image and resources in
placement.

| Member | Type | Meaning |
| --- | --- | --- |
| `ref` | string or null | `name@version` of the resolved environment. Logged only. |
| `prompt` | string or null | **Replaces** the workflow YAML's `prompt`. If no file exists at `workflow_path` and `prompt` is present, the runner synthesises the workflow (`{name: ref, prompt}`), so a one-call run needs no committed YAML. |
| `setup` | array of string or null | **Replaces** the workflow YAML's `setup:` list (the final, ordered list). |
| `instructions` | object or null | `{ "system"?: string, "agents_md"?: string }`: a system prompt and a root `AGENTS.md` for the engine. |
| `agent_files` | array of File or null | Nested instruction files; each `path` ends in `AGENTS.md`. |
| `skills` | array or null | `[{ "name": string, "files": [File] }]`: agent skill directories; `files` includes `SKILL.md`. |
| `sources` | array or null | Run inputs that are not workspace content: `{ "kind": "inline", …File }`, and from v4 `{ "kind": "git", … }` ([§3.3](#33-git-sources-v4)). Any other `kind` MUST fail the run. |
| `tools` | `"none"` or null | `"none"` withholds every tool, primitive and domain: the native engine is given an empty tool allow-list. It needs its own value because an empty `permissions.tools` means "no restriction". Only the native engine can honour it; an out-of-process engine (which brings its own built-in tools) MUST fail the run. Any other value MUST fail the run. Connectors are left as sent. |

A **File** is `{ "path": string, "content": string, "encoding"?: "utf8" | "base64" }`
(`utf8` by default).

The runner writes the instruction files, skills and inline sources into the workdir **before**
setup runs, and removes them again **before** computing the change set, so none of it is
committed. A file the engine itself rewrote is kept, and therefore appears in the change set.

Rules:

- The block is honoured only when the runner's operator enabled it (advertised as
  `capabilities.environment_spec`). A runner that has it disabled and receives a block MUST fail
  the run rather than run the base workflow without it.
- A block under a declared version below 2 MUST fail the run.
- A malformed block MUST fail the run (`status: "error"`) before the snapshot is downloaded,
  naming the first bad member. Unlike `limits`, nothing here has a safe default: dropping an
  instruction or a source would run something other than what was asked and still report success.

### 3.2 Credential gateway (v3)

Example: [`examples/run-payload.v3.json`](examples/run-payload.v3.json). The gateway itself is
specified in [`../gateway/`](../gateway/).

| Member | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `base_url` | string | yes | The gateway's base URL; absolute `http` or `https`, with no user-info. |
| `run_token` | string | yes | The attempt-bound token the gateway authenticates the run with. Non-empty. |
| `routes` | object or null | no | Per-provider base URLs overriding the default route `<base_url>/p/<provider>`. Keys MUST be among `anthropic`, `openai`, `openrouter`; values are URLs under the same rules as `base_url`. |

With the block present, every engine MUST reach its model provider at the gateway route with
`run_token` as its API key, and **no raw provider key** (neither `provider.credentials` nor the
runner host's own keys) may reach an engine. The gateway swaps in the real key on its side.

Rules:

- A block under a declared version below 3 MUST fail the run. (A runner that predated the block
  would ignore it and run on its host's keys, the very thing the gateway exists to prevent;
  declaring 3 makes such a runner refuse instead.)
- A malformed block MUST fail the run before the snapshot is downloaded, never fall back to raw
  keys. That includes a non-http(s) or credential-bearing URL, an empty `run_token`, or a route
  for a provider the runner cannot route. Unknown members are ignored.
- The block needs no operator flag; every v3 runner advertises
  `capabilities.credential_gateway: true`.

What the reference control plane does when it routes a run through the gateway (informative;
the payload shape is the same either way):

- sets `routes` for `openai` and `openrouter` to `<base_url>/p/<provider>/v1` (their SDKs expect
  `/v1` in the base URL) and leaves `anthropic` on the default route;
- removes the `anthropic`, `openai` and `openrouter` keys from `provider.credentials` (a `local`
  entry stays), and names the routed provider in `provider.preferred`;
- re-points each granted `streamable_http` connector at `<base_url>/c/<connector id>` with
  `run_token` as its bearer; `stdio` and `sse` connectors keep their direct settings;
- re-points each granted git source at `<base_url>/git/<host>/<owner>/<repo>` with `run_token`
  as its password.

### 3.3 Git sources (v4)

Example: [`examples/run-payload.v4.json`](examples/run-payload.v4.json).

An `environment.sources` entry may be a git repository that the runner fetches itself, outside
the agent's environment, after the snapshot is extracted and **before** setup:

| Member | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `kind` | `"git"` | yes | |
| `url` | string | yes | `https://host/owner/repo(.git)`. `http` only for a loopback host. No embedded credentials. |
| `ref` | string or null | no | Branch, tag or full 40-hex commit id; the remote's `HEAD` when absent. MUST match `^(?!-)(?!.*\.\.)[A-Za-z0-9._/-]{1,200}$`. |
| `path` | string or null | no | Where in the workdir; defaults to the repository name (last URL segment, `.git` stripped). MUST stay inside the workdir, MUST NOT start with `-`, and MUST NOT contain a `.git` or `.workspace` segment. |
| `auth` | object or null | no | `{ "username"?: string, "password": string }`, HTTP basic. `username` defaults to `x-access-token` and MUST NOT contain `:`; `password` MUST be non-empty. A short-lived token the control plane minted, or (behind the gateway) the run token. |
| `write` | `true` or null | no, **v5** | [§3.4](#34-git-write-v5). |

Behaviour:

- A shallow fetch of `ref` into `path`, checked out detached. A commit `ref` fetches every branch
  and tag in full, so the commit may sit on any of them.
- `auth` travels only as a request header on the fetch. It MUST NOT be written to the checkout's
  `.git/config`. Redirects are refused, so the header cannot follow one to another host.
- A `path` that already exists in the workspace MUST fail the run (a source never shadows
  workspace content).
- The first fetch failure removes what was fetched so far and fails the run.
- Every checkout is removed **before** the change set is computed (a fetched repository is input,
  never output), along with any parent directory created for it that is still empty.
- A git source under a declared version below 4 MUST fail the run.

### 3.4 Git write (v5)

Example: [`examples/run-payload.v5.json`](examples/run-payload.v5.json).

A git source may carry `write: true`. When its `url` is under the gateway's `/git/` route
(`<gateway.base_url>/git/…`) **and** the payload carries a `gateway` block, the runner leaves an
`http.<base_url>/git/.extraHeader` entry carrying the run token in the checkout's own
`.git/config` after the fetch, so native git inside the run can push back through the gateway.
The key is URL-scoped, so no other host sees the token. Without a gateway, or off its route,
`write` configures nothing. The gateway allows `git-receive-pack` only for a grant with `write`.

- A write source under a declared version below 5 MUST fail the run. A payload whose git sources
  are all read-only keeps declaring 4.
- A control plane SHOULD refuse to dispatch a write source the gateway will not route, rather
  than let it run read-only without saying so.

### 3.5 Conversations and suspension (v6)

Example: [`examples/run-payload.v6.json`](examples/run-payload.v6.json) and its suspended answer
[`examples/run-result.v6.json`](examples/run-result.v6.json).

Version 6 lets a run *park* on a tool that the control plane executes, end, and be continued
later by a **new** run that carries the transcript. The runner holds nothing in between.

| Member | Type | Meaning |
| --- | --- | --- |
| `conversation` | `{ "messages": [Message] }` or null | A stored history to **continue** instead of starting from the workflow's task prompt. The native engine seeds its loop with it verbatim and builds no user prompt; the system prompt is still the workflow's. |
| `external_tools` | array or null | Tools the control plane executes: `[{ "name", "description", "input_schema" }]`. The model may call one; the loop parks the call instead of running it, and the run ends `outcome: "suspended"`. |
| `limits.consumed` | `{ "steps": int, "duration_ms": int }` or null | What earlier runs of this conversation already spent (the sum of their `consumed`). The runner subtracts it from the budget before the loop starts, flooring at one step and one minute so the resumed step always runs. |
| `limits.budget_visible` | boolean or null | Tell the model on every step how many steps and how much time remain. Advisory; the limits stay hard. |

**Message** (the kernel's provider-neutral turn):

| Role | Shape |
| --- | --- |
| `user` | `{ "role": "user", "text": string }` |
| `assistant` | `{ "role": "assistant", "text": string, "toolCalls": [ToolCall] }` |
| `tool` | `{ "role": "tool", "results": [ToolResult] }` |

- **ToolCall**: `id` (string), `name` (string), `input` (object, the parsed arguments),
  `argumentsText` (string, optional: the exact bytes the model emitted, preserved so what resumes
  is what was parked), `meta` (object, optional: opaque provider data that must round-trip),
  `external` (`true`, optional: set on a call the loop parked).
- **ToolResult**: `toolCallId` (string), `content` (string, what the model is shown),
  `structured` (any, optional), `isError` (boolean, optional), `rejected` (boolean, optional: the
  control plane declined to execute a parked call; implies `isError`, and the resumed loop
  reports the call as `tool.failed` with `reason: "rejected"`).

Note that message members are camelCase (`toolCalls`, `toolCallId`, `argumentsText`), unlike the
rest of the payload.

Rules:

- A payload carrying any of the four members MUST declare at least 6; under a lower version the
  run MUST fail. (An older runner would ignore the seed, run the task prompt from scratch, and
  report `completed` on what was meant as a continuation.)
- `conversation.messages` MUST be a non-empty array; every entry MUST have a valid role and the
  members its role requires; it MUST NOT end with an `assistant` message (it ends with a user
  message, or with the tool results the model is waiting for, including the answers to every call
  the previous run parked).
- `external_tools[].name` MUST match `^[a-zA-Z0-9_-]{1,64}$`, MUST be unique, and MUST NOT
  collide with a tool the runner itself provides; `description` MUST be a string; `input_schema`
  MUST be a JSON Schema object (at least `{"type":"object"}`). External tools are not gated by
  `permissions.tools`.
- `limits.consumed` MUST be two non-negative integers.
- Only the native engine can continue a conversation or park external tools. A payload carrying
  these members with any other engine MUST fail the run; senders SHOULD pin `engine: "native"`.
- All validation happens before the snapshot is downloaded.

The resulting continuation loop:

1. The run ends `suspended` with `pending_calls`, the whole `messages` transcript and `consumed`
   ([§4.4](#44-suspended-results-v6)).
2. The control plane executes the calls (asks a person, waits as long as it likes; no runner
   process is held).
3. It dispatches a new run whose `conversation.messages` are that transcript plus a `tool` turn
   answering every pending id, with `limits.consumed` summed so far.

---

## 4. The run result

Example: [`examples/run-result.v1.json`](examples/run-result.v1.json).

### 4.1 Fields

| Field | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `protocol_version` | integer | yes (absent = 1) | Echo of the payload's declared version. |
| `status` | `"success"` \| `"error"` | yes | Whether the run completed. |
| `change_set` | object | yes | [§4.2](#42-change_set). Empty (`{"changed":[],"deleted":[]}`) when nothing changed, and always empty on an error, cancel or suspension. |
| `artifacts` | array | yes | `[{ "path": string, "bytes": int }]`. The reference runner writes the agent's final text to `.workspace/runs/<run_id>/output.md` (which is also in the change set) and lists it here. |
| `logs` | array of string | yes | Run log lines, secrets masked ([§7](#7-security-considerations)). |
| `error` | string or null | no | Why the run failed; masked. Present on `status: "error"`. |
| `verification` | object | no | Present only when the workflow declares `verify:` steps: `{ "passed": bool, "checks": [{ "command": string, "exitCode": int \| null, "timedOut": bool, "output"?: string }] }`. `passed` is true iff every check exited 0 without timing out; it is computed by the runner, never by the model. `output` is a truncated tail of stdout and stderr. A control plane SHOULD refuse to commit a change set whose verification did not pass. |
| `knowledge` | array | no | Durable facts the run asks to store: `[{ "content", "title"?, "kind"?, "path"?, "dedupe_key"?, "source"? }]`. Present only when non-empty. |
| `issues` | array | no | Things the run wants a person to look at: `[{ "title", "body"?, "dedupe_key"?, "labels"? }]`. Present only when non-empty. |
| `tasks` | array | no | Child tasks the workflow requested, dispatched only after the run commits: `[{ "key"?, "title", "context_refs": [string], "output_refs"?: [string], "initial_message", "computer_id"? }]`. Refs are opaque control-plane references. Present only when non-empty; `output_refs` only when non-empty. |
| `provider` | object | no | What the run actually executed on ([§4.3](#43-provider-observed)). |
| `outcome` | string | no | Why the agent phase stopped: `completed`, `steps_exhausted`, `timed_out`, `cost_exhausted`, `failed`, `canceled`, `suspended`. Orthogonal to `status` (a run that exhausted its steps can still succeed). Absent when the engine reported none. An open set. |
| `stop_reason` | string | no | One level finer: `end_turn`, `terminal_tool`, `length`, `steps_exhausted`, `timed_out`, `cost_exhausted`, `canceled`, `failed`, `suspended`. A `completed` run with `stop_reason: "length"` is a prose answer the output token cap cut short: a consumer MUST NOT apply the text as if it were whole. An open set. |
| `finish_reason` | string | no | Why the last model call stopped generating: `stop`, `tool_calls`, `length`, `content_filter`, `unknown`. An open set. |
| `pending_calls` | array | no, **v6** | [§4.4](#44-suspended-results-v6). |
| `messages` | array of Message | no, **v6** | [§4.4](#44-suspended-results-v6). |
| `consumed` | object | no, **v6** | [§4.4](#44-suspended-results-v6). |

Two further members (`private`, `error_code`) belong to the private-run profile and are not part
of this contract ([§8](#8-out-of-scope-private-runs)).

### 4.2 `change_set`

```json
{ "changed": [ { "path": "…", "content": "…", "encoding": "base64" } ], "deleted": [ "…" ] }
```

- `changed`: every file in the sandbox whose SHA-256 differs from `input_manifest[path]`, or that
  is absent from the manifest, with its **full** content (not a diff). `content` is the UTF-8 text
  when the bytes are valid UTF-8; otherwise it is base64 and `encoding` is `"base64"`. The control
  plane hashes the decoded bytes; text and base64 forms of the same bytes are equivalent.
- `deleted`: manifest paths no longer present in the sandbox.
- Files the runner itself materialised ([§3.1](#31-environment-v2)) and git checkouts
  ([§3.3](#33-git-sources-v4)) are removed before the diff and so never appear.
- The reference runner fails the run if the total changed content exceeds 64 MiB.

### 4.3 `provider` (observed)

`{ "engine": string, "name": string | null, "model": string | null }`: the engine that ran
(`native`, `claude-code`, `codex`, …), the provider adapter that served the model (`anthropic`,
`openai`, `openrouter`, `local`, `mock`), and the model id the engine reported. This is
**observed**, not predicted from the payload.

- `name` is null when no adapter served the run: an out-of-process engine brings its own model
  and reports none, or the run failed inside the engine before it returned.
- `model` is null when nothing was reported.
- The whole block is absent when the run never reached engine selection (for example a refusal
  before anything ran). A consumer MUST read absence as "not reported", never as "no provider was
  used".
- `name: "mock"` on a run that did not ask for the mock is a degraded run; a consumer SHOULD treat
  it as such.

### 4.4 Suspended results (v6)

Example: [`examples/run-result.v6.json`](examples/run-result.v6.json).

When the model calls an external tool, the run ends with:

- `status: "success"`, `outcome: "suspended"` (and `stop_reason: "suspended"`);
- `pending_calls`: `[{ "id": string, "name": string, "input": object, "arguments_text"?: string }]`,
  the parked calls (`arguments_text` is the exact bytes the model emitted, when the provider
  dialect delivers them);
- an **empty** `change_set` and `artifacts`, and no `verification`: the sandbox is destroyed, and
  a half-done edit is not a result to commit.

On any run whose payload carried at least one v6 member, the result also carries, when the engine
reported them:

- `messages`: the whole conversation the run leaves behind (the seed it was given followed by
  everything the loop appended). This is what the control plane stores and sends back as the next
  `conversation.messages`.
- `consumed`: `{ "steps": int, "duration_ms": int, "usage"?: Usage }`, what this run spent. The
  control plane sums these across a conversation into the next `limits.consumed`.

**Usage** (also used on heartbeats): `input_tokens`, `output_tokens`, `cache_read_input_tokens`,
`cache_creation_input_tokens`, all optional non-negative integers. `input_tokens` is the
**uncached** input; the two cache counts sit beside it (each sent only when non-zero), so a turn's
whole prompt is the sum of all three. (Runners before 2026-11-12 sent only `input_tokens` and
`output_tokens`, with cached input counted inside `input_tokens`.)

Secret values the payload carried are masked in `pending_calls` and `messages` like everywhere
else.

### 4.5 Delivering the result

| Transport | How the result travels |
| --- | --- |
| Warm pool, no `callbacks.result_url` | The `200` body of `POST /runs`. |
| Warm pool, with `callbacks.result_url` | `POST /runs` answers `202` at once ([`examples/run-accepted.json`](examples/run-accepted.json)); the runner executes in the background and POSTs the RunResult to `result_url` with `Authorization: Bearer <callbacks.token>`. |
| Per-run worker | `POST {base}/api/v1/runs/{run_id}/result`. |

**RunAccepted**: `{ "protocol_version": int, "run_id": string, "accepted": true }`. A control
plane distinguishes it from a RunResult by `accepted: true` and the absence of `status`.

**Idempotency.** A duplicate `POST /runs` for a `run_id` that is still executing MUST NOT start a
second execution: in asynchronous mode it gets the same `202`; in synchronous mode it waits on the
same execution and receives the same result. Once a run has finished, a new `POST` with the same
`run_id` is a fresh execution. (The reference runner keeps this state per process.)

**Retries (asynchronous warm pool).** The runner retries the POST to `result_url` on network
errors and on any `5xx`: 6 attempts in all, backing off 4, 8, 16, 32, 60 s (about two minutes),
honouring `Retry-After` (seconds or an HTTP date) capped at 60 s, with a 30 s timeout per attempt.
Any other status is final: `2xx` delivered it, `409` means the control plane has moved on (a newer
attempt, or the run already settled), `404` that it does not know the run.

**Per-run worker.** The reference worker POSTs the result once; any non-`2xx` answer is a
transport failure (non-zero exit), and recovery is the control plane's supervisor re-dispatching
the run.

**Control-plane answers on `/result`** (the reference control plane):

| Status | Body | Meaning |
| --- | --- | --- |
| `200` | `{ "ok": true, "status": "<run status>" }` | Applied, or ignored because the run is no longer running (a duplicate or late post). Applying is atomic and idempotent per attempt. |
| `401` | `{ "error": "unauthorized" }` | Bad or expired token, or the token names another run. |
| `409` | `{ "error": "callback is for attempt N; the run is on attempt M" }` | A newer attempt has claimed the run. |
| `422` | `{ "error": "…" }` | Body is not valid JSON, or could not be stored. |
| `503` | `{ "error": "…" }` with `Retry-After` | Transient; the run is still running and a re-post will apply. |

A canceled run's result is accepted only to finish it: the control plane records it and discards
its change set.

### 4.6 The ephemeral worker's payload endpoint

`GET {base}/api/v1/runs/{run_id}/payload` (the reference control plane):

| Status | Body | Meaning |
| --- | --- | --- |
| `200` | the payload | A fresh snapshot is published per fetch, so `tarball_url` is short-lived. |
| `401` | `{ "error": "unauthorized" }` | |
| `409` | `{ "error": "…" }` | A newer attempt claimed the run; or the run is not `running` (the payload, which carries secrets, is served only while the run is in flight); or, on the microVM lane, this attempt's payload was already fetched (a microVM gets its payload **once per attempt**, so a token lifted from a compromised guest cannot read it again). |
| `422` | `{ "error": "<reason>" }` | The control plane cannot build a payload this placement may run (for example an unsuitable model, or a run that must stay on the owner's own machine). The run is failed with that reason. |

---

## 5. Heartbeats and cancel

Example: [`examples/run-heartbeat.json`](examples/run-heartbeat.json).

### 5.1 Request

When the payload carries `callbacks.heartbeat_url`, the runner POSTs a beat every
`interval_ms`, with `Authorization: Bearer <token>` ([§1.3](#13-authentication)):

| Field | Type | Meaning |
| --- | --- | --- |
| `protocol_version` | integer | Echo of the payload's declared version. |
| `run_id` | string | |
| `last_seq` | integer or null | The highest event `seq` the runner has **produced**, including events dropped from an overflowing buffer, so a gap is visible. Null until the engine emits its first event. |
| `events` | array of Event | Progress since the last accepted beat. An empty array is a liveness-only beat (it covers setup and long tool calls). |

**Event**: `{ "seq": int, "type": string, "at": ISO-8601 string, "data": object }`. `seq` is per
execution and starts at 0 (a retry attempt starts again at 0).

| `type` | `data` |
| --- | --- |
| `run.started` | `{ "tool_count": int, "tool_schema_bytes"?: int }`: the size of the tool catalog the model reads on every turn (UTF-8 bytes of the tool specs). Tool names are never sent. Older runners send `{}`. |
| `model.turn` | `{ "step": int, "tool_calls": [tool name], "usage"?: Usage, "text"?: string }`. `text` is the assistant prose, masked then capped at 2048 characters. |
| `model.turn.failed` | `{ "step": int, "error": string }`: masked, capped at 512 characters. |
| `tool.called` | `{ "step": int, "call_id": string, "name": string, "replay"?: "safe" \| "unsafe", "input_bytes": int }`. `replay` is the tool's own claim about whether it is safe to run again; absent means no claim, which a consumer MUST treat as `unsafe`. |
| `tool.pending` | `{ "step": int, "call_id": string, "name": string, "input_bytes": int }`: a call parked for the control plane (v6). |
| `tool.succeeded` | `{ "step": int, "call_id": string, "name": string, "output_bytes": int }` |
| `tool.failed` | `{ "step": int, "call_id": string, "name": string, "reason": string }`; reasons include `threw`, `unknown_tool`, `aborted`, `truncated`, `rejected`, `invalid_input`. |
| `run.budget_exhausted` | `{ "kind": "steps" \| "duration" \| "cost" }` |
| `run.finished` | `{ "outcome": string }` |
| any other | `{}`: a newer engine's event type is forwarded with no data. |

Raw tool inputs, raw tool outputs and raw tool errors are **never** sent; only sizes, names and
ids. This is an allow-list, field by field.

### 5.2 Sending rules

- At most one beat in flight; a tick that finds one outstanding does nothing.
- At most 500 events are buffered; on overflow the oldest are dropped (and `last_seq` shows the
  gap).
- A beat that is not answered `200` (any other status, a network error, or a 10 s timeout) is
  treated as `continue`: its events go back to the front of the buffer, and the next attempt
  backs off `interval × 2^n`, capped at 60 s.
- Before the result is delivered, the runner makes one final flush (waiting for any beat in
  flight, ignoring backoff), so the progress stream lands before the result.
- A heartbeat MUST NOT fail a run.

The control plane MUST deduplicate events on (run, attempt, `seq`): a re-sent batch is harmless,
a lost one is not. The reference control plane also skips (rather than rejects) malformed events:
more than 500 per beat, a `type` over 64 characters, a negative or non-integer `seq`, or `data`
over 8 KiB serialised.

### 5.3 Response

`200` with one of:

```json
{ "action": "continue" }
{ "action": "cancel", "reason": "canceled by user" }
```

`reason` is optional. Anything other than a well-formed `cancel` in a `200` body is read as
`continue`.

The reference control plane answers:

| Run state | Answer |
| --- | --- |
| queued, running | `200 continue` |
| canceling | `200 cancel` (the beat is still recorded) |
| finished (any terminal state) | `200 cancel`, nothing recorded: no runner should still be executing it |
| anything else (not yet started, parked awaiting approval) | `409` |
| token for an older attempt | `409` |
| bad token | `401` |
| body is not JSON | `422` |

### 5.4 Cancel

The control plane cancels a run by answering a beat, with a `200`, `{"action":"cancel"}`. On a
cancel the runner:

- acts once: the first cancel records its reason and aborts; later ones are ignored;
- stops whatever phase is running (a setup or verify step's process group, or the engine). A
  cancel before the engine starts skips the engine; verify never runs after a cancel. An engine
  that ignores the signal is waited for, and its work is discarded;
- keeps beating until the result is ready, then delivers it exactly as for any run, with
  `status: "error"`, `outcome: "canceled"`, `error: "canceled: <reason>"` (`"requested by the
  control plane"` when no reason was given), and an **empty** `change_set` and `artifacts`.
  Example: [`examples/run-result-canceled.json`](examples/run-result-canceled.json).

A runner that predates cancel ignores the answer and runs to completion, so a control plane MUST
NOT rely on the runner stopping: it discards a canceled run's change set itself. Cancellation
stops the run's proposed changes from landing; it does not undo side effects the run already had
(calls it made through connectors, for example).

### 5.5 Heartbeat-only liveness

Heartbeats are how a control plane tells a long run from a hung one. A control plane SHOULD
treat a run whose beats stop arriving as lost after a window of its choosing, and SHOULD NOT treat
a single failed beat as anything.

### 5.6 Steering over the heartbeat (draft)

**Draft: implemented in the reference control plane behind an operator flag; no runner
implements it yet.** Example:
[`examples/run-heartbeat-steering.draft.json`](examples/run-heartbeat-steering.draft.json).

Steering delivers messages a person (or a delegated agent) posts to a run while it is still
going, so the native loop can fold them in before its next model call.

- A runner that can take messages sets `"steering": true` on a beat, and lists the ids of the
  messages it has folded in as `"acked_message_ids": [string]`.
- On a `continue`, the control plane then adds `"messages": [{ "id": string, "ordinal": int,
  "body": string, "posted_at": ISO-8601 string }]`: everything still live, oldest first, bounded
  per beat. A message is redelivered on every beat until acked, and an ack counts only for the
  attempt it was delivered to. A runner that does not send `steering: true` never sees `messages`.
- A retry attempt's payload carries `steering_history` (the same message shape, acked messages in
  order) so its engine sees what the attempt it replaces was told.
- Only the native engine can be steered; a control plane MUST refuse to queue a message for a run
  whose engine cannot take one.

---

## 6. Errors and refusals

There are three kinds of failure, and they travel differently.

| Kind | When | How it is reported |
| --- | --- | --- |
| **Refusal** | The runner cannot accept the payload at all: bad auth, a newer protocol version, missing `run_id` / `workflow_path` / `tarball_url`, an oversized body. | Warm pool: a `4xx` and nothing executes. Per-run worker: a newer version is a transport failure; everything else is a run failure. |
| **Run failure** | Anything after acceptance: a block that needs a higher version, a malformed block, no credential for the provider, an unsupported engine for the payload, a snapshot that fails to download or extract, a failing setup step, an engine error, an oversized change set, a cancel. | A normal RunResult with `status: "error"`, `error` set, an empty change set, and `provider` / `outcome` only if they were observed. Validation failures happen before the snapshot is downloaded. |
| **Transport failure** | The per-run worker cannot fetch its payload or post its result. | Non-zero exit. The control plane's supervisor recovers. |

### 6.1 `POST /runs` status codes

| Status | Body | When |
| --- | --- | --- |
| `200` | RunResult | Synchronous run finished (successfully or not). |
| `202` | RunAccepted | Asynchronous run accepted. |
| `401` | `{ "error": "unauthorized" }` | Missing or wrong bearer. |
| `404` | `{ "error": "not found" }` | Any path other than `/runs` and `/health`. |
| `413` | `{ "error": "request body exceeds <n> bytes" }` | Body over the runner's cap (reference default 50 MiB). |
| `422` | `{ "error": "unsupported protocol_version <n> (supported: <max>)" }` | Declared version above the runner's. Checked first. |
| `422` | `{ "error": "run_id, workflow_path and tarball_url are required" }` | A required field missing. |
| `500` | `{ "status": "error", "change_set": {…}, "artifacts": [], "logs": [], "error": "…" }` | A transport- or parse-level fault, including a body that is not valid JSON. |

See [`examples/runs-errors.json`](examples/runs-errors.json). A control plane MUST treat any
non-`2xx` answer as "not run" and MUST NOT read a `500` body as a RunResult for the run (it carries
no `protocol_version`).

### 6.2 What a runner MUST refuse or fail

Refuse (`422` / transport failure):

- `protocol_version` greater than the runner's.

Fail the run (`status: "error"`), before downloading the snapshot:

- `environment` under version < 2, or on a runner whose operator has not enabled it;
- `gateway` under version < 3, or a malformed gateway block;
- a git source under version < 4, or a write source under version < 5;
- any v6 member under version < 6, a malformed conversation, an invalid or colliding external
  tool, a malformed `limits.consumed`, or a v6 member with an engine other than `native`;
- an unknown `environment.sources[].kind`, an `environment.tools` other than `"none"`, or
  `"none"` with an engine other than `native`;
- any other malformed environment member;
- a selected provider with no usable credential (unless the operator deliberately enabled a mock
  fallback for development);
- an out-of-process engine where effective isolation is below `container`.

---

## 7. Security considerations

**The runner MUST:**

- authenticate every `POST /runs` with a constant-time comparison, and refuse to serve without a
  configured token outside an explicit local-only opt-out;
- refuse newer protocol versions instead of guessing, and fail (not ignore) any block it receives
  under a lower declared version, so a payload can never run as less than it asked;
- take the weaker of the payload's isolation claim and its own, so a payload cannot talk its way
  up to an isolation level that lets an out-of-process engine run;
- guard snapshot extraction against path traversal, and guard every payload-supplied path (git
  `path`, materialised files, skill names) against escaping the workdir;
- keep the credentials it is handed away from the agent where the protocol says so: only
  `agent_secrets` reach the engine; git `auth` rides only on the fetch request, never in
  `.git/config` (except the URL-scoped push header of [§3.4](#34-git-write-v5)); with a `gateway`
  block, no raw provider key reaches any engine;
- with a `gateway` block, never fall back to raw keys when the block is malformed;
- mask, in everything it sends back (run logs, `error`, heartbeat text, `pending_calls`,
  `messages`), the exact values of: `secrets`, `provider.credentials`, connector tokens,
  `gateway.run_token`, git source passwords, `callbacks.token`, and the worker's own callback
  token, replacing each with `[REDACTED]`. The reference runner masks longest values first and
  does not mask values shorter than 6 characters (so a trivially short value cannot shred every
  log line). This is exact-value masking, a backstop: a secret the model transformed is not
  caught;
- never send raw tool inputs, outputs or errors on a heartbeat;
- not let the engine hold the run-callback token. (In the reference microVM worker the callback
  token is read from the launcher's seed and shredded on read, and the engines run as an
  unprivileged user that cannot see the reporting process.)

**The control plane MUST:**

- send the runner token only over TLS to a runner it intends to reach;
- bind run-callback tokens to one run and one attempt, give them an expiry that covers the run,
  and answer `409` to an older attempt's callbacks, so a late result can never land on a retry;
- serve the payload (which carries secrets) only while the run is in flight, and on a microVM
  lane only once per attempt;
- apply results atomically and idempotently per attempt;
- deduplicate heartbeat events and accept them leniently: a beat is liveness, and refusing it
  helps no one;
- treat `tarball_url` as a credential: short-lived and per attempt;
- choose `isolation` honestly: it can only lower what the runner enforces, so overstating it buys
  nothing, but understating it is the safe direction;
- discard a canceled run's change set itself, whatever the runner reports.

**Trust boundary.** The payload is fully trusted by the runner (it comes from an authenticated
control plane); the snapshot content, the model's output and anything a tool returns are not.
That is why the agent phase gets fewer secrets than setup and verify: the model reads untrusted
content and can execute code with egress, so a secret in its environment is one prompt injection
from leaving.

---

## 8. Out of scope: private runs

The reference implementation has a **private-run** profile: a run whose inputs are references
into an end-to-end encrypted personal vault, executed only on the owner's own machine against a
local model, so that neither the control plane nor any cloud provider sees the content. It adds a
payload `vault` block, result members `private` (vault references, a generic status and counts)
and `error_code` (a fixed code instead of error text), and a heartbeat projection that carries
only phase codes.

That profile is tied to one vault implementation's reference format and to the operator's own
home executors, so it is not part of this public spec, and its fixtures are deliberately not
reproduced under `examples/`. For an implementer of this spec:

- a runner MUST NOT emit `private` or `error_code`;
- a runner that does not implement the profile ignores a `vault` member as unknown (the
  reference control plane never dispatches a private run to a placement other than the owner's
  own executor), except that a payload carrying both `vault` and any v6 member MUST fail the run;
- a control plane MUST NOT send a `vault` block to a runner that does not implement the profile.

---

## Examples

Every optional member is present (as a value or `null`) so a parser can be tested against the
whole shape. Values are placeholders.

| File | What |
| --- | --- |
| [`run-payload.v1.json`](examples/run-payload.v1.json) … [`run-payload.v6.json`](examples/run-payload.v6.json) | One payload per version; each adds that version's block to the one before. From v3 on, provider keys are absent and the HTTP connector points at the gateway, as the reference control plane sends a gateway-routed run. |
| [`run-accepted.json`](examples/run-accepted.json) | The `202` body. |
| [`run-result.v1.json`](examples/run-result.v1.json) | A successful result with every optional v1 member. |
| [`run-result.v6.json`](examples/run-result.v6.json) | A `suspended` result. |
| [`run-result-canceled.json`](examples/run-result-canceled.json) | A canceled result. |
| [`run-heartbeat.json`](examples/run-heartbeat.json) | A beat with one event of every type, and both answers. |
| [`run-heartbeat-steering.draft.json`](examples/run-heartbeat-steering.draft.json) | Draft: steering negotiation. |
| [`health.json`](examples/health.json) | `GET /health`. |
| [`runs-errors.json`](examples/runs-errors.json) | `POST /runs` error bodies. |

---

## Source

Derived from the code, not the prose, at these commits:

- `rarebit-one/jumpdrive-runner` at `a3ee2ae` (the runner: protocol types, HTTP server, per-run and
  microVM workers, heartbeat, result callback, redaction, environment, gateway, git sources,
  conversation, and the contract fixtures it pins);
- `@rarebit-one/harness-kernel` 0.19.1 (the version that runner resolves: `Permissions`,
  `ConnectorConfig`, message, event and outcome vocabularies);
- `rarebit-one/jumpdrive-web` at `16fb786` (the control plane: payload builder, runner client,
  warm-pool dispatch, callback endpoints, heartbeat recorder, gateway routing, steering).

Where the implementing repositories' prose and code disagree, this spec follows the code:

- The runner's README gives the `POST /runs` body cap as 4 MiB; the code defaults to 50 MiB.
- The runner's contract notes say the control plane does not send `vault` yet; it now sends it
  for every private run.
- The runner's contract notes say a `409` from `result_url` means the run already settled; the
  reference control plane answers `200` to a post for a run that is no longer running, and `409`
  only for a stale attempt.
- A `POST /runs` body that is not valid JSON is answered `500`, not `4xx`.
- The `messages` / `consumed` result members are returned when the payload carried **any** v6
  member (including `limits.consumed` or `limits.budget_visible` alone), not only `conversation`
  or `external_tools` as the type comments say.
