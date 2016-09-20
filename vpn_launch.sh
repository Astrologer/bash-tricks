#!/bin/bash

if [ $# -ne 1 -o ! -f "$1" ]; then
    echo -e "Usage: `basename $0`\t<openvpn config file name>"
    exit
fi

VPN_CONFIG=$PWD/`basename $1`
ROUTE_TABLE=113

VPN_LOG=$(mktemp /tmp/vpn_XXXXXX.log)
VPN_SCRIPT=$(mktemp /tmp/vpn_XXXXXX.sh)
PID_TAIL=$(mktemp /tmp/pid_XXXXXX)
chmod a+x $VPN_SCRIPT

read -p "Enter Auth Username:" user
read -s -p "Enter Auth Password:" password; echo
read -p "Enter Google Authenticator Code:" code

export VPN_LOG
export user
export password
export code

cat > $VPN_SCRIPT << EOF
#!/bin/bash
echo -en "\$user\n\$password\n\$code\n" | openvpn --route-noexec --config $VPN_CONFIG > \$VPN_LOG
EOF


daemon -U $VPN_SCRIPT

(tail -f $VPN_LOG & echo $!> $PID_TAIL)| timeout 30 grep -q "Initialization Sequence Completed"
kill `cat $PID_TAIL`
gateway=$(cat $VPN_LOG | grep PUSH_REPLY | sed s/.*route-gateway\ // | sed s/,.*//)
device=$(cat $VPN_LOG | grep device | sed s/.*device\ // | sed s/\ .*//)

if [ "$device" == "" -o "$gateway" == "" ]; then
    cat $VPN_LOG
    exit
fi

echo VPN started with device $device and gateway $gateway

if [ ! `ip netns list | grep vpn` ]; then
    ip netns add vpn
    ip link add veth0 type veth peer name veth1
    ifconfig veth0 10.0.0.1
    ip link set veth1 netns vpn
    ip netns exec vpn ifconfig veth1 10.0.0.2
    ip netns exec vpn route add default gw 10.0.0.1 veth1
    ip rule add iif veth0 table $ROUTE_TABLE
fi

iptables -t nat -A POSTROUTING -o $device -j MASQUERADE
ip route add default via $gateway dev $device table $ROUTE_TABLE
echo 1 > /proc/sys/net/ipv4/ip_forward

ip netns exec vpn sudo -u "#$SUDO_UID" -g "#$SUDO_GID" bash
export PS1=(vpn)$PS1

rm -f $VPN_LOG
rm -f $VPN_SCRIPT
rm -f $PID_TAIL
