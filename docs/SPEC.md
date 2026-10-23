# Spec: Movie Night

## 1. Overview

A minimal web application where an authenticated user pastes text, submits it, and receives a short link. Anyone following that link (no login required) sees the original text, rendered with minimal styling. Content is stored durably, survives server restarts, and expires after an admin-configured period. Admins can take down content.

## 2. Goals & Non-Goals

**Goals**
- Create a paste from plain text with minimal friction (browser flow first).
- Return a short, random, shareable URL.
- Display pasted text faithfully (whitespace and line breaks preserved).
- Persist data across restarts/redeploys.
- Expire pastes after an admin-configured TTL.
- Let admins take down content.
- Require authentication to create; viewing is public.
- Backend in Haskell using Servant.

**Non-Goals (v1)**
- User-initiated deletion or editing of pastes
- User-selectable expiration
- Custom (user-chosen) slugs
- Password-protected pastes
- JSON API (deferred; see §12)
- Syntax highlighting, Markdown rendering, or rich text
- File/binary uploads
- Search or listing of pastes
- Horizontal scaling (traffic is expected to be very low; single instance + SQLite)

## 3. User Stories

1. **Create:** As a signed-in user, I can paste text into a textbox and submit it, so that I receive a short link.
2. **Share:** As a user, I can easily copy the short link, so that I can send it to others.
3. **View:** As anyone (signed in or not), I can open the link and read the text exactly as written.
4. **Raw access:** As a technical user, I can fetch the raw text (e.g. with `curl`).
5. **Not found:** As a recipient of a bad, expired, or removed link, I see a clear "not found" message.
6. **Takedown:** As an admin, I can take down a paste by ID so its content is no longer served.
7. **Expiry config:** As an admin, I can configure how long pastes live.

## 4. Functional Requirements

### 4.1 Creating a paste
- **FR-1:** The home page (`GET /`) presents a single textarea and a submit button to signed-in users. Anonymous visitors see a sign-in prompt instead (see §5).
- **FR-2:** Submitting (`POST /`) requires authentication. It stores the text and the creator's identity and returns a unique short ID.
- **FR-3:** After submission, the user is redirected (303) to the paste's view page, which displays its full URL with a "copy link" control.
- **FR-4:** Empty or whitespace-only submissions are rejected with a validation message.
- **FR-5:** Submissions over the maximum size are rejected. Limit: 512 KiB
  of UTF-8 text (`MAX_PASTE_BYTES`), measured on the decoded text after
  line-ending normalization (FR-6), i.e. as stored, not on the encoded
  request body (see NFR-4).
- **FR-6:** Text is stored exactly as received, except line endings normalized to `\n`.

### 4.2 Short links
- **FR-7:** IDs are always server-generated; users cannot choose them.
- **FR-8:** IDs are random base62 strings (`[0-9A-Za-z]`) of length 8 (~2.18 × 10¹⁴ space).
- **FR-9:** IDs are generated with a cryptographically secure RNG so they are not guessable/enumerable.
- **FR-10:** On ID collision (including with a taken-down row), the 
  server retries generation (up to 7 times, then 500).
- **FR-11:** URL format: `https://<host>/<id>`.

### 4.3 Viewing a paste
- **FR-12:** Viewing is public; no authentication is required or checked.
- **FR-13:** `GET /<id>` returns an HTML page displaying the text in a `<pre>` block, with all content HTML-escaped.
- **FR-14:** `GET /<id>/raw` returns the text as `text/plain; charset=utf-8`.
- **FR-15:** The view page shows only: the text, creation timestamp, expiry timestamp, a "copy link" control, a "raw" link, and a "new paste" link. All timestamps are displayed in UTC and labeled as such.
- **FR-16:** Unknown **or expired** IDs return HTTP 404 with a minimal "Paste not found" page. Expired and never-existed are indistinguishable to viewers.
- **FR-17:** Taken-down IDs return HTTP 404 with the same page as unknown IDs. Taken-down and never-existed are indistinguishable to viewers.

### 4.4 Expiration
- **FR-18:** Every paste expires after a TTL set by the admin via 
  configuration (`PASTE_TTL_DAYS`, §7.4). Users cannot choose or change it, 
  The view page shows a visible expiry notice, e.g. "This paste expires on
  2026-11-20."
- **FR-19:** `expires_at` is computed and stored at creation time. Changing 
  the TTL affects only pastes created afterward, so a link's lifetime never 
  changes after it's shared.
- **FR-20:** Expiry is enforced at read time (`expires_at > now`), so expired pastes stop being served immediately regardless of purge timing.
- **FR-21:** A background thread purges expired rows at server startup and
  then every 24 hours. A failed purge is logged and retried at the next
  interval.

### 4.5 Deletion & takedown
- **FR-22:** Users cannot delete or edit pastes. Pastes are immutable once created.
- **FR-23:** Admins can take down a paste by ID via an admin CLI (§6).
- **FR-24:** Takedown permanently erases the paste content and keeps the row with its metadata (`taken_down_at`, `takedown_reason`) so the takedown is recorded. Public responses for the ID are 404 (FR-17).
- **FR-25:** Takedown is idempotent; taking down an already-removed or nonexistent ID reports that clearly and exits non-zero for nonexistent.

### 4.6 Persistence
- **FR-26:** Pastes survive application restarts.

## 5. Authentication (stub plan)

Creating a paste requires authentication; viewing never does. The final auth mechanism is not yet decided. This section fixes the **seam** so it can be swapped in without touching handlers, and records the questions to resolve.

### 5.1 Requirements fixed now
- **AUTH-1:** Only `GET /` (form rendering), `POST /`, and auth routes are auth-aware. View routes (`/:id`, `/:id/raw`) never inspect credentials.
- **AUTH-2:** Handlers receive an authenticated `User` value from a Servant auth combinator; they never parse credentials themselves.
- **AUTH-3:** Each paste records `created_by` (user identifier) for abuse investigation.
- **AUTH-4:** Unauthenticated `POST /` returns 401 (or redirects to sign-in for browser requests).
- **AUTH-5:** Browsers send Basic credentials with any request to the site,
  including form posts triggered by other sites. `POST /` therefore rejects
  a request whose `Origin` header differs from `BASE_URL` with 403. Requests
  without an `Origin` header (e.g. curl) are allowed.

### 5.2 Seam in the Servant API

```haskell
-- Generalized auth: the handler for "session" is supplied via Servant's Context
type instance AuthServerData (AuthProtect "session") = User

data User = User
  { userId      :: UserId
  , displayName :: Text
  }

type CreateAPI =
       AuthProtect "session" :> Get '[HTML] HomePage
  :<|> AuthProtect "session" :> ReqBody '[FormUrlEncoded] PasteForm
         :> Verb 'POST 303 '[HTML] (Headers '[Header "Location" Text] NoContent)
```

The `AuthHandler Request User` is built at startup from config, so changing auth mechanisms means providing a different `AuthHandler` (and auth routes). Handler code stays the same.

### 5.3 Interim mechanism (v1)
Until the real flow is built, the `AuthHandler` validates HTTP Basic 
credentials against an admin-managed list (`USERS_FILE`, containing 
usernames + argon2id password hashes). This is real protection, 
trivial at this traffic level, and needs no session storage. It is 
explicitly temporary.

Users file format: one user per line, `username:hash`, where the hash is an
argon2id string in PHC format (`$argon2id$v=19$m=19456,t=2,p=1$<salt>$<hash>`).

```
# comments and blank lines are ignored
alice:$argon2id$v=19$m=19456,t=2,p=1$c2FsdHNhbHQ$aGFzaGhhc2hoYXNo
```

- Usernames match `[a-z0-9_-]{1,32}`. The username is the value stored in
  `created_by`.
- Hash parameters follow the OWASP minimum (19 MiB memory, 2 iterations,
  1 lane). The hash is verified on every authenticated request.
- The file must be mode `0600`; the server refuses to start otherwise.
- The file is read at startup. User changes take effect on restart.
- Users are managed with the `add-user`, `set-password`, and `remove-user` CLI
  subcommands (§6).
- Basic auth has no logout. The browser's native credential dialog serves as
  the sign-in prompt (FR-1). Both limitations are accepted for the interim.

### 5.4 Target flow (to be designed)
Sketch, assuming cookie-based sessions:

1. Anonymous user visits `/` → sees "Sign in to create a paste".
2. `GET /auth/login` → starts login with the chosen identity method.
3. Callback/verification route → on success, create a row in `sessions`, set an `HttpOnly; Secure; SameSite=Lax` session cookie, redirect to `/`.
4. `AuthHandler` reads the cookie, looks up the session, yields `User` or rejects.
5. `POST /auth/logout` → deletes session row, clears cookie.
6. `POST /` is protected against CSRF (SameSite cookie + per-session form token).

Likely schema additions:

```sql
CREATE TABLE users    (id TEXT PRIMARY KEY, external_id TEXT UNIQUE, display_name TEXT, created_at TEXT NOT NULL);
CREATE TABLE sessions (token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
                       created_at TEXT NOT NULL, expires_at TEXT NOT NULL);
```

### 5.5 Auth open questions
1. **Identity method:** OAuth/OIDC with an external provider (GitHub, Google, company SSO)? Email magic links? Local username/password?
2. **Who may sign up:** Anyone, an allowlist of users/domains, or admin-invited only?
3. **Admin identity:** Should admins eventually be web users with an admin role, or stay CLI-only (§6)?
4. **Session lifetime:** How long before re-login is required?
5. **Account suspension:** Should takedown also be able to suspend the creator?

## 6. Admin Operations

Admin actions happen through a CLI subcommand of the same executable, run on 
the host against the same SQLite file. SQLite WAL mode allows this while the 
server runs.

```
movie-night serve                                   # run the web server
movie-night takedown <id> --reason "<text>"         # erase content, log takedown
movie-night show <id>                               # print metadata (created_at, created_by, expires_at, status)
movie-night purge-expired                           # run the purge job once, on demand
movie-night add-user <name>                         # prompt for password twice; fail if user exists
movie-night set-password <name>                     # prompt for password; replace the hash
movie-night remove-user <name>                      # remove the user; their pastes are unaffected
```

- Takedowns are logged to an append-only file (`TAKEDOWN_LOG`, §7.4): the
  ID, reason, and UTC timestamp, never the content. The DB row keeps
  `taken_down_at` and `takedown_reason` until purged, so the log is the
  lasting record. It is used to re-apply takedowns after a database restore
  (NFR-13) and must be included in backups.
- The log has one JSON object per line, e.g.
  `{"id":"abcdEFGH","reason":"spam","time":"2026-10-23T12:00:00Z"}`.
  Only takedowns that erase content are logged; a repeat takedown is not.
  If the log can't be written after the content is erased, `takedown`
  exits non-zero and says to record the takedown manually.
- `show`, `takedown`, and `purge-expired` refuse to run if the database
  file doesn't exist, rather than creating an empty one, so a wrong
  `DB_PATH` is reported instead of every paste appearing missing.
- `--reason` is required for `takedown`.
- Public responses for taken-down IDs are indistinguishable from unrecognized IDs (404). The CLI reports takedown status, including already-removed and nonexistent IDs (FR-25).
- TTL is configured via `PASTE_TTL_DAYS` and takes effect on server restart.
- CLI parsing via `optparse-applicative`.

## 7. Architecture

```
Browser / curl ──HTTP──▶ Warp ──▶ WAI middleware ──▶ Servant handlers ──▶ Storage interface ──▶ SQLite
                                  (logging, size limit,  │                  (record of functions)   ▲
                                   security headers)     └─ AuthHandler ──▶ user list / sessions    │
                                                                                                    │
Admin CLI (takedown / show / purge-expired) ────────────────────────────────────────────────────────┤
Purge thread (daily)  ──────────────────────────────────────────────────────────────────────────────┘
```

### 7.1 Suggested libraries
- **Server:** `servant`, `servant-server`, `warp`, `wai-extra` (logging, request size limit)
- **HTML:** `servant-lucid` + `lucid` (auto-escapes text;
  `servant-lucid` does not support `lucid2`)
- **Persistence:** SQLite via `sqlite-simple`
- **Random IDs:** `crypton` (or `entropy`) for secure random bytes
- **Password hashing (interim auth):** `crypton` (argon2id)
- **CLI:** `optparse-applicative`
- **Config:** environment variables
- **Testing:** `hspec`, `hspec-wai`, `QuickCheck`

### 7.2 Storage abstraction
Handlers depend on a record interface, not SQLite directly, so tests can use an in-memory implementation:

```haskell
data LookupResult
  = Found Paste
  | Gone               -- taken down; served as 404 publicly
  | NotFound           -- never existed or expired; served as 404

data Store = Store
  { storeInsert       :: Paste -> IO (Either InsertError ())     -- DuplicateId on collision
  , storeLookup       :: UTCTime -> PasteId -> IO LookupResult   -- "now" passed in for testable expiry
  , storeTakedown     :: PasteId -> Text -> UTCTime -> IO TakedownResult
  , storeInspect      :: PasteId -> IO (Maybe PasteInfo)         -- metadata, any status (`show`)
  , storePurgeExpired :: UTCTime -> IO Int                       -- rows purged
  , storeHealthy      :: IO Bool                                 -- `/healthz`
  }
```

### 7.3 Database schema

```sql
CREATE TABLE IF NOT EXISTS pastes (
  id               TEXT PRIMARY KEY,
  content          TEXT,               -- NULL after takedown
  created_by       TEXT NOT NULL,
  created_at       TEXT NOT NULL,      -- ISO-8601 UTC
  expires_at       TEXT NOT NULL,      -- ISO-8601 UTC
  taken_down_at    TEXT,               -- NULL unless taken down
  takedown_reason  TEXT
);
CREATE INDEX IF NOT EXISTS pastes_expires_at ON pastes(expires_at);
```

- Enable WAL mode (`PRAGMA journal_mode=WAL`) and a busy timeout so the CLI and server coexist.
- Timestamps are stored as fixed-width ISO-8601 UTC text at whole-second
  precision (`YYYY-MM-DDTHH:MM:SSZ`), truncating any fraction. The fixed
  width makes text comparison in SQL (e.g. the purge) order correctly.
- Schema initialization runs at startup (idempotent).
- The purge job deletes rows where `expires_at <= now`.
- DB file path is configurable and must reside on a persistent volume.

### 7.4 Configuration (environment variables)

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `8080` | HTTP listen port |
| `DB_PATH` | `./data/pastes.db` | SQLite file |
| `BASE_URL` | `http://localhost:<PORT>` | Used to build short URLs and for the cross-origin check (AUTH-5) |
| `MAX_PASTE_BYTES` | `524288` | Size limit |
| `PASTE_TTL_DAYS` | `30` | Lifetime of newly created pastes |
| `USERS_FILE` | `./data/users` | Interim Basic-auth credentials (§5.3) |
| `TAKEDOWN_LOG` | `./data/takedowns.log` | Append-only takedown log (§6) |

## 8. Presentation

- Server-rendered HTML.
- The view page has a "copy link" control, implemented with a small script served as a static file (`/static/copy.js`). The link text stays selectable without it.
- Single small inline stylesheet: system monospace font, `white-space: pre-wrap` for wrapping long lines, comfortable max-width, no colors beyond defaults.
- Responsive and readable on mobile; respects light/dark mode via `prefers-color-scheme`.
- On the view page, the paste content is the most prominent feature: full
  size, monospace, about 80 characters wide. Everything else is slim
  chrome in small, faded, sans-serif text: a header above the content (the
  link, "copy link", "raw", "new paste") and a footer below it (creation
  and expiry timestamps). The fading uses opacity, not a color, so it
  follows light and dark mode.

## 9. Non-Functional Requirements

### 9.1 Security
- **NFR-1:** All user content is HTML-escaped on render; never interpreted as markup.
- **NFR-2:** Response headers:
  `Content-Security-Policy: default-src 'none'; style-src 'self' 'unsafe-inline'; script-src 'self'`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: same-origin`. Other
  sites never receive a referrer. The policy is not `no-referrer`, because
  under that policy browsers send `Origin: null` on form posts, which
  AUTH-5 must reject.
- **NFR-3:** Raw endpoint always served as `text/plain` so browsers never sniff it as HTML.
- **NFR-4:** Request body size is enforced at the WAI layer before the full body is read. The cap is 3 × `MAX_PASTE_BYTES` + 4 KiB, which allows for worst-case URL-encoding growth. The handler then checks the decoded text against `MAX_PASTE_BYTES` (FR-5). Both rejections return 413.
- **NFR-5:** Per-user rate limit on paste creation: 30 per minute, as a
  sliding window held in memory (reset on restart). Excess requests get 429.
  This is low priority given authentication and expected traffic.
- **NFR-6:** Parameterized SQL queries only.
- **NFR-7:** Deployed behind HTTPS (terminated at reverse proxy). This is required, since interim Basic auth sends credentials on every request.
- **NFR-8:** Credentials and session tokens are stored only as hashes.

### 9.2 Performance
- **NFR-9:** Expected traffic is very low; a single instance with SQLite is sufficient. No caching layer.
- **NFR-10:** p95 latency < 50 ms for view requests on modest hardware.

### 9.3 Reliability & Operations
- **NFR-11:** Request logging (Apache-style); takedown events are logged (§6). Paste content and credentials are never logged.
  The client address is taken from `X-Forwarded-For`, which Caddy sets
  (replacing any client-supplied value), falling back to the socket address
  when there is no proxy.
- **NFR-12:** `GET /healthz` returns 200 when the DB is reachable.
- **NFR-13:** The data volume (database, takedown log, users file, TLS
  certificates) is backed up by daily EBS snapshots (§12). If only the
  database is restored from an older snapshot, takedowns recorded in the
  current log after that snapshot are re-applied. If the whole volume is
  restored, the log is restored with it, so takedowns made since the
  snapshot are lost along with pastes made since then. This is accepted:
  takedowns need not be retained more rigorously than pastes, and the admin
  re-applies any recent takedowns from their own records.

## 10. Endpoints (v1)

| Method | Path | Auth | Success | Errors |
|---|---|---|---|---|
| GET | `/` | required | 200 HTML form | 401 / sign-in prompt |
| POST | `/` | required | 303 → `/<id>` | 400 empty, 401, 403 cross-origin, 413 too large, 429 rate limited |
| GET | `/:id` | none | 200 HTML | 400 malformed, 404 missing, expired, or taken down |
| GET | `/:id/raw` | none | 200 text/plain | 400, 404 |
| GET | `/static/copy.js` | none | 200 text/javascript | — |
| GET | `/healthz` | none | 200 | 503 if DB unreachable |

Route ordering: fixed paths (`/healthz`, `/static/*`, future `/auth/*`) must be matched before `Capture "pasteId"`. `PasteId` parsing (8-char base62) also prevents them from colliding.

## 11. Testing Requirements

- **Unit:** ID generator output always matches base62/length rules (QuickCheck); `PasteId` parsing rejects malformed input; line-ending normalization; expiry computation from TTL.
- **Property:** For any non-empty text under the limit, create → fetch raw returns identical content.
- **Integration (`hspec-wai`):**
  - Form flow with valid credentials; `POST /` without/with bad credentials → 401.
  - View routes succeed with no credentials.
  - 404 (unknown), 404 (expired: insert with past `expires_at`), 404 (taken down), 400, 413.
  - View page includes the expiry notice and the copy control; `/static/copy.js` is served.
  - HTML escaping (`<script>` renders literally); security headers present (including CSP `script-src`).
- **Size limits:** decoded text at exactly `MAX_PASTE_BYTES` is accepted even when its encoded body is larger; one byte over → 413; an oversized raw body → 413.
- **Users file:** parsing accepts comments and blank lines and rejects malformed lines; the server refuses to start on a world-readable file; `add-user` / `set-password` / `remove-user` round-trip.
- **Admin:** takedown erases content, yields 404 publicly, and is logged; repeat takedown is idempotent; purge removes only expired rows.
- **Persistence:** create paste, restart app against the same DB file, fetch succeeds.

## 12. Future Work

- Real authentication flow (§5.4) replacing interim Basic auth.
- JSON API, for example:
  - `POST /api/pastes` → 201 `{"id","url","expiresAt"}`
  - `GET /api/pastes/:id` → 200 `{"id","content","createdAt","expiresAt"}`
  - These would be protected by the same auth seam (likely API tokens).
- AWS deployment:
  - The application will run on AWS, with all infrastructure defined in OpenTofu.
  - Infrastructure must be the cheapest possible, using the free tier where available.
    Free-tier eligibility of the account is unknown, so the design targets the lowest
    steady-state cost and treats any free tier as a bonus.
  - Compute: a single t4g.nano EC2 instance (0.5 GB, plus a 1 GB swap file)
    running Ubuntu 24.04 LTS, with a root volume and a separate EBS data
    volume. The data volume is marked `prevent_destroy`, so replacing the
    instance never touches data. CPU credits are `standard`, not the t4g
    default `unlimited`, so sustained load is throttled rather than billed.
    The metadata service requires IMDSv2 tokens.
  - Provisioning: on first boot, user data installs Docker, Compose, and
    the ECR credential helper; creates the swap file; formats the data
    volume if it is blank and mounts it; writes the `deploy/` files and
    `.env` to `/opt/movie-night`; and enables the systemd unit. The admin
    then creates the first user and starts the unit (README,
    "Infrastructure"). User data only runs at first boot; later changes to
    it apply when the instance is replaced.
  - Network: a dedicated VPC with one public subnet and an internet gateway,
    and no NAT gateway. The security group allows 80/tcp, 443/tcp, and
    443/udp from anywhere, and 22/tcp from the admin CIDRs.
  - Data volume: mounted on the host at `/var/lib/movie-night` (by UUID, `nofail`):

    ```
    /var/lib/movie-night/
    ├── db/pastes.db          (+ -wal, -shm)
    ├── logs/takedowns.log
    ├── users                 (0600)
    └── caddy/                (TLS certificates; persisted to avoid Let's Encrypt rate limits)
    ```

  - Runtime: Docker Compose (app + Caddy), started on boot by a systemd unit;
    Docker's `unless-stopped` restart policy restarts failed containers. The
    unit requires the data volume's mount, so the app never starts against
    an empty directory on the root volume. The app container mounts
    `/var/lib/movie-night` at `/data`, with `DB_PATH=/data/db/pastes.db`,
    `USERS_FILE=/data/users`, and `TAKEDOWN_LOG=/data/logs/takedowns.log`.
    It runs as UID 10001, which owns the data directory. Container logs are
    rotated (5 × 10 MB). The host files are in `deploy/`.
  - Admin CLI commands run inside the app container
    (`docker compose exec app movie-night ...`), so they see the same paths as the
    server.
  - Networking: an Elastic IP, so the DNS record stays stable across instance
    replacement. AWS bills public IPv4 addresses hourly outside the free tier, which is
    expected to be the main fixed cost.
  - DNS: an A record for the domain points at the Elastic IP. For now the
    domain is registered by hand in Route 53, and OpenTofu manages the A
    record in its hosted zone (`route53_zone_name`). The domain isn't tied
    to Route 53: with `route53_zone_name` unset, OpenTofu manages no DNS,
    and the A record is created wherever the domain's DNS is hosted. The
    registration itself is never managed by OpenTofu, so no apply or
    destroy can affect it. Registration and the hosted zone ($0.50/month)
    add to the monthly cost.
  - HTTPS (NFR-7): TLS terminates on the instance (e.g. Caddy with Let's Encrypt).
    No load balancer, since an ALB alone would exceed the target cost.
  - Images: built Docker images are pushed to ECR and pulled by the instance.
    ECR keeps the 10 most recent images. The host's Compose file has no
    build section, so the instance only ever pulls.
  - Backups (NFR-13): daily EBS snapshots of the data volume via Data Lifecycle
    Manager, with a retention count set by an OpenTofu variable. SQLite in WAL mode
    recovers cleanly from a crash-consistent snapshot. Up to one day of data can be
    lost.
  - OpenTofu state is stored remotely in S3, using S3-native locking (`use_lockfile`),
    so no DynamoDB table is needed.
  - The state bucket is created once by a separate configuration with local
    state (`infra/bootstrap`); the main configuration is in `infra/`.
  - Region: `us-east-1`.
  - Admin access: SSH with a key pair. The security group allows port 22 only
    from admin-specified CIDRs (an OpenTofu variable).
  - Architecture: ARM64 only (Graviton, e.g. t4g). Images are built on GitHub
    Actions native ARM runners (`ubuntu-24.04-arm`), not under QEMU
    emulation. The test job caches the Stack store, and the image job caches
    Docker layers, between runs.
  - CI pushes images to ECR as `:<commit>` and `:latest`, only for pushes to
    `main` that pass the tests. It authenticates via GitHub OIDC with an
    OpenTofu-managed IAM role (no long-lived AWS keys in GitHub), which only
    workflows on `main` of this repository can assume, and which may only
    push to the Movie Night repository.
  - Deploys are manual at first: pull the new image and restart on the instance.
  - Cost monitoring: an AWS Budgets budget of $10/month, alerting by email on 100%
    of actual spend and 100% of forecasted spend. Alerts only, no automatic actions.

## 13. Deliverables

- Stack project with `app/`, `src/`, `test/` layout (toolchain installed via ghcup)
- `Dockerfile` with a volume mount for the DB
- Docker Compose file (app + Caddy) and systemd unit for the instance
- `README` covering build, run, configuration, admin CLI usage, and interim auth setup
