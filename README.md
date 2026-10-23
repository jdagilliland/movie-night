# Movie Night

Paste text, get a short link. See `docs/SPEC.md` for the full spec.

## Development

### Prerequisites

Install the Haskell toolchain with [ghcup](https://www.haskell.org/ghcup/),
including Stack. The project is pinned to the Stackage snapshot in
`stack.yaml` (LTS 24.64, GHC 9.10.3); Stack installs that GHC via ghcup if
it is missing.

### Build and run

```
stack build                 # build library, executable, and tests
stack exec movie-night -- add-user alice  # create a user; prompts for a password
stack exec movie-night -- serve           # run the web server on port 8080
```

The server refuses to start without a users file, so create a user first.
`set-password` and `remove-user` manage existing users; restart the server
after any change.

Admin commands work while the server is running:

```
stack exec movie-night -- takedown <id> --reason "<text>"  # erase content, log it
stack exec movie-night -- show <id>                        # metadata and status
stack exec movie-night -- purge-expired                    # purge now (also runs daily)
```

The server is configured with environment variables (see `docs/SPEC.md`
§7.4). By default it stores data in `./data/pastes.db`, which is
git-ignored.

### Tests

```
stack test                              # build and run the full test suite
stack test --file-watch                 # re-run tests whenever a file changes
stack test --ta '--match "FR-8"'        # run only tests whose description matches
```

`--ta` passes arguments through to hspec. Test descriptions include
requirement IDs from the spec (e.g. `FR-17`), so `--match "FR-17"` runs the
tests for one requirement.

CI runs `stack test` on a native ARM64 runner for every push to `main` and
every pull request (`.github/workflows/ci.yml`).

## Deployment

The app runs in Docker behind Caddy, which terminates TLS. The files for a
host are in `deploy/`: `compose.yaml`, `Caddyfile`, `.env.example`, and the
systemd unit `movie-night.service`. All persistent data lives in one host
directory, `/var/lib/movie-night` by default, mounted into the app
container as `/data`:

```
/var/lib/movie-night/
├── db/pastes.db
├── logs/takedowns.log
├── users
└── caddy/            (TLS certificates)
```

### Building the image

```
docker build -t movie-night:local .
```

The image is built for the host's architecture: `linux/arm64` on Apple
Silicon, matching the Graviton instance. The app runs as UID 10001.

### Trying the stack locally

```
cd deploy
printf 'MOVIE_NIGHT_DOMAIN=localhost\nMOVIE_NIGHT_DATA=./data\n' > .env
docker compose run --rm -it app add-user alice
docker compose up --build
```

Then open <https://localhost>. Caddy serves `localhost` with a certificate
from its own local CA, so the browser warns about it. `deploy/.env` and
`deploy/data/` are git-ignored.

### First setup on the instance

1. Mount the data volume at `/var/lib/movie-night` and give the app's UID
   the directories it writes to:

   ```
   sudo chown 10001:10001 /var/lib/movie-night
   sudo install -d -o 10001 -g 10001 /var/lib/movie-night/db /var/lib/movie-night/logs
   ```

2. Copy `deploy/` to `/opt/movie-night`, and create `/opt/movie-night/.env`
   from `.env.example` with the domain and the image to run.
3. Pull the image and create the first user:

   ```
   cd /opt/movie-night
   docker compose pull
   docker compose run --rm -it app add-user alice
   ```

4. Install and start the systemd unit, which brings the stack up on boot:

   ```
   sudo cp movie-night.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now movie-night
   ```

### Deploying a new version

```
cd /opt/movie-night
docker compose pull app
docker compose up --detach app
```

This recreates only the app container; Caddy keeps running.

### Administration

Admin commands run inside the app container:

```
docker compose exec app movie-night takedown <id> --reason "<text>"
docker compose exec app movie-night show <id>
docker compose exec app movie-night purge-expired
docker compose exec -it app movie-night add-user <name>
docker compose restart app   # after any user change
```

Logs: `docker compose logs app`. Container logs are rotated at 5 × 10 MB.

### Re-applying takedowns after a restore

If only the database is restored from an older snapshot, while the current
takedown log survives, re-apply the logged takedowns (requires `jq`).
Takedowns already in the database report "already taken down", and purged
pastes report "No such paste"; both are harmless. A restore of the whole
volume brings back the log as of the snapshot too, so re-apply any
takedowns made since then by hand.

```
jq -r '[.id, .reason] | @tsv' /var/lib/movie-night/logs/takedowns.log |
  while IFS=$'\t' read -r id reason; do
    docker compose exec -T app movie-night takedown "$id" --reason "$reason"
  done
```
