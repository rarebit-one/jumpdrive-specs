# Broker protocol

How a broker places work onto self-hosted machines that **dial out**: the agents on those
machines enrol, poll for work, lease it, keep the lease alive and report how it ended. The
broker never connects to an agent. It also accepts work from two job sources: GitHub Actions
`workflow_job` webhooks, and a Jumpdrive control plane submitting `jd_run` jobs.

The key words MUST, SHOULD and MAY are used as in RFC 2119.

| Section | Status |
| --- | --- |
| [Overview](#1-overview), [Concepts](#2-concepts) | stable |
| [Registration](#3-registration-and-authentication) | stable |
| [Poll protocol](#4-the-poll-protocol) (poll, ack, heartbeat, complete) | stable |
| [Offer fields for GitHub jobs](#43-offers), caches, grants, memory caps | stable |
| [VM report and named egress record](#461-the-vm-block) | stable (shape); produced only on VM-lane placements |
| [Job kind `workflow_job`](#51-workflow_job-github-actions) | stable |
| [Job kind `jd_run`](#52-jd_run-a-jumpdrive-run-in-a-microvm) (submitter API, offer call, offer block) | **draft**: implemented, ships inert |
| [Egress policy, enforce mode](#53-egress-policy) | **draft**: implemented, ships inert |
| [Protocol version negotiation](#14-versioning) | **draft**: the field is sent, nothing acts on it yet |
| [Capabilities, labels, lanes](#6-capabilities-labels-and-lanes), [placement](#7-placement) | stable |
| [Tenant isolation](#8-tenant-isolation) | stable |
| [Operator interface](#11-operator-interface) | summary only; not a wire contract |

*Draft* here means proposed: either implemented in the reference implementation but
disabled unless an operator turns it on, so nothing relies on it yet, or not implemented
at all (as marked). It may change without a version bump until it is armed.

## 1. Overview

### 1.1 Parties

| Party | Role |
| --- | --- |
| **Broker** | Decides where work runs. Holds tenants, workers, bindings, jobs and placements. Serves HTTPS and makes outbound calls to GitHub and the control plane only. |
| **Agent** (a *worker*) | A process on a build host. It enrols once, then polls the broker, runs what it is offered (a container, a microVM, or a host process) and reports the outcome. One agent belongs to exactly one broker. |
| **GitHub** (job source) | Delivers `workflow_job` webhooks. The broker mints a single-use just-in-time (JIT) runner config for each offer through the tenant's GitHub App installation. The job itself then runs between the runner and GitHub. The broker carries no build traffic. |
| **Control plane** (job source, `jd_run`, draft) | Submits `jd_run` jobs with a submitter token, reads their state, and mints the run token for each offer when the broker asks. |
| **Operator** | Creates tenants, bindings and tokens through an operator API (summarised in §11). |

**One agent, one broker.** An agent MUST NOT enrol with, or poll, more than one broker.
Brokers do not see each other's placements, so two brokers sharing one agent would both
read the same slot as free. To serve two brokers from one machine, run two agents and
split the machine's capacity between them at the OS level (separate users, cgroups or
containers).

### 1.2 Transport

- HTTPS (TLS) for every request. Request and response bodies are JSON
  (`Content-Type: application/json`), UTF-8.
- **Every worker-plane request is made by the agent.** The protocol is stateless
  request/response. The broker keeps no session and no persistent connection, so it can
  run behind a load balancer or as serverless functions, and an agent behind NAT needs no
  inbound port.
- The broker does not reject unknown fields on worker-plane bodies. The control-plane
  submission body (`POST /v1/jd-runs`) is a closed schema and rejects them (§5.2).
- Request body limits on the broker: enrol 64 KiB, poll 256 KiB, complete 64 KiB,
  `jd-runs` 64 KiB, GitHub webhook 1 MiB. An agent SHOULD bound what it reads from a
  response (the reference agent reads at most 1 MiB).
- Timestamps are RFC 3339 in UTC. Identifiers (`worker_id`, `placement_id`, `job_id`,
  `run_id`, `tenant_id`) are UUIDs, and receivers MUST treat them as opaque strings and
  path-escape them.

### 1.3 Authentication

Every credential is a bearer token in `Authorization: Bearer <token>`. Broker-issued tokens
are 32 random bytes, hex-encoded (64 characters). The broker stores only their SHA-256
digest, so it can never show one again.

| Caller → broker | Credential | Issued by |
| --- | --- | --- |
| Agent: `POST /v1/enroll` | single-use **enrolment token**, bound to one worker name, TTL ≤ 24 h (default 1 h) | operator (§3.1) |
| Agent: every other worker-plane route | long-lived **worker credential** | the broker, in the enrol response |
| Control plane: `/v1/jd-runs*` | **submitter token**, bound to one `jd_submitter` tenant | operator (§5.2.1) |
| GitHub: `POST /webhooks/github` | HMAC-SHA256 signature in `X-Hub-Signature-256` with the App's webhook secret | GitHub |
| Operator: `/v1/admin/*` | operator bearer (§11) | deployment |

| Broker → callee | Credential |
| --- | --- |
| Broker → GitHub API | the tenant's GitHub App installation token |
| Broker → control plane (`jd_run` offer, draft) | HMAC-SHA256 request signature with a shared callback secret (§5.2.4) |

### 1.4 Versioning

- The agent sends `"protocol_version": 1` on every poll. Version 1 is the only version.
- The poll is the one request whose response the agent must understand in full, which is
  why the version rides on it rather than on a path or header.
- Within version 1, compatibility is additive. A broker adds offer fields that an older
  agent ignores, and it never sends a field whose meaning an older agent could get wrong.
  Where an older agent would misread a placement, the broker does not offer it to that
  agent at all: it gates on the `agent_version` the agent reports (§6.4).
- **Receivers MUST ignore unknown JSON fields** on worker-plane messages, except where a
  section says the schema is closed.
- **Draft, not implemented:** a broker that serves a later protocol version MUST answer
  a poll declaring version 1 with a version-1 response. It MUST refuse a version it
  cannot serve with `400`. The reference broker decodes `protocol_version` but does not
  check it today.
- `expected_agent_version` on the poll response is advisory: the agent logs that it
  differs and keeps working.

## 2. Concepts

**Tenant.** The unit of attribution and isolation. It has two kinds:

- `github_org`: one GitHub App installation, identified **only** by its
  `installation_id`.
- `jd_submitter` (draft): a control plane, identified only by its submitter token.

A tenant has a `public_repository_policy` (`deny`, the default, or `allow`) and an
`active` flag.

**Worker.** One enrolled agent. It is not a machine: one machine may run several agents.
Its status is `active`, `draining` (finishes what it holds and is offered nothing new) or
`disabled`. A retired worker is `disabled` and hidden from the fleet.

**Binding.** Permission for a worker to run one tenant's jobs. A worker with no binding
for a tenant runs nothing of that tenant's (**default deny**). A binding has these
fields:

- `mode`: `shared` or `exclusive`. A worker holding an exclusive binding serves that
  tenant only.
- `repository_allowlist`: optional. Absent means every repo in the tenant.
- `public_repository_policy`: optional. Overrides the tenant's.
- `priority`: an integer, higher first.

**Job.** One unit of work from a source, `kind` = `workflow_job` or `jd_run`. Job states:
`queued`, `placed`, `running`, `completed`, `ineligible`, `unplaceable`.

**Placement.** One attempt to run one job on one worker, the thing an agent is offered.
Placement states, forward-only, with terminal states sticky:

```
pending ──ack──▶ claimed ──first heartbeat──▶ running ──▶ finished
   │                │                            │
   └── lease expires, revoke, or job settled ────┴──▶ expired | abandoned
```

A job has at most one live placement (`pending`, `claimed` or `running`) at a time.

**Lease.** Each live placement has a `lease_expires_at`. It is 60 s after the offer while
`pending`, and 2 min after each ack or heartbeat. A placement whose lease passes is
expired by the broker's reaper, which then decides whether the job is re-queued (§9).

## 3. Registration and authentication

### 3.1 Enrolment token (operator)

`POST /v1/admin/enrollment-tokens` with the operator bearer:

| Field | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `worker_name` | string | yes | The only name this token can enrol. A token not bound to a name would be a capability to enrol any machine. |
| `ttl_seconds` | integer | no | Lifetime. A value ≤ 0 or above 86 400 is replaced by 3 600. |

`201`: `{token, worker_name, expires_at}`. The raw token is returned once.
Examples: [`enrollment-token-request.json`](examples/enrollment-token-request.json),
[`enrollment-token-response.json`](examples/enrollment-token-response.json).

### 3.2 `POST /v1/enroll`

Bearer: the enrolment token. Body: a **Capabilities** object (§6.1). `name`, `os` and
`arch` are required. `name` MUST equal the token's `worker_name`.

`201 Created`:

| Field | Type | Meaning |
| --- | --- | --- |
| `worker_id` | string (uuid) | The worker's id. Used in the poll path. |
| `token` | string | The worker credential. Returned exactly once. The agent MUST persist it with owner-only permissions and use it for every later request. |
| `poll_after_ms` | integer | When to make the first poll (currently `1000`). |

Errors:

- `400`: malformed body, missing `name`/`os`/`arch`, or an unknown `container_runtime`
  (`{"error": "..."}`).
- `401` (no body): no bearer, or a token that is unknown, used, expired or bound to a
  different name. The four cases are deliberately indistinguishable.

An agent MUST treat a `201` without `worker_id` or `token` as a failure.

Enrolment always creates a new worker. **An agent MUST NOT re-enrol to upgrade itself**:
two worker rows for one agent would let the broker count the same slots twice. Re-enrol
only a genuinely new agent. To bring a retired worker back, an operator reactivates it.

Examples: [`enroll-request.json`](examples/enroll-request.json),
[`enroll-response.json`](examples/enroll-response.json).

### 3.3 Worker credential

The worker credential authenticates `poll`, `ack`, `heartbeat` and `complete`. A
credential that is unknown, revoked or expired gets `401`.

- On the poll, the `{id}` in the path MUST be the credential's own worker, or the broker
  answers `403`. A worker can never act for another by changing the URL.
- On the placement routes, a placement that is not this worker's is indistinguishable from
  one that is no longer live: both get `409`.

An agent that receives `401` or `403` MUST stop polling and fail loudly rather than retry.
Waiting never fixes a credential, and retrying looks like credential stuffing.

## 4. The poll protocol

```
agent                                   broker
  │ POST /v1/workers/{id}/poll  ───────▶  refresh capabilities, reconcile `running`,
  │                             ◀───────  select + lease jobs, mint credentials
  │ {placements, revoke, poll_after_ms}
  │
  │ for each placement:
  │ POST /v1/placements/{p}/ack ───────▶  pending → claimed, lease 2 min
  │   start the work
  │ POST …/{p}/heartbeat  every 15 s ──▶  → running, lease 2 min; may say cancel
  │   work ends
  │ POST …/{p}/complete  ──────────────▶  record outcome (first report wins)
```

### 4.1 `POST /v1/workers/{id}/poll`

The poll is both the agent's heartbeat as a worker and its request for work. Each poll
refreshes the stored capabilities, so a host whose hardware changed converges without
re-enrolling.

Request body ([`poll-request.json`](examples/poll-request.json)):

| Field | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `protocol_version` | integer | yes | `1`. |
| `capacity_free` | integer ≥ 0 | yes | Upper bound on how many new placements this poll may return, across both slot classes. The broker splits it by class itself. |
| `running` | array of string | yes | Every placement id this agent is executing now. MUST be `[]`, never `null`, when there are none: the broker reconciles against this list. |
| `image_digests` | array of string | yes | Image digests present locally (`sha256:…`). Informational. `[]` when none or not applicable. |
| `disk_free_pct` | integer | yes | Free disk on the agent's state volume, 0–100, counting root-reserved blocks as used. `-1` means cannot measure. |
| `mem_available_mb` | integer | no | Memory a new job could use now: the smaller of host-available memory and the room left under every enclosing cgroup limit. `-1` or absent means cannot measure, which never holds work back. |
| `cpu` | object | no | CPU admission budget, below. Absent means not reported, never "zero cores". |
| `capabilities` | object | yes | Capabilities (§6.1). |

`cpu` object:

| Field | Type | Meaning |
| --- | --- | --- |
| `free_cores` | number ≥ 0 | Cores still spendable: `total_cores − max(load1, cores reserved by running placements)`. |
| `total_cores` | number > 0 | `cores × target load per core`. |
| `regular_cores` | number > 0 | Cost of one regular placement. |
| `heavy_cores` | number > 0 | Cost of one heavy placement (one that declares a memory class). |

A `cpu` object whose `total_cores`, `regular_cores` or `heavy_cores` is not positive is
ignored, as if it were absent.

Response `200` ([`poll-response.json`](examples/poll-response.json)):

| Field | Type | Meaning |
| --- | --- | --- |
| `placements` | array of Offer | Work leased to this agent, each `pending` with a 60 s lease (§4.3). May be empty. |
| `revoke` | array of string | Ids from the request's `running` that the broker no longer considers live (expired, finished, abandoned, or the job was revoked). The agent MUST stop each one and SHOULD report it with phase `revoked`. |
| `poll_after_ms` | integer | When to poll next: `500` while work is flowing, `5000` when idle, `30000` when the worker is draining or disabled. |
| `expected_agent_version` | string | Advisory (§1.4). |

The agent MUST process `revoke` **before** `placements`, so a slot freed by a revoke
can take a new placement in the same response.

A worker that is not `active` gets no placements, but its poll still refreshes
capabilities and returns `revoke`.

Poll errors:

- `400`: malformed body, or a `capabilities.container_runtime` the broker does not model.
  The agent's configuration is wrong, and it should stop rather than run jobs some way the
  broker does not know about.
- `401`/`403`: see §3.3.
- `500`: transient. Retry with backoff.

#### Pacing

The agent obeys `poll_after_ms`, clamped to **[500 ms, 60 s]**. After a failed poll:

- On a response with `Retry-After` (delta-seconds or HTTP-date), wait that long, clamped
  to 60 s.
- Otherwise use exponential backoff from 2 s to 60 s with ±20 % jitter. Without jitter, a
  broker restart synchronises the whole fleet.

`408`, `429` and `5xx` are retryable. Every other `4xx` is not. The reference agent uses a
5 s connect timeout and a 20 s whole-request timeout.

### 4.2 Capacity the broker respects

On each poll the broker places at most `min(capacity_free, max-per-poll)` jobs (default 2
per poll; an operator may set 0 for no per-poll cap). Within that limit it also respects:

- **Disk floor.** If `disk_free_pct ≥ 0` and below the broker's floor (default 20 %), the
  worker gets nothing new.
- **Slot classes.** A worker with `heavy_slots > 0` has two pools: `max_concurrency`
  regular slots and `heavy_slots` heavy ones. A heavy job never takes a regular slot, and
  the reverse also holds. Heavy jobs are capped per *host*, counted across every agent
  reporting the same `host`. A worker reporting `heavy_slots` 0 has one shared pool, and
  heavy jobs in it are capped by a broker-wide per-host limit (default 1).
- **Live memory.** A heavy job is placed only if `mem_available_mb` covers its class plus
  a reserve (default 1024 MB), unless the agent cannot measure.
- **CPU.** Jobs are taken in queue order, each spending its class's cost from `free_cores`.
  The first job that does not fit holds its cores: nothing queued behind it is placed on
  that worker in that poll. There are two exceptions. A job costing more than
  `total_cores` holds nothing. A worker running nothing always gets one job, whatever it
  costs.
- **Per-host lane caps.** VM-lane jobs default to 1 per host, and `jd_run` to 1 per host
  inside that.

### 4.3 Offers

An offer is one element of `placements`. An agent MUST NOT start work for an offer it has
not acked (§4.4).

| Field | Type | Present | Meaning |
| --- | --- | --- | --- |
| `placement_id` | string (uuid) | always | Placement id, used in the ack, heartbeat and complete paths. |
| `kind` | string | `jd_run` only | `"jd_run"`, or absent/`"workflow_job"` for a GitHub runner. The broker currently omits it for GitHub runners, so an agent MUST read an absent `kind` as `workflow_job`. |
| `runner_name` | string | always | The placement's runner/slot name, unique across the instance. `workflow_job`: `<prefix><workflow_job_id>-<attempt>`. `jd_run`: `<prefix>jdrun-<run_id>-<run attempt>-<placement attempt>`. The prefix is per broker instance. |
| `jit_config` | string (secret) | `workflow_job` | The GitHub JIT runner config, a bearer credential for the tenant's runner fleet (§10). MUST NOT appear on a `jd_run` offer. |
| `image` | string | always | Image reference, pinned by digest (`…@sha256:<hex>`). |
| `timeout_seconds` | integer | always | Hard wall-clock limit (default 3600). The agent stops the work when it passes and reports `deadline_exceeded`. |
| `lease_expires_at` | string (RFC 3339) | always | When the pending lease ends. Ack before this. |
| `memory_mb` | integer | heavy and `jd_run` | The job's memory class. A container runs under a memory limit of this size. **Its presence makes the placement heavy** for slot accounting. |
| `memory_cap_mb` | integer | regular, when armed | A memory limit for a *regular* placement that does not make it heavy. Never sent together with `memory_mb`; if both arrive, `memory_mb` wins. |
| `cache_volumes` | object string→string | when armed | Logical cache name → shared volume name. Mounted at `/cache/<name>`: the agent derives the path, the broker never sends one. |
| `cache_volume_scheme` | integer | with `cache_volumes` | How the volumes are named: `2` = `<owner>--<repo>`. Absent means the legacy naming. |
| `env` | object string→string | with `cache_volumes` | Extra environment for the job. Passed by value-free inheritance, never on argv (§10). |
| `leased_caches` | array | when armed | Caches held by one container at a time: `{name, volume, env}`. The agent mounts `<volume>-<k>` for the lowest `k` none of its running containers holds, and applies `env` **only** when it mounts. |
| `shared_caches` | array | VM lane, when armed | `{name, volume}`. Mountable by several containers at once. Applied only to a `vm`-granted placement. |
| `grants` | array of string | grant lanes | Extra capabilities from the closed set `kvm`, `build`, `vm` (§6.3). |
| `vcpus` | integer | `jd_run` | Guest vCPUs. |
| `jd_run` | object | `jd_run` | `{run_id, attempt, url, token}` (§5.2.5). |
| `egress` | object | `jd_run`, when the run sent one | The egress policy the broker decided (§5.3). |

The agent validates names it is told to mount. A cache `name` MUST match
`^[a-z][a-z0-9_-]{0,31}$`. A leased base volume MUST match `^jdb-[a-z0-9][a-z0-9_.-]{0,180}$`,
and a shared volume `^jdb-docker-[a-z0-9][a-z0-9_.-]*--(main|pr)$`. An `env` key MUST be a
portable variable name. An agent SHOULD refuse an offer that breaks these rules.

**An offer the agent cannot honour exactly is refused, never run differently.** After
acking, the agent reports `infra_error` with a fixed note when any of these hold:

- the offer names a grant the host is not armed for;
- its kind is one the agent is not armed for;
- a `jd_run` has no token, carries a `jit_config`, or is not `vm`-granted;
- its egress policy does not parse;
- an `enforce` policy cannot be carried.

An agent MUST NOT drop a grant or a policy and run anyway.

**Image gate.** A runtime that uses images SHOULD NOT pull an image inline. If the digest
is not present locally, the agent acks, reports `image_missing` with
`container_exit: -1`, and pulls in the background so the next offer succeeds. The broker
then re-places the job.

### 4.4 `POST /v1/placements/{id}/ack`

Body `{}`. Turns the offer into a lease the agent owns: `pending → claimed`, lease = now +
2 min. It must be the agent's own placement, still `pending`.

- `200`: `{lease_expires_at, poll_after_ms}` ([`ack-response.json`](examples/ack-response.json)).
- `409 {"cancel": true}` ([`lease-conflict.json`](examples/lease-conflict.json)): not live,
  not pending, or not this worker's. **Stop. Do not retry, and do not start the work.**

The reference agent acks before the image check, so even an `image_missing` report lands
against a claimed placement.

### 4.5 `POST /v1/placements/{id}/heartbeat`

Body `{}`. Sent every 15 s while the work runs. The first heartbeat moves `claimed →
running`. Each one sets lease = now + 2 min.

- `200 {lease_expires_at, poll_after_ms, cancel}`
  ([`heartbeat-response.json`](examples/heartbeat-response.json)). `cancel: true` means
  stop now. Nothing can dial in to the host, so this is the broker's only in-band way to
  stop work.
- `409 {"cancel": true}`: the placement is no longer live. The agent SHOULD stop. The
  reference agent treats a `409` heartbeat as a failed heartbeat and stops when the next
  poll lists the placement in `revoke`.

A failed heartbeat (network error, `5xx`) MUST NOT by itself stop the work. Tearing down
every job on a short broker outage is worse than a lease that expires and is reconciled.

### 4.6 `POST /v1/placements/{id}/complete`

Reports how the placement ended, as the agent saw it. The **first report wins**: it is
accepted whatever the placement's state, because GitHub's completion often reaches the
broker first. A repeat gets `409`.

Request ([`complete-request.json`](examples/complete-request.json)):

| Field | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `phase` | string | yes | Phase, below. |
| `container_exit` | integer | yes | Exit status, or `-1` where nothing ran (unclaimed, image missing, refused, orphan). |
| `oom_killed` | boolean | yes | The container was killed for exceeding its memory limit. |
| `memory_peak_mb` | integer | no | Peak memory. `0` means not measured. |
| `started_at` | string (RFC 3339) | no | When work started. The reference broker ignores it. |
| `ended_at` | string (RFC 3339) | no | When the agent stopped the work, by its own clock. The broker clamps it into [claim time, now]. |
| `image_digest` | string | no | Digest actually run or missing. |
| `error` | string | no | A short note **written by the agent**. It MUST NOT be copied from the job's output, which can contain anything, including the job's own credentials. |
| `vm` | object | no | VM-lane summary (§4.6.1). Omitted for every other placement. |

`phase` values:

| Phase | Meaning |
| --- | --- |
| `completed` | The work ran to completion. Says nothing about whether the job passed. For `workflow_job`, GitHub owns that verdict. |
| `deadline_exceeded` | The agent stopped it at `timeout_seconds`. |
| `unclaimed` | Offered but never started, for example no free slot. |
| `infra_error` | Something on the host failed: launch failure, refused offer, agent shutdown, an orphan found at start-up. A runner that exits within seconds without taking a job reports `infra_error` with an `error` starting `runner_exited_before_job`. |
| `image_missing` | The image digest is not present locally (§4.3). |
| `revoked` | The broker revoked the placement and the agent stopped it. Neither a host failure nor a completion. |

The broker stores unknown phases as sent. It reads an older agent's `completed` with
`error: "revoked by broker"` as `revoked`.

- `200 {"status":"ok"}` ([`complete-response.json`](examples/complete-response.json)).
- `409 {"status":"already terminal"}` ([`complete-conflict.json`](examples/complete-conflict.json)):
  this placement already has a report, or it is not this worker's. **Drop the report; do
  not retry.**
- `5xx`, network error: keep the report and retry later.

An agent MUST write each report durably (for example to a spool file, fsynced, owner-only)
**before** sending it, and re-send spooled reports after a restart. It deletes the spooled
copy only on `200` or `409`.

For a `jd_run` (draft) the report **is** the verdict: it finishes the placement and
completes the job. The conclusion is `success` when `container_exit` is 0, the phase is
`completed` and there is no `error`, and `failure` otherwise.

#### 4.6.1 The `vm` block

This block is sent only for a placement that ran in a microVM (`vm` grant). The agent reads
it from a file written inside the job's container, so **the broker trusts nothing in it
beyond its types**.

| Field | Type | Meaning |
| --- | --- | --- |
| `boot_ms` | integer | Guest boot time. |
| `guest_mem_mb` | integer | Guest memory. |
| `cache_generation` | integer | Docker cache generation (`0` = cold). |
| `egress_names` | integer | Distinct names resolved. |
| `egress_dests` | integer | Distinct destinations. |
| `egress_bytes` | integer | Bytes sent. |
| `egress_record` | object | Named egress record, below. Omitted by older launchers. |

`egress_record`:

| Field | Type | Meaning |
| --- | --- | --- |
| `names` | array of `{name, queries, would_block?}` | Up to 64 names resolved through the launcher's forwarder. `name` MUST match `^[a-z0-9.-]{1,253}$`. `would_block` is true for a name the job's policy would refuse. |
| `names_overflow` | integer | Names beyond 64, or cut to keep the report within 16 KiB. |
| `invalid_names` | integer | Names that failed the character rule. |
| `dests` | array of `{ip, proto, port, bytes, name?}` | Up to 64 destinations by bytes. IPv4 only, `proto` `tcp`/`udp`. `name` is empty for an address never resolved through the forwarder, that is, a raw-IP connection. |
| `mode` | string | Egress mode the launcher **actually ran**: `observe`/`enforce`. Empty means the launcher had no policy. |
| `refused` | integer | Queries answered `REFUSED` in enforce mode. |

The broker bounds every value before storing it. A value out of range is stored as
null, an entry that breaks a rule is dropped and counted, and the report file is capped
at 16 KiB. Names are guest-controlled, so anything that renders them MUST escape them.

## 5. Job kinds and sources

### 5.1 `workflow_job` (GitHub Actions)

**Ingress.** `POST /webhooks/github`, GitHub's `workflow_job` event, verified with
`X-Hub-Signature-256` (HMAC-SHA256 over the raw body, compared in constant time) before
anything is parsed.

| Status | When |
| --- | --- |
| `202` | Processed, or not a `workflow_job` event, or not addressed to this instance. |
| `400` | Payload does not decode. |
| `401` | Missing or wrong signature. |
| `413` | Body over 1 MiB. |
| `500` | Handling failed. GitHub may redeliver, and handling is idempotent on `workflow_job.id`. |
| `503` | The broker has no webhook secret configured. Unsigned payloads are never accepted. |

**Tenant attribution** comes only from `installation.id`. An org name in the payload is
never trusted. An unknown installation is ignored.

**`queued`.** The broker only considers a job whose `runs-on` contains one of its
**routing labels**. Each broker instance configures these: one default label, plus one
each for the macOS, heavy and grant lanes. From the raw `runs-on` the broker derives the
job's requirements:

| `runs-on` token (case-insensitive, exact) | Effect |
| --- | --- |
| a routing label | selects this broker; not a requirement |
| `self-hosted` | dropped |
| `linux`, `ubuntu-latest`, `ubuntu-*` | `os = linux` |
| `macos`, `macos-*` | `os = darwin` |
| `windows`, `windows-*` | `os = windows` |
| `x64`, `amd64` / `arm64`, `aarch64` | `arch = amd64` / `arm64` |
| anything else | a required capability label |

A job's `os` is set by these rules, in order:

- no OS token and the macOS routing label present: `darwin`;
- no OS token otherwise: `linux`;
- the heavy routing label adds a memory class;
- a grant lane label adds that grant's capability label `jdb-grant-<g>` and the lane's
  memory class.

The broker refuses a job at once (red, see below) when:

| Reason | When |
| --- | --- |
| `tenant_paused` | The tenant is not active. |
| `public_repository` | The repo is public and the effective policy is `deny`. |
| `reserved_label` | `runs-on` names a `jdb-grant-*` label itself. Only a worker may advertise one. |
| `lane_combined` | A grant lane label is combined with any other label. It must be the whole `runs-on`, because GitHub hands a runner any job whose labels are a subset of its own. |
| `lane_not_armed` | The org is not armed for the requested grant lane. |
| `no_capable_worker`, `heavy_excluded_host`, `agent_below_lane_minimum` | No worker could **ever** run it (§7.2), ignoring whether one is online now. |

A refused job is recorded and, for GitHub, gets a failing check run naming the reason.
A job that merely has to **wait** stays queued (§9).

**Minting.** For each `workflow_job` offer, the broker resolves the instance's runner group
and **verifies the group admits the repository**: a runner in a group that does not
admit the repo registers and is never given the job. Only then does it mint a JIT config,
labelled with the job's **raw** `runs-on`. GitHub dispatches only to a runner carrying
every label as literally written. A mint failure withholds the offer: it is dropped from
the poll response, and its pending lease re-places it.

**`in_progress` and `completed`.** The broker matches these by `runner_name`. A JIT runner
is not bound to one job: GitHub gives queued work to any matching runner. So the job
recorded on the placement is corrected to the one GitHub reports. GitHub's `completed`
event finishes the placement with GitHub's conclusion, and the agent's report
corroborates it. Events for runners this instance did not mint never touch its
placements.

**Retries.** The broker owns them: an expired placement re-queues the job (§9).

### 5.2 `jd_run`: a Jumpdrive run in a microVM

**Status: draft (implemented, ships inert).** A `jd_run` is one attempt of one control-plane
run, placed only on the VM lane. It has no GitHub side effects of any kind.

#### 5.2.1 Submitter tenant and token (operator)

The operator does three things:

1. Creates a tenant with `POST /v1/admin/tenants {"kind": "jd_submitter"}`.
2. Binds workers to it.
3. Issues a token with `POST /v1/admin/submitter-tokens {"tenant_id": "<uuid>"}`.

The issue call returns `201 {token, tenant_id, prefix, note}`, shown once. It returns
`404` if no `jd_submitter` tenant has that id, and `409` on a conflict. Examples:
[`submitter-token-request.json`](examples/submitter-token-request.json),
[`submitter-token-response.json`](examples/submitter-token-response.json). The tenant must
also be armed on the broker, and only tenants the operator lists may submit.

#### 5.2.2 `POST /v1/jd-runs`

Bearer: submitter token. Unknown, wrong and inactive-tenant tokens all get `401` with
`WWW-Authenticate: Bearer realm="jd-runs"` and no detail.

The broker checks the arming gate **on the authenticated tenant**, before it reads the
body. It never uses `org_ref` for this.

Body, a **closed schema** where an unknown field is `400 unknown_field`
([`jd-run-submit-request.json`](examples/jd-run-submit-request.json)):

| Field | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `run_id` | string (uuid) | yes | The control plane's run id. |
| `attempt` | integer ≥ 1 | yes | The control plane's attempt number. |
| `org_ref` | string, non-empty | yes | Opaque attribution for reports. Never interpreted. |
| `size` | string | yes | Size enum. Only `standard` is accepted. The broker maps it to memory (default 4096 MB) and vCPUs (default 2). The submitter never names numbers. |
| `egress` | object | no | Egress policy (§5.3). Absent means observe with no list. |

`(tenant, run_id, attempt)` is unique, and **a repeat submission is idempotent**: it
returns the original row with the same `202`.

`202 Accepted` ([`jd-run-submit-response.json`](examples/jd-run-submit-response.json)):
`{job_id, run_id, attempt, state: "queued"}`.

| Status | `error` | When |
| --- | --- | --- |
| `400` | `unknown_field`, `malformed json`, `run_id must be a uuid`, `attempt must be >= 1`, `org_ref is required`, `size is required`, `unknown size`, `egress.allow exceeds the 64-entry limit`, `egress policy rejected` | Invalid body. Never retry unchanged. |
| `401` | (none) | Authentication. |
| `409` | `lane_not_armed` | The tenant is not armed ([`jd-run-refusal.json`](examples/jd-run-refusal.json)). |
| `409` | `no_capable_worker` | No worker could ever run a `jd_run` for this tenant. A capable but busy worker means the job waits. |
| `500` | (none) | Transient. |

#### 5.2.3 `GET /v1/jd-runs/{run_id}` and `DELETE /v1/jd-runs/{run_id}`

Both are scoped to the authenticated tenant. Another tenant's run is `404`, the same as
one that does not exist. A malformed `run_id` is `400`.

`GET` returns the most recent attempt
([`jd-run-status-response.json`](examples/jd-run-status-response.json)):

| Field | Type | Present | Meaning |
| --- | --- | --- | --- |
| `job_id` | string | always | Broker job id. |
| `run_id`, `attempt` | string, integer | always | As submitted. |
| `state` | string | always | Job state (§2). |
| `reason` | string | always | `""`, or why the job is terminal without a run: `lane_disarmed`, `offer_refused`, `lease_expired_after_ack`, `revoked`, `attempts_exhausted`, `placement_deadline`, `queue_ceiling`. |
| `attempts` | integer | always | Placements made for this attempt so far. |
| `conclusion` | string | when completed | `success` or `failure`. |
| `vm_report` | object | once reported | The `vm` block (§4.6.1). Fields are null where unknown. |
| `egress_mode_effective` | string | once offered with a policy | `observe` or `enforce`: what the broker **offered** (§5.3). |
| `egress_mode_reason` | string | on a downgrade | `tenant_not_armed`, `agent_too_old` or `policy_invalid`. |

`DELETE` revokes every non-terminal attempt of the run. The job becomes `unplaceable`
with reason `revoked`. A live placement expires, and the worker's next poll lists it in
`revoke`. It is idempotent. The response is `200 {run_id, state: "revoked", note}`
([`jd-run-delete-response.json`](examples/jd-run-delete-response.json)).

#### 5.2.4 Broker → control plane: minting the run token

The run token is minted **at offer time by the control plane** and never stored by the
broker. When a poll is about to offer a `jd_run`:

`POST {cp}/api/v1/broker/runs/{run_id}/offer`
([`cp-offer-request.json`](examples/cp-offer-request.json)):

| Field | Type | Meaning |
| --- | --- | --- |
| `attempt` | integer | The run attempt being offered. |
| `placement_id` | string | Attribution for the control plane's audit. |
| `host` | string | The worker's reported host. Attribution only. |

The control plane MUST NOT trust `placement_id` or `host` for anything but audit.

Headers:

```
X-Jdb-Timestamp: <unix seconds>
X-Jdb-Signature: v1=<lower-hex HMAC-SHA256(secret, "<ts>.<METHOD>.<escaped path>." || body)>
```

The control plane MUST compare the signature in constant time and MUST reject a timestamp
outside a short skew window (five minutes), so a captured request cannot mint a token
later. The `v1=` prefix versions the scheme.

The control plane SHOULD mint only when the run is running, it is placed on the VM
backend, and the attempt is current.

| Response | Broker action |
| --- | --- |
| `2xx {token, expires_at, callback_url?}` ([`cp-offer-response.json`](examples/cp-offer-response.json)) | Offer it. `callback_url` is the base the guest uses to reach the control plane when it differs from the one the broker called. Empty means the same. |
| `404`, `409`, `410`, `422` with `{error?, reason?}` ([`cp-offer-refusal.json`](examples/cp-offer-refusal.json)) | **Refusal**: the job is settled `unplaceable` with reason `offer_refused`. Retrying cannot help. |
| any other status, a `2xx` without `token`, a body that does not decode, a timeout (10 s), a transport error | **Withhold**: the offer is dropped from this poll, and its pending lease re-places the job. |

The broker follows no redirects. A signed mint sent wherever a `3xx` points would hand
a token to an unconfigured host. The control-plane base URL is `https`; plain `http` is
allowed only to a loopback host.

Before minting, the broker re-checks that the tenant is still armed. A tenant disarmed
after submission settles the job with `lane_disarmed`.

#### 5.2.5 The `jd_run` offer and its lifecycle

The offer carries these fields (§4.3):

- `kind: "jd_run"`, `runner_name`, `image`, `timeout_seconds`, `lease_expires_at`;
- `memory_mb`, `vcpus`, and `grants: ["vm"]`;
- `jd_run`, below;
- `egress`, when the run sent a policy.

It never carries `jit_config`.

`jd_run` object:

| Field | Type | Meaning |
| --- | --- | --- |
| `run_id` | string (uuid) | The run. |
| `attempt` | integer | The run attempt. |
| `url` | string | The control-plane base URL for the guest. |
| `token` | string (secret) | The attempt-bound run token. |

Agent rules:

- Only an agent that reports `agent_version` ≥ 0.9.0 and advertises both
  `jdb-grant-vm` and `jdb-kind-jdrun` is ever selected. The broker strips
  `jdb-kind-jdrun` from an older or unparseable agent's labels before storing them.
- The agent refuses (`infra_error`) the offer in these cases: it is not armed for
  `jd_run`; there is no token; there is a `jit_config`; `vm` is not granted; or
  `memory_mb − 1024` is below 1024. The guest gets `memory_mb` less 1 GiB for the VMM.
- The token reaches the job by inherited environment and the guest seed. It never goes on
  argv or a kernel command line.

**Retries belong to the control plane.** The broker re-places a `jd_run` only **before
ack**. If a lease expires **after** ack, the job is settled with `lease_expired_after_ack`,
because the guest may already have spent real resources. The agent's report finishes it
(§4.6). The control plane decides whether a new attempt follows, and submits it with a
new `attempt` number.

### 5.3 Egress policy

**Status: draft (implemented, ships inert).** One parser serves every hop (ingress, offer,
agent, launcher), so what the broker accepted is exactly what is enforced.
[`egress-policy.json`](examples/egress-policy.json).

```json
{ "mode": "observe" | "enforce", "allow": ["<entry>", …] }
```

- **Closed schema.** Unknown fields, trailing data, or more than 16 KiB serialized are
  rejected. An empty `mode` means `observe`.
- `allow` has at most **64** entries, with no duplicates after canonicalisation. Each
  entry is case-folded and is one of:
  - `host` (port 443);
  - `host:port` (1–65535);
  - `*.host[:port]`, which matches exactly **one** label under `host`.
- An entry is a **name, never an address**. Each label is 1–63 bytes of letters, digits or
  hyphens, with no leading or trailing hyphen, at least two labels, and 253 bytes in all.
  A wildcard needs at least two labels under it. **Port 53 is always refused**, because
  the guest's only resolver is the launcher's forwarder.
- The broker stores and offers the policy in canonical form: lower case, `:443` omitted.

**Enforce applies only when both sides opt in:** the submission asks for `enforce`, **and**
the broker lists the tenant for enforcement, **and** the worker's agent is ≥ 0.9.1.
Otherwise the offer carries the same list with `mode: "observe"`, and the downgrade is
recorded as `egress_mode_effective`/`egress_mode_reason`. It is never silent.

In enforce mode the launcher behaves as follows:

- It answers DNS only for allowed names. Everything else gets `REFUSED`, and only `A`
  queries are relayed.
- It pins answered addresses into an allow set before replying.
- It forwards in this order: LAN drop first, then established, then the pinned set, then
  drop.
- It also allows the run's own control-plane host and port.

A placement offered `enforce` whose report's `egress_record.mode` is not `enforce` is
logged as an error by the broker: an older launcher image enforces nothing. An agent that
receives an `enforce` policy it cannot carry MUST refuse the placement rather than run it
in observe mode.

## 6. Capabilities, labels and lanes

### 6.1 Capabilities object

The agent sends this at enrolment and on every poll
([`enroll-request.json`](examples/enroll-request.json)):

| Field | Type | Req. | Meaning |
| --- | --- | --- | --- |
| `name` | string | yes | Worker name. At enrolment it must equal the token's `worker_name`. |
| `host` | string | yes | The machine's hostname. **First non-empty report wins.** Later changes are ignored, so an agent cannot relocate where its work is attributed. Empty never overwrites. |
| `os` | string | yes | `runtime.GOOS`-style: `linux`, `darwin`, … |
| `arch` | string | yes | `amd64`, `arm64`, … |
| `cpus` | integer | yes | Logical CPUs. |
| `memory_mb` | integer | yes | Total memory. A job's class must fit within it. |
| `has_kvm` | boolean | yes | `/dev/kvm` is openable. |
| `container_runtime` | string | yes | How work executes: `podman` (containers, kernel-enforced limits) or `host` (a process on the machine, macOS only). Empty means an older agent and is read as `podman`; anything else is refused. |
| `labels` | array of string | yes | Capability labels (§6.2). |
| `max_concurrency` | integer | yes | Regular slots. A value ≤ 0 is ignored, and the previous value is kept. |
| `heavy_slots` | integer | no | Heavy slots on top of `max_concurrency`. Absent or 0 means a shared pool. |
| `cpus_per_job` | number | no | The per-container CPU quota the agent applies. Report-only. |
| `heavy_opt_out` | boolean | no | The host takes no heavy-lane job. Absent means accepts. |
| `agent_version` | string | yes | Semver of the running agent, overwritten on every poll, empty included. Lane gates compare it (§6.4). |
| `host_runner_version` | string | no | On a `host`-runtime worker, the staged runner version (`MAJOR.MINOR.PATCH`). Report-only. Malformed values are dropped. |

### 6.2 Labels

A worker advertises labels, and a job requires labels. A worker can take a job only if it
advertises **every** label the job requires (§7.1). Three kinds of label have protocol
meaning:

- **Ordinary capability labels** are free-form, set by the host's operator, and matched
  exactly.
- **Grant labels `jdb-grant-<g>`** (`kvm`, `build`, `vm`) are the worker's statement that
  its host is armed for grant `g` and can honour it now. For example, the `kvm` label is
  advertised only while `/dev/kvm` opens, and `vm` only while the VM devices open.
  **Reserved:** a job source may not ask for one directly (`reserved_label`).
- **Kind label `jdb-kind-jdrun`** means the host is armed for `jd_run`. It is advertised
  only alongside `jdb-grant-vm`, and admitted only from agent ≥ 0.9.0.

### 6.3 Grants

A grant gives the job container something the default container (rootless, capabilities
dropped, no devices) lacks. The set is **closed**, and the agent fixes what each grant adds.
The broker only ever names a grant, never flags.

| Grant | The container also gets |
| --- | --- |
| `kvm` | `/dev/kvm`. The job is heavy-class. |
| `build` | A standard capability set for nested multi-uid image builds. Still no `SYS_ADMIN`, devices, seccomp or `/proc` changes. |
| `vm` | The job runs in its own microVM, launched inside the container. Heavy-class at the VM lane's memory class. |

A grant reaches a job only when three independent things hold:

1. the job asked for the lane;
2. the job's tenant is armed for it on the broker;
3. the host is armed for it on the agent, which is how it comes to advertise the grant
   label.

A tenant disarmed after a job queued stops the grant at the next offer. That placement is
withheld and expired, not sent without its grant.

### 6.4 Lanes and agent-version gates

Every job is on one or more **lanes**, decided from its requirements:

1. on each grant lane whose `jdb-grant-*` label it requires;
2. else `macos` if `os = darwin`;
3. else `heavy` if it declares a memory class;
4. else `linux`.

An operator MAY set a minimum agent version per lane. A worker whose `agent_version` is
below its lane's minimum, **or is empty or unparseable**, is not eligible: version gates
fail closed. Versions are `MAJOR.MINOR.PATCH`, optionally prefixed `v`, with a semver
pre-release (ordered per semver) and an optional build suffix (ignored).

Built-in gates (not configurable):

| Gate | Minimum |
| --- | --- |
| Selected for `jd_run` | 0.9.0 |
| `enforce` egress offered | 0.9.1 |
| `memory_cap_mb` honoured | 0.8.5. The broker still sends the field, so an older agent runs uncapped. |

## 7. Placement

### 7.1 The predicate

The broker decides one (job, worker) pair with these checks, in order. Each denial has
exactly one machine-readable reason. Eligibility is **static**: it ignores whether the
worker is online or busy.

| # | Rule | Reason on denial |
| --- | --- | --- |
| 1 | Worker status is `active`. | `worker_not_ready` |
| 2 | Tenant is active. | `tenant_inactive` |
| 3 | The worker holds no exclusive binding to a *different* tenant. | `exclusive_to_other_tenant` |
| 4 | The worker has a binding for the job's tenant. | `no_binding` |
| 5 | The repo is in the binding's allowlist, if it has one. | `repo_not_in_allowlist` |
| 6 | A public repo needs an effective policy (binding, else tenant, else `deny`) of `allow`. | `public_repository` |
| 7 | The job's `os` and `arch`, when set, equal the worker's (case-insensitive). | `os_mismatch`, `arch_mismatch` |
| 8 | The worker advertises every required label. | `label_missing` |
| 9 | A `darwin` job needs `container_runtime = host`. A Mac running containers executes Linux. | `runtime_mismatch` |
| 10 | A job needing KVM needs `has_kvm`. | `kvm_unavailable` |
| 11 | The job's memory class ≤ the worker's `memory_mb`. | `insufficient_memory` |
| 12 | A heavy-lane job (memory class, no grant) is not placed on a worker with `heavy_opt_out`. | `heavy_excluded_host` |
| 13 | The agent meets the minimum for each of the job's lanes. | `agent_below_lane_minimum` |

The broker re-checks rule 6 at placement time, not only at ingress, so a policy that is
tightened takes effect at once. A `jd_run` requires `os = linux` and the labels
`jdb-grant-vm` and `jdb-kind-jdrun`.

### 7.2 Waiting versus unplaceable

At ingress, and again whenever the fleet changes, the broker asks whether **any** worker,
online or not, could ever pass the predicate:

- If none could, the job is unplaceable at once, with reason `no_capable_worker`. The
  reason is `heavy_excluded_host` or `agent_below_lane_minimum` instead when lifting only
  that exclusion would make it reachable.
- If one could, the job waits.

A job that waits too long is made unplaceable by the time limits in §9.

### 7.3 Selection on a poll

Among jobs the polling worker is eligible for, the broker:

- applies the transient gates of §4.2;
- skips a job whose placement on **this** worker expired within the re-placement
  cooldown (default 10 min). This is a cooldown, not a ban, so a lane with one worker
  still retries;
- briefly defers a fresh job (for its first 15 s) to an emptier capable peer that polled
  recently, so workers of different sizes fill at similar percentages. An idle worker
  never defers;
- orders by binding `priority` descending, then by queue time.

Selection takes row locks with `SKIP LOCKED`, and a unique index allows one live
placement per job. Two polls racing can never double-place a job.

## 8. Tenant isolation

These guarantees hold for every conforming broker:

1. **Attribution is by credential, never by payload.** A GitHub job's tenant is its App
   `installation.id`. A `jd_run`'s tenant is the one its submitter token is bound to.
   Names in payloads (org, `org_ref`) are never used to choose a tenant or to arm a
   lane.
2. **Default deny.** A worker runs a tenant's work only through a binding. With no
   binding, nothing runs. An exclusive binding makes a worker refuse every other tenant,
   whatever else it is bound to.
3. **Public repositories are denied by default** at every level, re-checked at
   placement. A self-hosted runner reachable from a fork pull request is a remote code
   execution path.
4. **Per-worker identity.** A worker credential acts only for its own worker id and its
   own placements.
5. **Per-tenant reads.** A submitter can read or revoke only its own tenant's runs.
   Another tenant's run is `404`, not `403`.
6. **Caches stop at the org.** Cache volumes are keyed `<owner>--<repo>`. The `--` keeps
   two orgs from ever folding onto one volume. Within an org, a JIT runner can take any
   matching job, so the org, not the repo, is the trust boundary.
7. **Credentials are single-purpose and unpersisted.** A JIT config or run token exists
   only on its offer, is minted for that placement, has no database column, and MUST NOT
   be logged or put on argv.
8. **One agent, one broker** (§1.1). Cross-broker capacity is partitioned by the OS.
9. **No cross-kind side effects.** A `jd_run` never produces a GitHub check, mint, rerun
   or deregistration.

## 9. Timeouts and retries

| What | Value (reference default) | On expiry |
| --- | --- | --- |
| Pending lease (offer → ack) | 60 s | Placement expired; the job re-queues. |
| Running lease (ack/heartbeat) | 2 min, renewed each heartbeat | Placement expired, unless GitHub reports it executing (below). The job re-queues; a `jd_run` acked before expiry is settled `lease_expired_after_ack`. |
| Executing grace | 2 h | A placement GitHub reports as executing keeps its slot past a lapsed lease for this long. |
| Heartbeat interval (agent) | 15 s | n/a |
| Job wall clock (`timeout_seconds`) | 3600 s | The agent stops the job (SIGTERM, 30 s grace, then kill) and reports `deadline_exceeded`. |
| Placement attempts per job | 5 | Then `unplaceable`, reason `attempts_exhausted`, or `runner_exited_before_job` if the last attempt's runner never took the job. |
| Placement deadline (one wait) | 2 h, reset on each re-queue | `unplaceable`, reason `placement_deadline`. |
| Queue ceiling (whole life) | 23 h | `unplaceable`, reason `queue_ceiling`. |
| Re-placement cooldown | 10 min | See §7.3. |
| Reaper pass | 30 s | Expires leases and sweeps deadlines. |
| Worker considered offline | 3 min without a poll | Alarm only. Its placements expire by lease. |
| Agent poll interval | `poll_after_ms`, clamped 0.5–60 s | n/a |
| Agent backoff | 2 s → 60 s, ±20 % jitter; `Retry-After` wins, capped 60 s | n/a |
| Agent request timeouts | 5 s connect, 20 s total | Counts as a failed request. |
| Broker → control-plane offer | 10 s | Offer withheld; re-placed after the pending lease. |
| Control-plane signature skew | 5 min | The control plane rejects the request. |

Re-queueing an expired `workflow_job` is safe because only one live placement can exist per
job, and GitHub's own completion settles whichever runner actually ran it.

## 10. Errors and refusals

### 10.1 Error shapes

The broker sends `{"error": "<stable string or message>", "detail": "<text>"}` where it
has something useful to say. `detail` is optional; examples:
[`error.json`](examples/error.json), [`jd-run-refusal.json`](examples/jd-run-refusal.json).
These cases carry **no body** on purpose:

- every `401`: not saying why stops an attacker from probing which token was once real;
- most `500`s: internal error text can carry hostnames and schema.

Lease conflicts use `{"cancel": true}`, and completion conflicts use
`{"status": "already terminal"}`.

| Status | Meaning for the client |
| --- | --- |
| `200`/`201`/`202` | Success. |
| `400` | The request is wrong. Do not retry unchanged. |
| `401` / `403` | Credential wrong, or not yours. Stop; do not back off and retry. |
| `404` | Not found, or not yours (`jd-runs`). |
| `409` | A state conflict. On ack/heartbeat: stop the placement. On complete: drop the report. On `jd-runs`: a named refusal (`lane_not_armed`, `no_capable_worker`). |
| `408`, `429`, `5xx` | Transient. Retry with backoff, honouring `Retry-After`. |

### 10.2 What a receiver MUST refuse

The **broker** MUST refuse:

- an enrolment token that is unknown, already used, expired, or bound to another name;
- a worker credential for a different worker id (`403`);
- a `container_runtime` it does not model;
- a GitHub delivery without a valid signature, and every delivery when it has no secret;
- a `jd-runs` body with unknown fields, a non-uuid `run_id`, `attempt` < 1, an unknown
  `size`, or an egress entry that breaks §5.3;
- a job that names a reserved grant label, or combines a grant lane with other labels.

It MUST NOT:

- offer a `workflow_job` without a usable JIT config;
- offer a `jd_run` without a minted token;
- offer a grant lane job whose tenant is no longer armed.

The **agent** MUST refuse (ack, then report `infra_error`, never run):

- a grant it is not armed for;
- a kind it is not armed for;
- a `jd_run` without a token or with a `jit_config`;
- a `workflow_job` offer carrying a `jd_run` block;
- an egress policy that does not parse;
- an `enforce` policy it cannot carry.

It SHOULD also refuse cache names or volumes that fail §4.3's patterns. It MUST stop on
`401`/`403`.

The **control plane** MUST reject an offer request with a bad signature or a timestamp
outside the skew window. It MUST NOT mint for a run that is not running, not placed on
the VM backend, or not on its current attempt.

## 11. Operator interface

This is a summary, not a wire contract. Operator routes live under `/v1/admin/` and need
the operator bearer, a secret of its own that is never shared with a job source. A broker
MUST refuse operator routes when no operator secret is configured. They cover:

- tenants: `POST`/`GET /v1/admin/tenants`, and moving a tenant's installation
  ([`tenant-upsert-request.json`](examples/tenant-upsert-request.json));
- worker bindings: `PUT`/`DELETE /v1/admin/workers/{id}/bindings`
  ([`binding-upsert-request.json`](examples/binding-upsert-request.json)). `tenant_id`
  wins over `github_org`. An explicit empty `repository_allowlist` is refused as
  ambiguous; omit it to allow every repo;
- workers: rename, drain, retire (a tombstone, refused while the worker has live
  placements), and reactivate;
- tokens: enrolment and submitter tokens;
- placements: list, and expire one, which hands the job to the normal retry rule;
- jobs: list, explain why a job is or is not placeable (re-running the §7.1 predicate per
  worker), and revive;
- the expected-fleet manifest, reports, and a reporting self-test.

Health endpoints:

- `GET /health/alive` and `GET /health/ready` are unauthenticated;
- `GET /health` is an unauthenticated aggregate, with no ids, tenants or credentials;
- `GET /health/diagnostics/env` requires the operator bearer.

The reference implementation ships a **read-only** MCP server (stdio JSON-RPC) for agents
and humans. Its tools are `fleet`, `jobs`, `placements`, `explain_placement`,
`list_revives` and `tenants`. By design, it exposes no mutation.

## 12. Security considerations

**Broker:**

- Verify the webhook HMAC over the raw bytes, in constant time, before parsing. Bound the
  read before verifying.
- Compare every bearer by digest lookup or constant-time comparison. Store only digests.
- Derive tenants only from installation ids and submitter tokens (§8).
- Re-check tenant activity, public-repo policy and lane arming at placement and at offer,
  not only at ingress.
- Bound and type-check everything an agent reports. The VM block and egress record come
  from inside a job container.
- Never log, persist or echo a JIT config or run token. Never include a response body in
  an error message: poll responses carry credentials.
- Sign control-plane calls, follow no redirects, and use https only.
- Keep `/health` free of identifiers.

**Agent:**

- Store the worker credential owner-only. Pass enrolment tokens by file, never on argv.
- Pass JIT configs, run tokens and offer `env` to the job by inherited environment,
  never on argv, which is world-readable via `ps`.
- Derive mount paths yourself and validate volume and env names. A broker must not be
  able to mount over system paths.
- Refuse what you cannot honour (§10.2). Never quietly run with a grant or policy
  dropped.
- Write `error` notes yourself. Never forward job output.
- Spool completion reports durably, and drop them only on `200`/`409`.

**Control plane:**

- Verify the signature and skew. Mint only for a current, running, VM-placed attempt.
- Bind the token to that attempt, with a TTL near the run timeout.
- Treat `placement_id` and `host` as attribution only.

**Residual risks the protocol accepts:**

- A compromised host sees the work it runs, including its in-flight credentials.
- Enforce-mode egress does not stop domain fronting through an allowed CDN.

## 13. Notes on implementation and documentation

The places where code and documentation disagreed, or the code does less than the
protocol implies. This spec follows the code.

- `protocol_version` is sent but never checked by the broker (§1.4).
- The broker omits `kind` on `workflow_job` offers. Agents must default it.
- A `409` heartbeat's `{"cancel": true}` body is not read by the reference agent, which
  relies on the poll's `revoke` list instead.
- `started_at` on a completion report is sent by the agent but ignored by the broker.
- The broker stores an unrecognised `phase` as sent rather than refusing it.

## 14. Examples

Every example is in [`examples/`](examples/), fully populated, with placeholder values only.

| File | Message |
| --- | --- |
| `enrollment-token-request.json`, `enrollment-token-response.json` | §3.1 |
| `enroll-request.json`, `enroll-response.json` | §3.2 |
| `poll-request.json`, `poll-response.json` | §4.1, offers of both kinds §4.3 |
| `ack-response.json`, `heartbeat-response.json`, `lease-conflict.json` | §4.4–4.5 |
| `complete-request.json`, `complete-response.json`, `complete-conflict.json` | §4.6 |
| `jd-run-submit-request.json`, `jd-run-submit-response.json`, `jd-run-refusal.json` | §5.2.2 |
| `jd-run-status-response.json`, `jd-run-delete-response.json` | §5.2.3 |
| `cp-offer-request.json`, `cp-offer-response.json`, `cp-offer-refusal.json` | §5.2.4 |
| `submitter-token-request.json`, `submitter-token-response.json` | §5.2.1 |
| `egress-policy.json` | §5.3 |
| `tenant-upsert-request.json`, `binding-upsert-request.json`, `error.json` | §10–11 |

## Source

Derived from `rarebit-one/jumpdrive-broker` at `b6bb73d`: the README, ADRs 0005, 0006 and
0007, and the code of the worker plane, placement predicate, poll store, `jd_run`
ingress, control-plane client, webhook parser and agent.
