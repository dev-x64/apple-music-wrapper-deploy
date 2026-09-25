# Apple Music wrapper: Docker deployment

An installer for a new Ubuntu 22.04/24.04 x86_64 server. It downloads the prebuilt package for the [`lite` branch of WorldObservationLog/wrapper](https://github.com/WorldObservationLog/wrapper/tree/lite), creates a Docker image, prompts for an Apple ID and password, opens the port with UFW, and checks `/status` and `/m3u8`. The container is named `wrapper`.

## Quick start

On a **new** server with `sudo` access:

```bash
git clone https://github.com/dev-x64/apple-music-wrapper-deploy.git
cd apple-music-wrapper-deploy
sudo bash install.sh
```

If Git is not installed yet:

```bash
sudo apt-get update && sudo apt-get install -y git
```

The installer sets up Docker Engine and Compose from [Docker's official repository](https://docs.docker.com/engine/install/ubuntu/) if needed. GitHub Actions builds the `wrapper-lite-linux-x86_64` package from the `lite` branch. GitHub requires authentication to download Actions artifacts directly, so the installer retrieves the artifact through [nightly.link](https://nightly.link/) using a link to a specific workflow run. It verifies the downloaded file's SHA-256 against the digest provided by the GitHub API. The server does not need to build the Android NDK.

The password is hidden while you type it. If Apple requests a two-factor authentication code, enter it in the interactive terminal. After installation, the `wrapper` command is available from any directory.

## Commands

```bash
wrapper status                 # Check /status and available storefront regions
sudo wrapper logs              # Show the last 100 log lines
sudo wrapper logs --follow     # Follow the logs
sudo wrapper login             # Prompt for Apple ID and a hidden password
sudo wrapper login USER        # Prompt for the password only
sudo wrapper login USER PASS   # Pass both values as arguments
sudo wrapper update            # Download a prebuilt lite package, update and test the image
wrapper test                   # Check /status and /m3u8 for the default test track
wrapper test 1608815075        # Test a specific Apple Music track ID
```

With `wrapper login USER PASS`, the password remains in your shell history and is briefly visible in the process list. Use `sudo wrapper login` or `sudo wrapper login USER` to avoid this. The password is not stored in Compose, the Dockerfile, the repository, or a configuration file. Only the login state created by the upstream wrapper is stored.

`wrapper update` downloads the latest **successful build** of the upstream `lite` branch; it does not update this installer. If the download, checksum, Docker build, or service check fails, it restores the previous image and package. Account data in `/opt/apple-music-wrapper/data` is preserved. If a new commit has not passed GitHub Actions yet, try the command again later.

## Configuration

Set these environment variables before running `install.sh`:

| Variable | Default | Purpose |
|---|---|---|
| `WRAPPER_PORT` | `12340` | HTTP API port and UFW rule |
| `WRAPPER_INSTALL_DIR` | `/opt/apple-music-wrapper` | Installation directory |
| `WRAPPER_TEST_ADAM_ID` | `1608815075` | Track ID for the `/m3u8` check; `0` skips it |

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

The container uses `network_mode: host` and `privileged: true` because the upstream rootless launcher creates a namespace and mounts `/proc`. With standard Docker port publishing, Docker can [bypass UFW rules](https://docs.docker.com/engine/install/ubuntu/#firewall-limitations). Host networking lets incoming traffic pass through the host's firewall rules. The installer allows detected SSH ports before enabling UFW, then allows the wrapper port. The wrapper API has no built-in password: anyone who can reach the open port can use it. Run it on a trusted server and, if needed, restrict the UFW rule to your clients' IP addresses.

The installation check requires a successful `/status` response with at least one region and a successful `/m3u8` response for the test track. If the track is unavailable in your account's region, set a different `WRAPPER_TEST_ADAM_ID`, or set it to `0` to check status only. You can run `wrapper test TRACK_ID` later.

## If installation is interrupted

Run `sudo bash install.sh` again to resume an incomplete installation created by this installer. It will not overwrite an unrelated `/opt/apple-music-wrapper` directory unless the installer marker is present.

```bash
wrapper status
sudo wrapper logs
sudo docker ps --filter name=wrapper
```

If `/status` works but `/m3u8` does not, check the subscription, account region, and track ID. If login failed, run `sudo wrapper login` again. The wrapper code and binaries belong to the [upstream project](https://github.com/WorldObservationLog/wrapper/tree/lite); this repository contains only installation and management scripts.

To migrate from an earlier version of this installer that built `lite` from source, run `sudo bash install.sh` from a fresh clone of this repository. The installer preserves the `data` directory and replaces the old source tree with the prebuilt package. After that, use `sudo wrapper update`.

## Developer checks

```bash
bash -n install.sh wrapper download-upstream.sh
bash tests/run.sh
```

## License

The scripts in this repository are MIT-licensed. The upstream wrapper is also [MIT-licensed](https://github.com/WorldObservationLog/wrapper/blob/lite/LICENSE). This repository contains no Apple ID, password, or login data.
