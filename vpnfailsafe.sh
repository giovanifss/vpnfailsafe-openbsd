#!/bin/sh

DNS_SERVERS=
COMMON_NAME=
REMOTE_IPS=
REMOTE_PORTS=
REMOTE_PROTOS=
ROUTE_NET_GATEWAY_IP=
ROUTE_VPN_GATEWAY_IP=

readonly END="#----- END KILLSWITCH -----"
readonly BEG="#----- BEGIN KILLSWITCH -----"
readonly IP_REGEX='^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
readonly PORT_REGEX='^([0-9]{1,4}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$'
readonly PROTO_REGEX='^(udp|tcp)$'
readonly DOMAIN_REGEX='^([a-zA-Z0-9-]{1,63}\.){0,6}[a-zA-Z0-9-]{1,63}$'


echoerr () {
    echo "$(date '+%a %b %e %H:%M:%S %Y')" "$@" 1>&2
}

backup_and_replace () {
    cp "$1" "$1.bkp"
    permissions=$(stat -f "%OLp" "$1")
    chmod "$permissions" "$1.killswitch"
    mv "$1.killswitch" "$1"
}

setup_remote_variables () {
    total_count=$(env | grep '^remote_[0-9]' | wc -l)

    REMOTE_IPS=$(env | grep '^remote_[0-9]' | 
                cut -d '=' -f2 | grep -oE "$IP_REGEX")
    if [ $(echo "$REMOTE_PORTS" | wc -l) -ne $total_count ]; then
        echoerr "$0: some remote do not have a valid IP address"
        exit 1
    fi

    REMOTE_PORTS=$(env | grep '^remote_port_[0-9]' | \
                cut -d '=' -f2 | grep -oE "$PORT_REGEX")
    if [ $(echo "$REMOTE_PORTS" | wc -l) -ne $total_count ]; then
        echoerr "$0: some remote do not have a valid port number"
        exit 1
    fi

    REMOTE_PROTOS=$(env | grep '^proto_[0-9]' | \
                cut -d '=' -f2 | grep -oE "$PROTO_REGEX")
    if [ $(echo "$REMOTE_PROTOS" | wc -l) -ne $total_count ]; then
        echoerr "$0: some remote do not have a valid protocol"
        exit 1
    fi
}

setup_dns_variables () {
    DNS_SERVERS=$(env | grep '^foreign_option' | cut -d '=' -f2 | \
                grep '^dhcp-option DNS' | cut -d ' ' -f3)

    if [ -z "$DNS_SERVERS" ]; then
        echoerr "$0: WARNING: no DNS was pushed by the VPN server, " \
                "this may cause a DNS leak"
    else
        DNS_SERVERS=$(echo "$DNS_SERVERS" | grep -oE "$IP_REGEX")
        if [ -z "$DNS_SERVERS" ]; then
            echoerr "$0: a pushed DNS server do not have a valid IP"
            exit 2
        fi
    fi
}

setup_network_interface_variables () {
    result=$(ifconfig "$dev")
    if [ $? -ne 0 ]; then
        echoerr "$0: invalid VPN network interface name"
        exit 3
    fi
}

setup_domain_variables () {
    COMMON_NAME=$(echo "$common_name" | cut -d '=' -f2 | \
                grep -oE "$DOMAIN_REGEX")
    if [ -z "$COMMON_NAME" ]; then
        echoerr "$0: common_name is not a valid domain"
        exit 4
    fi
}

setup_route_variables () {
    ROUTE_NET_GATEWAY_IP=$(echo "$route_net_gateway" | cut -d '=' -f2 | \
                grep -oE "$IP_REGEX")
    if [ -z "$ROUTE_NET_GATEWAY_IP" ]; then
        echoerr "$0: route_net_gateway is not a valid IP address"
        exit 5
    fi

    ROUTE_VPN_GATEWAY_IP=$(echo "$route_vpn_gateway" | cut -d '=' -f2 | \
                grep -oE "$IP_REGEX")
    if [ -z "$ROUTE_VPN_GATEWAY_IP" ]; then
        echoerr "$0: route_vpn_gateway is not a valid IP address"
        exit 5
    fi
}

setup_up_variables () {
    setup_dns_variables
    setup_network_interface_variables
    setup_domain_variables
    setup_route_variables
}

setup_hosts () {
    remote_entries=$(getent hosts "$COMMON_NAME" $REMOTE_IPS)
    if [ ! -z "$remote_entries" ]; then
        {
            sed -e "/^$BEG/,/^$END/d" /etc/hosts
            echo "$BEG"
            echo "$remote_entries"
            echo "$END"
        } > /etc/hosts.killswitch
        backup_and_replace "/etc/hosts"
    fi
}

setup_resolv () {
    if [ ! -z "$DNS_SERVERS" ]; then
        previous=$(cat /etc/resolv.conf | grep -v 'nameserver')
        {
            echo "$previous"
            echo "$BEG"
            for server in $DNS_SERVERS; do
                echo "nameserver $server"
            done
            echo "$END"
        } > /etc/resolv.conf.killswitch
        backup_and_replace "/etc/resolv.conf"
    fi
}

cleanup_resolv () {
    if [ -f /etc/resolv.conf.bkp ]; then
        mv /etc/resolv.conf.bkp /etc/resolv.conf
    else
        echoerr "$0: no backup found for /etc/resolv.conf"
    fi
}

setup_routes () {
    current_routes=$(route -n show)
    for ip in $REMOTE_IPS; do
        echo "$current_routes" | grep -q "$ip"
        if [ $? -ne 0 ]; then
            route add -host "$ip" "$ROUTE_NET_GATEWAY_IP"
        fi
    done
    route add -net 0.0.0.0/1 "$ROUTE_VPN_GATEWAY_IP"
    route add -net 128.0.0.0/1 "$ROUTE_VPN_GATEWAY_IP"
}

cleanup_routes () {
    current_routes=$(route -n show)
    for route in $REMOTE_IPS 0.0.0.0/1 128.0.0.0/1; do
        echo "$current_routes" | grep -q "$route"
        if [ $? -eq 0 ]; then
            route delete "$route"
        fi
    done
}

setup_pf () {
    {
        echo "block drop in"
        echo "block return out"
        echo "pass in on egress proto udp from any port 67 to any port 68"
        echo "pass out on $dev all"
        while [ ! -z "$REMOTE_IPS" ]; do
            ip=$(echo "$REMOTE_IPS" | head -n1)
            port=$(echo "$REMOTE_PORTS" | head -n1)
            proto=$(echo "$REMOTE_PROTOS" | head -n1)
            echo "pass out on egress proto $proto from any to" \
                    "$ip port $port"
            REMOTE_IPS=$(echo "$REMOTE_IPS" | tail -n+2)
            REMOTE_PORTS=$(echo "$REMOTE_PORTS" | tail -n+2)
            REMOTE_PROTOS=$(echo "$REMOTE_PROTOS" | tail -n+2)
        done
    } | pfctl -f -
}

main () {
    setup_remote_variables
    case "${script_type:-down}" in
        up)
            setup_up_variables
            setup_hosts
            setup_routes
            setup_resolv
            setup_pf;;
        down)
            cleanup_routes
            cleanup_resolv;;
    esac
}

main
