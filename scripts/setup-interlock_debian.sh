#!/usb/bin/env bash

# Setup interlock on 'usbarmory-debian-base_image'
# INTERLOCK - file encryption front end

INTERLOCK_REPO_TAG="v2019.01.30"	# use this tag for signal support

# add andrea (inversepath) gpg key
sudo apt-key adv --keyserver keyserver.ubuntu.com --recv 73C9E98B25B61D15
wget http://keys.inversepath.com/gpg-andrea.asc -O gpg-andrea.asc
gpg --import gpg-andrea.asc

# create 2nd primary partition with parted
sudo apt update
sudo apt install -y parted
sudo parted -s /dev/mmcblk0 unit mib mkpart primary 3670MB 100%
sudo parted -s /dev/mmcblk0 print
sudo partprobe

sudo pvcreate /dev/mmcblk0p2                   		# initialize physical volume
sudo vgcreate lvmvolume /dev/mmcblk0p2         		# create volume group
sudo lvcreate -l 100%FREE -n encryptedfs lvmvolume	# create logical volume of 20 GB

# set-up encrypted partition, with default cryptsetup settings (Type YES)
sudo cryptsetup -y --cipher aes-xts-plain64 --key-size 256 --hash sha1 luksFormat /dev/lvmvolume/encryptedfs
sudo cryptsetup luksOpen /dev/lvmvolume/encryptedfs interlockfs

# list pv, vg, lv(s)
pvscan -v
vgscan -v
lvscan -va


# create ext4 filesystem
sudo mkfs.ext4 /dev/mapper/interlockfs         

# lock volume
sudo cryptsetup luksClose interlockfs

# add user interlock
sudo useradd -m -d /home/interlock interlock
sudo usermod --shell /bin/bash interlock
sudo passwd interlock

# setup golang
sudo apt update
sudo apt install -y xz-utils git gcc make binutils net-tools libcap2-bin policykit-1
wget https://dl.google.com/go/go1.13.3.linux-armv6l.tar.gz
sudo tar -C /usr/local -xzf go1.13.3.linux-armv6l.tar.gz

cat >> ~/.bashrc << EOF

# golang
export PATH=$PATH:/usr/local/go/bin
export GOPATH=$HOME/go
EOF

sudo apt remove golang
sudo apt-get autoremove

# setup certificates
mkdir certs
pushd certs || exit
openssl req -newkey rsa:2048 -new -nodes -x509 -days 3650 -keyout key.pem -out cert.pem
popd
test -d /etc/interlock && sudo mkdir /etc/interlock
sudo mv certs /etc/interlock/certs

sudo bash -c 'cat > /etc/interlock/interlock.conf' << EOF
{
  "debug": false,
  "static_path": "/usr/share/interlock/static",
  "set_time": true,
  "bind_address": "10.0.0.1:4430",
  "tls": "on",
  "tls_cert": "/etc/interlock/certs/cert.pem",
  "tls_key": "/etc/interlock/certs/key.pem",
  "tls_client_ca": "",
  "hsm": "off",
  "key_path": "keys",
  "volume_group": "lvmvolume",
  "ciphers": [
          "OpenPGP",
          "AES-256-OFB",
          "TOTP",
          "Signal"
  ]
}
EOF
sudo chown interlock:interlock -Rv /etc/interlock

# compile interlock
cd /tmp && git clone https://github.com/inversepath/interlock.git
cd /tmp/interlock || exit
git fetch --all --tags
git checkout "${INTERLOCK_REPO_TAG}" -b with-signal-support
git describe --tags | grep "${INTERLOCK_REPO_TAG}" || exit
git submodule init
git submodule update
make with_signal
sudo cp -av /tmp/interlock/interlock /usr/local/sbin/interlock
sudo chown interlock:interlock /usr/local/sbin/interlock
sudo /sbin/setcap 'cap_net_bind_service=+ep' /usr/local/sbin/interlock
sudo /sbin/getcap /usr/local/sbin/interlock

# setup web interface
sudo mkdir -p /usr/share/interlock/static/
sudo rsync -rxvH --links /tmp/interlock/static/ /usr/share/interlock/static/
sudo chown interlock:interlock -Rv /usr/share/interlock/

# create interlock.service and sudo
sudo bash -c 'cat > /etc/systemd/system/interlock.service' << EOF
[Unit]
Description=INTERLOCK file encryption front-end
Documentation=https://github.com/inversepath/interlock/blob/master/README.md
Requires=network.target
After=network.target

[Service]
PermissionsStartOnly=true
ExecStartPre=/sbin/setcap 'cap_net_bind_service=+ep' /usr/local/sbin/interlock
ExecStart=/usr/local/sbin/interlock -c /etc/interlock/interlock.conf
User=interlock
Group=interlock
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

sudo bash -c 'cat >> /etc/sudoers' << EOF
interlock ALL=(root) NOPASSWD:							\
	/bin/date -s @*,							\
	/sbin/poweroff,								\
        /sbin/setcap 'cap_net_bind_service=+ep' /usr/local/sbin/interlock,      \
	/bin/mount /dev/mapper/interlockfs /home/interlock/.interlock-mnt,	\
	/bin/umount /home/interlock/.interlock-mnt,				\
	/bin/chown interlock /home/interlock/.interlock-mnt,			\
	/sbin/cryptsetup luksOpen /dev/lvmvolume/* interlockfs,			\
	!/sbin/cryptsetup luksOpen /dev/lvmvolume/*.* *,			\
	/sbin/cryptsetup luksClose /dev/mapper/interlockfs,			\
	!/sbin/cryptsetup luksClose /dev/mapper/*.*,				\
	/sbin/cryptsetup luksChangeKey /dev/lvmvolume/*,			\
	!/sbin/cryptsetup luksChangeKey /dev/lvmvolume/*.*,			\
	/sbin/cryptsetup luksRemoveKey /dev/lvmvolume/*,			\
	!/sbin/cryptsetup luksRemoveKey /dev/lvmvolume/*.*,			\
	/sbin/cryptsetup luksAddKey /dev/lvmvolume/*,				\
	!/sbin/cryptsetup luksAddKey /dev/lvmvolume/*.*
EOF

# remove permissions of other users
sudo chmod o-rwx -Rv -- /home/interlock/
sudo chmod o-rwx /home/interlock/.interlock-mnt

# enable interlock service
sudo systemctl enable interlock.service
sudo systemctl is-enabled interlock.service

# start interlock service
sudo systemctl start interlock.service
sudo systemctl is-active interlock.service

# check service status
sudo systemctl status interlock.service