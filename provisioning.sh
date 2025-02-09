#!/usr/bin/env bash
set -euo pipefail
RCLONE_ARGS="--create-empty-src-dirs --drive-acknowledge-abuse --drive-skip-gdocs --drive-skip-shortcuts --drive-skip-dangling-shortcuts --metadata --fast-list --links"

echo "Running my_provisioning.sh..."
ls /
# Activate the main Python environment in case we need dateutil, etc.
source /venv/main/bin/activate

########### Additional envars from git
# 1) Download the vars.conf file from GitHub
echo "Fetching environment variables from GitHub..."
wget -q -O /tmp/vars.conf \
  "https://raw.githubusercontent.com/adam-securafort/ML-config/refs/heads/main/vars.conf"

if [[ ! -s /tmp/vars.conf ]]; then
  echo "ERROR: /tmp/vars.conf is empty or missing. Aborting provisioning."
  exit 1
fi

# 2) Export each line into environment variables for subsequent commands in this script
echo "Applying environment variables from /tmp/vars.conf..."
while IFS='=' read -r key val; do
  # Skip blank lines or comment lines if any
  [[ -z "$key" ]] && continue
  [[ "$key" =~ ^#.* ]] && continue

  # Safely export
  export "$key=$val"
done < /tmp/vars.conf

# Now the rest of this provisioning script can use $CURRENT_MODEL, $CURRENT_CONFIG, etc.
echo "Environment variable CURRENT_MODEL is set to: $CURRENT_MODEL"
echo "Environment variable AUTOBACKUP_FOLDER_NAME is set to: $AUTOBACKUP_FOLDER_NAME"

# 3) (Optional) If you want these env vars available to the entire container beyond
#    this script, append them to /etc/environment so that login shells and other processes
#    can see them. This is helpful if your trainer or other services need them.
while IFS='=' read -r key val; do
  [[ -z "$key" ]] && continue
  [[ "$key" =~ ^#.* ]] && continue
  echo "$key='$val'" >> /etc/environment
done < /tmp/vars.conf

echo "Done fetching environment variables from GitHub."

echo "Adding 'docker-latest' alias to root's .bashrc..."
cat <<'EOF' >> /home/user/.bashrc
# Alias to attach to the most recently launched container (sorted by newest at the top):
alias docker-exec='docker exec -it $(docker ps -q | head -n1) /bin/bash'
EOF
echo "Alias 'docker-exec' added to /root/.bashrc"

# Configure rclone. Environment variables must be set at runtime or via the Vast.ai UI.
mkdir -p /root/.config/rclone
cat <<EOF >/root/.config/rclone/rclone.conf
[drive]
type = drive
client_id = "595617756164-ojobrnulu3lrk2g74f48c20d8vpchjiu.apps.googleusercontent.com"
client_secret = ${R_CLIENT_S:-dummySecret}
scope = drive
token = ${R_T:-dummyToken}
team_drive =

[secret]
type = crypt
remote = drive
password = ${R_CRYPT_S:-mypassword}
filename_encryption = standard
directory_name_encryption = false
EOF

echo "rclone config created at /root/.config/rclone/rclone.conf"

rclone copy "secret:/live/models" "/workspace/deep/models" $RCLONE_ARGS --log-file "/root/.config/rclone/rclone.log" --exclude '**/*autobackups*/**' --exclude '**/*.face_cache*/**' 
rclone copy "secret:/live/images.tar" "/workspace/deep/" $RCLONE_ARGS --log-file "/root/.config/rclone/rclone.log"
tar -xvf /workspace/deep/images.tar -C /workspace/deep/

# If we only want to download the latest backups once, we do it here.
# Suppose we rely on CURRENT_MODEL, AUTOBACKUP_FOLDER_NAME, and so on.
if [[ -n "${AUTOBACKUP_FOLDER_NAME:-}" ]]; then
    echo "Restoring the top 3 subfolders from remote backups..."
    python /workspace/restore_latest_backups.py
else
    echo "AUTOBACKUP_FOLDER_NAME is not set, skipping top-3 backup restore."
fi


# symlinks

ln -s $CURRENT_MODEL /workspace/trainer/current_model
ln -s $CURRENT_CONFIG /workspace/trainer/current_config
ln -s $CURRENT_SRC /workspace/trainer/current_src
ln -s $CURRENT_DST /workspace/trainer/current_dst

# Cron is already installed and the cron file is in /etc/cron.d. This just ensures it's recognized.
crontab /etc/cron.d/deep-crontab || echo "Cron config might be loaded automatically."

echo "Provisioning is complete."

