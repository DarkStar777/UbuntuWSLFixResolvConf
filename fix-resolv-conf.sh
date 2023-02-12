#!/bin/bash
# try to rewrite /etc/resolv.conf with current DNS configuration
# -q will skip rewrite if /etc/resolv.conf has been modified in past 2 hours

tmpfile="$(mktemp --suffix=-resolvconf)"
trap -- 'rm -f "$tmpfile"' EXIT
resolvfile="/etc/resolv.conf"

# quick mode, skip if resolv.conf has been modified recently
if [ "$1" = "-q" ]; then
    if  [ -z "$(find -L "$resolvfile" -mmin +120)" ]; then
        exit 0
    fi
fi

# make sure we're running as root
if [[ "$(/usr/bin/id -u)" != "0" ]]; then echo "ERROR: MUST RUN AS ROOT" 1>&2; exit 1; fi

pwsh() { /mnt/c/windows/System32/WindowsPowerShell/v1.0/powershell.exe "$@" | /usr/bin/tr -d '\r'; }

pwsh '
  Write-Output "# generated by fixvpn $(Get-Date)"

  ### attempt to get the right interface, uses technique to merge objects using Select-Object
  Get-NetIPInterface -AddressFamily IPv4 -ConnectionState "Connected" |
    sort -Property { $_.InterfaceMetric + $_.RouteMetric } | ### Try to order like windows would
    Select-Object *,@{Name="dns";Expression={(Get-DnsClientServerAddress -AddressFamily IPv4 -InterfaceIndex $_.InterfaceIndex).ServerAddresses}} |
    ?{$_.dns.Length -gt 0} | ### skip those with no dns server addresses
    Select-Object -First 1 | ### only get the first one (lowest metric wins)
    Select-Object -ExpandProperty dns |
    % {"nameserver $_"}

  (Get-DnsClientGlobalSetting).SuffixSearchList | % { "search $_" }
' < /dev/null > "$tmpfile"

### verify that the powershell output contains ONLY the expected lines
count=$(cat "$tmpfile" | egrep -v '^(#|search|nameserver)|^\s*$' | wc -c)
if [[ $count -lt 2 ]]; then
    cat "$tmpfile"
    cp --backup=simple -v "$tmpfile" "$resolvfile" 1>&2
    exit $?
else
    cat "$tmpfile"
    echo "ERROR: ${tmpfile} contains unexpected output" 1>&2
    exit 1
fi
