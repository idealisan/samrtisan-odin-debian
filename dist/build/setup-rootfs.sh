#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
R=/mnt/debian

# --- user & sudo ---
chroot $R useradd -m -s /bin/bash -G sudo user
echo "user:user" | chroot $R chpasswd
echo "root:*" | chroot $R chpasswd -e   # lock root password login

# --- base system identity ---
echo odin > $R/etc/hostname
sed -i "s/^127.0.1.1.*/127.0.1.1\todin/" $R/etc/hosts 2>/dev/null || echo "127.0.1.1	odin" >> $R/etc/hosts
cat > $R/etc/fstab << 'FSTAB'
/dev/disk/by-label/pmOS_root  /     ext4  defaults,noatime,errors=remount-ro  0 1
tmpfs                         /tmp  tmpfs defaults,nosuid                       0 0
FSTAB

# marker for initramfs fallback scan
touch $R/.odin-debian

# --- ssh: allow password auth ---
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' $R/etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/'            $R/etc/ssh/sshd_config
mkdir -p $R/run/sshd

# --- serial console getty ---
chroot $R systemctl enable serial-getty@ttyMSM0.service

# --- usb gadget + network service ---
cat > $R/usr/local/sbin/odin-usb-gadget.sh << 'GADGET'
#!/bin/bash
set -e
CFG=/sys/kernel/config/usb_gadget/odin
modprobe configfs 2>/dev/null || true
mount -t configfs none /sys/kernel/config 2>/dev/null || true
mkdir -p $CFG/functions/ncm.usb0 $CFG/configs/c.1
echo 0x18d1 > $CFG/idVendor
echo 0x4ee1 > $CFG/idProduct
echo "ODIN Debian" > $CFG/configs/c.1/strings/0x409/configuration 2>/dev/null || {
    mkdir -p $CFG/configs/c.1/strings/0x409; echo "ODIN Debian" > $CFG/configs/c.1/strings/0x409/configuration; }
ln -sf $CFG/functions/ncm.usb0 $CFG/configs/c.1/f1
UDC=$(ls /sys/class/udc | head -n1)
[ -n "$UDC" ] && echo "$UDC" > $CFG/UDC
sleep 1
ip link set usb0 up
ip addr add 172.16.42.1/24 dev usb0 2>/dev/null || true
# hand out one address to the host, pmOS-style
dnsmasq --no-daemon --pid-file=/run/odin-dnsmasq.pid --interface=usb0 \
    --bind-interfaces --dhcp-range=172.16.42.2,172.16.42.2,12h \
    --dhcp-option=option:router --no-resolv --no-hosts --log-facility=/var/log/odin-dnsmasq.log &
GADGET
chmod +x $R/usr/local/sbin/odin-usb-gadget.sh
cat > $R/etc/systemd/system/odin-usb-gadget.service << 'UNIT'
[Unit]
Description=ODIN USB NCM gadget (172.16.42.1) + dnsmasq
After=systemd-modules-load.service
Before=network.target sshd.service
[Service]
Type=forking
ExecStart=/usr/local/sbin/odin-usb-gadget.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
chroot $R systemctl enable odin-usb-gadget.service

# --- first-boot resize to fill userdata ---
cat > $R/usr/local/sbin/odin-firstboot-resize.sh << 'RESIZE'
#!/bin/bash
ROOTDEV=$(findmnt -n -o SOURCE /)
case "$ROOTDEV" in
  /dev/dm-*|/dev/mapper/*) exit 0 ;;
esac
growpart "$(dirname "$ROOTDEV" | sed 's|/dev$||;s|^$|/dev|')/$(basename "$ROOTDEV" | sed -E "s/p?[0-9]+$//")" \
         "$(basename "$ROOTDEV" | grep -oE "[0-9]+$")" >/dev/null 2>&1 || true
resize2fs "$ROOTDEV"
systemctl disable odin-firstboot-resize.service
RESIZE
chmod +x $R/usr/local/sbin/odin-firstboot-resize.sh
cat > $R/etc/systemd/system/odin-firstboot-resize.service << 'UNIT2'
[Unit]
Description=Grow root filesystem to fill userdata (one-shot)
After=local-fs.target
ConditionPathExists=!/var/lib/odin-resize-done
[Service]
Type=oneshot
ExecStart=/bin/sh -c '/usr/local/sbin/odin-firstboot-resize.sh && touch /var/lib/odin-resize-done'
[Install]
WantedBy=multi-user.target
UNIT2
chroot $R systemctl enable odin-firstboot-resize.service

# --- locale & misc ---
echo "en_US.UTF-8 UTF-8" > $R/etc/locale.gen
chroot $R locale-gen >/dev/null 2>&1 || true
chroot $R systemd-machine-id-setup 2>/dev/null || true

# --- enable ssh ---
chroot $R systemctl enable ssh.service
echo SETUP_DONE
