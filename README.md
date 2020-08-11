<!--
SPDX-FileCopyrightText: 2020 Loetkolben
SPDX-License-Identifier: MIT
-->

# screen-server-scripts / gamesrv / CTL.sh

screen-server-scripts (also known as CTL.sh from its main executable or
gamesrv from the systemd unit names) is a script to
start a Minecraft server in a screen and control it via systemd.
It should be easy to adapt for different servers that behave similarly
to Minecraft.

## System Setup / Integration Assumptions
- You have a user for running all the game servers: `gamesrv`
- This user's home directory ist `/opt/gamesrv/`
- This repository is cloned to `/opt/gamesrv/screen-server-scripts/`
- The server instance folders are in `/opt/gamesrv/instances/`
  (an instance `vanilla` would be located at `/opt/gamesrv/instances/vanilla/`).

The only thing that cares about system integration or absolute paths are
the systemd unit files.
The `CTL.sh` script is completely standalone and can be theoretically be
located where ever you want, if you do NOT want to use the systemd
integration.

### Dependencies
- `screen`
- `bc`

```
sudo apt install screen bc
```

### Actual setup guide
```sh
# Add user
adduser --system --home /opt/gamesrv --disabled-password gamesrv

# Switch to gamesrv user
sudo -u gamesrv -i

# Make sure we are in the home directory of gamesrv user
cd

# Clone repo
git clone https://github.com/Loetkolben/screen-server-scripts

# Create instances directory
mkdir instances

# exit from sudo
exit

# Install systemd integration
cp /opt/gamesrv/screen-server-scripts/systemd/* /etc/systemd/system

# Reload systemd
systemctl daemon-reload

# System setup / integration done!
# Continue with `Adding a new server instance`.
```

## Adding a new server instance
- Run all these steps (except the system integration part) as `gamesrv` user.

- Create a directory with the instance name in `/opt/gamesrv/instances/`.
  Example: Instance name should be `FOOBAR` (= `$INSTANCE_NAME`),
  so the directory would be
  ```sh
  mkdir -p /opt/gamesrv/instances/$INSTANCE_NAME
  ```

- Dump the normal Minecraft server files into
  `/opt/gamesrv/instances/$INSTANCE_NAME`.

- Symlink `CTL.sh` form the repository to
  `/opt/gamesrv/instances/$INSTANCE_NAME/CTL.sh`:
  ```sh
  ln -s /opt/gamesrv/screen-server-scripts/CTL.sh /opt/gamesrv/instances/$INSTANCE_NAME/CTL.sh
  ```

- Optionally, create a `ctlconf.sh` file in
  `/opt/gamesrv/instances/$INSTANCE_NAME` to override
  any of the variables from the config section from `CTL.sh`.

- Start/stop the server or view status:
  ```sh
  systemctl start|stop|status gamesrv@FOOBAR.service
  ```
  After starting, the server should be running in a screen with the configured
  `$SCREEN_NAME` (by default `$INSTANCE_NAME`).

- Enable/disable auto-start on boot:
  ```sh
  systemctl enable|disable gamesrv@FOOBAR.service
  ```

- Start the timer for the backup:
  ```sh
  systemctl enable|disable gamesrv-backup@FOOBAR.timer
  ```

- View backup status or run backup manually:
  ```sh
  systemctl status|start gamesrv-backup@FOOBAR.service
  ```
