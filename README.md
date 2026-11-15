# Apple Music Wrapper Deploy

One-command installer and management CLI for [Apple Music wrapper-lite](https://github.com/WorldObservationLog/wrapper/tree/lite) in Docker, with a watchdog that keeps it running and logged in.

**Supported:** Ubuntu 22.04 / 24.04 and Debian 12 / 13, x86_64 — a fresh server or one that already runs other services.

The installer downloads the prebuilt `lite` package, builds a Docker image, prompts for an Apple ID and password, opens the port in UFW or iptables, checks `/status` and `/m3u8`, and enables a periodic health check. The container is named `wrapper`.

## Quick start

On a server with root or `sudo` access:

```bash
git clone https://github.com/dev-x64/apple-music-wrapper-deploy.git
cd apple-music-wrapper-deploy
sudo bash install.sh
```

If Git is not installed yet:

```bash
sudo apt-get update && sudo apt-get install -y git
```

The installer sets up Docker Engine and Compose from Docker's official repository ([Ubuntu](https://docs.docker.com/engine/install/ubuntu/), [Debian](https://docs.docker.com/engine/install/debian/)) if they are missing; an existing Docker installation is reused. GitHub Actions builds the `wrapper-lite-linux-x86_64` package from the `lite` branch. GitHub requires authentication to download Actions artifacts directly, so the installer retrieves the artifact through [nightly.link](https://nightly.link/) using a link to a specific workflow run. It verifies the downloaded file's SHA-256 against the digest provided by the GitHub API. The server does not need to build the Android NDK.

The password is hidden while you type it. If Apple requests a two-factor authentication code, enter it in the interactive terminal. After installation, the `wrapper` command is available from any directory.

## Commands

```bash
wrapper status                 # Check /status and available storefront regions
sudo wrapper logs              # Show the last 100 log lines
sudo wrapper logs --follow     # Follow the logs
sudo wrapper login             # Prompt for Apple ID and a hidden password
sudo wrapper login USER        # Prompt for the password only
sudo wrapper login USER PASS   # Pass both values as arguments
sudo wrapper login --save      # Log in and keep the credentials for automatic re-login
sudo wrapper forget-credentials  # Delete saved credentials
sudo wrapper restart           # Recreate the container and test it
sudo wrapper firewall          # Allow the API port in iptables/ip6tables (idempotent)
sudo wrapper update            # Download a prebuilt lite package, update and test the image
wrapper test                   # Check /status and /m3u8 for the default test track
wrapper test 1608815075        # Test a specific Apple Music track ID
sudo wrapper watchdog          # Run one health check now (restart / re-login if needed)
wrapper watchdog status        # Next run, re-login state and recent watchdog log
sudo wrapper watchdog disable  # Turn the periodic check off (enable turns it back on)
```

With `wrapper login USER PASS`, the password remains in your shell history and is briefly visible in the process list. Use `sudo wrapper login` or `sudo wrapper login USER` to avoid this. By default the password is not stored anywhere: only the login state created by the upstream wrapper is kept. It is saved only if you ask for it with `--save` (see below).

## Watchdog and automatic re-login

The installer enables `wrapper-watchdog.timer`, which runs `wrapper watchdog run` every 5 minutes (and 3 minutes after boot). Each run:

1. checks `/status` (at least one authenticated region) and `/m3u8` for the test track;
2. on failure, waits 20 seconds and checks again, so short hiccups are ignored;
3. recreates the container if it is still unhealthy (this also starts a stopped or crashed container);
4. if that does not help and credentials are saved, stops the container, logs in again and starts it.

Automatic re-login is opt-in: run `sudo wrapper login --save` (or install with `WRAPPER_SAVE_CREDENTIALS=1`). The Apple ID and password are then stored in plain text in `/etc/apple-music-wrapper.credentials` (mode `0600`, readable by root only). Re-login is attempted at most once per `WRAPPER_RELOGIN_COOLDOWN` seconds (6 hours by default) so a wrong password does not lock the Apple ID. It runs without a terminal, so it only works when Apple does not ask for a 2FA code; otherwise the log says so and you need `sudo wrapper login`.

`wrapper login`, `wrapper update` and `wrapper restart` take the same lock as the watchdog, so it never restarts the container in the middle of them. The watchdog logs to the journal: `journalctl -u wrapper-watchdog.service`.

`wrapper update` downloads the latest **successful build** of the upstream `lite` branch; it does not update this installer. If the download, checksum, Docker build, or service check fails, it restores the previous image and package. Account data in `/opt/apple-music-wrapper/data` is preserved. If a new commit has not passed GitHub Actions yet, try the command again later.

## Configuration

Set these environment variables before running `install.sh`:

| Variable | Default | Purpose |
|---|---|---|
| `WRAPPER_PORT` | `12340` | HTTP API port and firewall rule |
| `WRAPPER_FIREWALL` | `auto` | `auto`: UFW rule if UFW is active, otherwise iptables rule if iptables is installed; `ufw`: install and turn on UFW (SSH and the port allowed); `iptables`: always use an iptables rule; `off`: don't touch the firewall |
| `WRAPPER_INSTALL_DIR` | `/opt/apple-music-wrapper` | Installation directory |
| `WRAPPER_TEST_ADAM_ID` | `1608815075` | Track ID for the `/m3u8` check; `0` skips it |
| `WRAPPER_WATCHDOG` | `1` | Install and enable the periodic health check; `0` disables it |
| `WRAPPER_WATCHDOG_INTERVAL` | `5min` | Pause between checks (`300s`, `5min`, `1h`) |
| `WRAPPER_RELOGIN_COOLDOWN` | `21600` | Minimum seconds between automatic re-login attempts |
| `WRAPPER_SAVE_CREDENTIALS` | `0` | `1` saves the credentials entered during installation for re-login |
| `WRAPPER_REPLACE_CONTAINER` | `0` | `1` replaces an existing `wrapper` container not created by this installer |
| `WRAPPER_IMPORT_DATA` | | Directory with existing account data to copy into an empty `data/` |

Example:

```bash
sudo WRAPPER_PORT=12341 WRAPPER_TEST_ADAM_ID=1608815075 bash install.sh
```

Point your client to `http://SERVER_IP:12340` as the wrapper-lite address. For example, in `amdl`, set `lite-server` to this URL.

## How it works

- `/opt/apple-music-wrapper/upstream` contains the unpacked prebuilt `lite` package and its commit SHA in `.source-commit`.
- `/opt/apple-music-wrapper/Dockerfile` and `compose.yaml` are created from templates in this repository.
- `/opt/apple-music-wrapper/data` holds persistent account data and has `0700` permissions.
- `/etc/apple-music-wrapper.conf` contains the installation path, port, and test track ID; it contains no secrets.
- `/usr/local/bin/wrapper` is the management CLI.
- `/etc/systemd/system/wrapper-watchdog.service` and `.timer` run the watchdog.
- `/etc/apple-music-wrapper.credentials` exists only after `wrapper login --save`.

The container uses `network_mode: host` and `privileged: true` because the upstream rootless launcher creates a namespace and mounts `/proc`. With standard Docker port publishing, Docker can [bypass UFW rules](https://docs.docker.com/engine/install/ubuntu/#firewall-limitations). Host networking lets incoming traffic pass through the host's firewall rules. By default (`WRAPPER_FIREWALL=auto`) the installer never turns a firewall on, so servers running other services are not affected:

- if UFW is active, it runs `ufw allow PORT/tcp`;
- otherwise, if `iptables` is installed, it inserts `ACCEPT` for the port at the top of the `INPUT` chain (and in `ip6tables`), tagged with the comment `apple-music-wrapper`. Plain iptables rules are lost on reboot, so the watchdog re-adds the rule on every run (3 minutes after boot, then every 5 minutes); `sudo wrapper firewall` does the same by hand;
- otherwise it leaves the firewall alone.

On a fresh server, `WRAPPER_FIREWALL=ufw` installs and turns on UFW after allowing the detected SSH ports and the wrapper port. The wrapper API has no built-in password: anyone who can reach the open port can use it. Run it on a trusted server and, if needed, restrict the firewall rule to your clients' IP addresses.

The installation check requires a successful `/status` response with at least one region and a successful `/m3u8` response for the test track. If the track is unavailable in your account's region, set a different `WRAPPER_TEST_ADAM_ID`, or set it to `0` to check status only. You can run `wrapper test TRACK_ID` later.

## If installation is interrupted

Run `sudo bash install.sh` again to resume an incomplete installation created by this installer. It will not overwrite an unrelated `/opt/apple-music-wrapper` directory unless the installer marker is present.

```bash
wrapper status
sudo wrapper logs
sudo docker ps --filter name=wrapper
```

If `/status` works but `/m3u8` does not, check the subscription, account region, and track ID. If login failed, run `sudo wrapper login` again. The wrapper code and binaries belong to the [upstream project](https://github.com/WorldObservationLog/wrapper/tree/lite); this repository contains only installation and management scripts.

## Replacing an existing wrapper

If the server already runs a `wrapper` container that was set up by hand (for example from the upstream repository), the installer stops instead of touching it. To switch to this installer without logging in again:

```bash
sudo WRAPPER_REPLACE_CONTAINER=1 bash install.sh
```

The installer builds the new image first, then stops the old container, keeps it as `wrapper-replaced-<timestamp>` (with its restart policy turned off), copies the account data from the directory it mounted at `/app/rootfs/data`, and starts the new container with it. You are asked to log in only if that data does not give a working session. Set `WRAPPER_IMPORT_DATA=/path/to/data` to import account data from another directory. When everything works, remove the old container with `docker rm wrapper-replaced-<timestamp>`.

Re-running `install.sh` on a server that is already logged in also skips the login prompt.

To migrate from an earlier version of this installer that built `lite` from source, run `sudo bash install.sh` from a fresh clone of this repository. The installer preserves the `data` directory and replaces the old source tree with the prebuilt package. After that, use `sudo wrapper update`.

## Developer checks

```bash
bash -n install.sh wrapper download-upstream.sh
bash tests/run.sh   # needs Docker for `compose config`; uses mocks for curl and docker
```

## License

The scripts in this repository are MIT-licensed. The upstream wrapper is also [MIT-licensed](https://github.com/WorldObservationLog/wrapper/blob/lite/LICENSE). This repository contains no Apple ID, password, or login data.
