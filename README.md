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

Behind a TLS-intercepting proxy, put the proxy's CA certificates (PEM,
`*.crt`) in `docker/extra-ca-certs/` so the build can download packages.
Only the build stage trusts them; the final image doesn't contain them.
The directory's contents are git-ignored.

### Trying the stack locally

```
docker build -t movie-night:local .
cd deploy
printf 'MOVIE_NIGHT_DOMAIN=localhost\nMOVIE_NIGHT_DATA=./data\n' > .env
docker compose run --rm -it app add-user alice
docker compose up
```

Then open <https://localhost>. Caddy serves `localhost` with a certificate
from its own local CA, so the browser warns about it. `deploy/.env` and
`deploy/data/` are git-ignored.

### Infrastructure

The AWS infrastructure is defined with OpenTofu in `infra/`. Run these with
AWS credentials for the target account in your shell (e.g. `AWS_PROFILE`).

1. Once, create the bucket that holds the state:

   ```
   cd infra/bootstrap
   tofu init
   tofu apply        # note the state_bucket output
   ```

2. Configure the main configuration. Both files are git-ignored:

   ```
   cd infra
   cp backend.hcl.example backend.hcl            # set the bucket
   cp terraform.tfvars.example terraform.tfvars  # domain, SSH key, etc.
   ```

3. Create everything:

   ```
   tofu init -backend-config=backend.hcl
   tofu apply
   ```

4. Point the domain's DNS A record at the `public_ip` output.
5. In the GitHub repository, set the Actions variable `AWS_ROLE_ARN` to the
   `github_actions_role_arn` output (Settings → Secrets and variables →
   Actions → Variables). The next push to `main` builds the image and
   pushes it to ECR.

On first boot the instance sets itself up: Docker and Compose, the ECR
credential helper, a swap file, the data volume mounted at
`/var/lib/movie-night`, the files from `deploy/` in `/opt/movie-night`, and
the systemd unit, enabled but not started. Once an image is in ECR, SSH in
(the `ssh_command` output) and start the stack:

```
cloud-init status --wait    # until first-boot setup has finished
cd /opt/movie-night
docker compose pull
docker compose run --rm -it app add-user alice
sudo systemctl start movie-night
```

Caddy obtains the Let's Encrypt certificate on the first HTTPS request,
which only works once DNS points at the instance.

To rebuild the instance from scratch, run `tofu apply
-replace=aws_instance.app`. The data volume, including users and pastes, is
kept and reattached; SSH in and `sudo systemctl start movie-night`.

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
