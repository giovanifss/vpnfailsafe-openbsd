# Vpnfailsafe OpenBSD
This is an OpenBSD port for the [vpnfailsafe](https://github.com/wknapik/vpnfailsafe) openvpn killswitch script.

## How does it work?
The vpnfailsafe OpenBSD essence is similar to the original vpnfailsafe. Basically, it will:
1) Resolve the VPN servers domains and save it in `/etc/hosts`;
2) Setup routes to make internet traffic go through the VPN tunnel. Currently, the script does not setup any
route to networks exposed by the VPN provider;
3) Update the nameservers in `/etc/resolv.conf` to force lookups to pushed DNS servers;
4) Overwride pf(4) ruleset, making it:
   - Allow only incoming DHCP responses;
   - For each VPN server, allow connections to the specific IP, port and protocol;
   - Block everything else.

Also, the behavior for `down` action is similar:
1) Keep `/etc/hosts` untouched, so further reconnections do not require a DNS lookup;
2) Remove previously added routes;
3) Restore `/etc/resolv.conf`;
4) Keep pf(4) ruleset, avoiding unwanted connections and allowing re-establishment of the VPN tunnel.

To return the ruleset to the original configuration, just `pfctl -f /etc/pf.conf`.

## Installation
To be able to use the killswitch, save the vpnfailsafe.sh script somewhere and make it executable.
Then, add the following lines to your OpenVPN configuration file (.ovpn, .conf):
```
script-security 2
up /path/to/script/vpnfailsafe.sh
down /path/to/script/vpnfailsafe.sh
```

## RTNETLINK File Exists Error
As explained [in the vpnfailsafe README](https://github.com/wknapik/vpnfailsafe#im-getting-an-rtnetlink-answers-file-exists-error-every-time-i-connect),
this error appear when OpenVPN tries to set up a route that was already created by vpnfailsafe.sh. Adding the
`route-noexec` option will tell OpenVPN to leave routing to vpnfailsafe.sh and prevent those errors from appearing.
