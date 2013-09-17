#!/bin/bash

#
# Create iptables rules for application compartmentalization.
#
# The maximum UID our allocation mechanism scales to is 262143
UID_BEGIN=500
UID_END=16000                       # Large enough to cover the broker range
NTABLE="rhc-user-table"             # Switchyard for app UID tables

# Cross-app restrictions
UTABLE="rhc-app-table"
UIFACE="lo"
UWHOLE_NET="127.0.0.0"
UWHOLE_NM="8"
USAFE_NET="127.0.0.0"
USAFE_NM="25"
UAPP_BASE="127.0.0.0"  # UID 0
UAPP_NM="25"
# Example of use:
# iptables -I rhc-app-table -d 127.0.250.0/25 -m owner --uid-owner 500 -j ACCEPT


# Rules for allowing a UID to access a proxy
PORT_BEGIN=35531
PORT_END=65535


DEBUG=""
SYSCONFIG=""

function help {
  cat <<EOF >&2
Usage: $0 [ -h ] [ -i | -n | -s ] [ -b UID ] [ -e UID ] [ -t name ] [ -p name ] [ -i iface ]

    Basic options:
    -h       Print this message and exit.

    Output/execution type
    -i       Run iptables (default mode)
    -n       Print what would be done instead of calling iptables.
    -s       Print output suitable for /etc/sysconfig/iptables.

    Less common options that must remain consistent across invocation
    -b UID   Beginning UID.  (default: $UID_BEGIN)
    -e UID   Ending UID.  (default: $UID_END)
    -t name  Table Name (default: $UTABLE)
EOF
}

while getopts ':hinsb:e:t:p:' opt; do
  case $opt in
    'h')
      help
      exit 0
      ;;
    'i')
      DEBUG=""
      SYSCONFIG=""
      ;;
    'n')
      DEBUG=1
      ;;
    's')
      SYSCONFIG=1
      ;;
    'b')
      UID_BEGIN="${OPTARG}"
      ;;
    'e')
      UID_END="${OPTARG}"
      ;;
    't')
      UTABLE="${OPTARG}"
      ;;
    'p')
      PTABLE="${OPTARG}"
      ;;
    '?')
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    ':')
      echo "Option requires argument: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

# Test combinations of arguments for compatibility
if [ "${DEBUG}" = "1" -a "${SYSCONFIG}" = "1" ]; then
  echo "Debug (-n) and Sysconfig (-s) are mutually exclusive." >&2
  exit 1
fi

function iptables {
  if [ "${SYSCONFIG}" ]; then
    echo "$@"
  elif [ "${DEBUG}" ]; then
    echo /sbin/iptables "$@"
  else
    /sbin/iptables "$@"
  fi
}

function new_table {
  tbl="$2"
  if [ "$tbl" = "" ]; then
    tbl="filter"
  fi
  if [ "${SYSCONFIG}" ]; then
    echo ':'"$1"' - [0:0]'
  else
    iptables -t "$tbl" -N "$1" || :
    iptables -t "$tbl" -F "$1"
  fi
}

function decode_ip {
  ret=0
  quad=16777216
  for byt in `echo "$1" | sed -e 's/\./ /g'`; do
    ret=$(($ret + $(($byt * $quad))))
    quad=$(($quad/256))
  done

  echo $ret
}

function uid_to_ip {
  # This works on IPv4.  Switch to a real language
  # and use inet_ntop/inet_pton for ipv6.
  block=$((2**$((32 - $UAPP_NM))))
  start=`decode_ip $UAPP_BASE`

  a=$(($1*$block+$start))
  h1=$(($a/16777216))
  h2=$(($(($a%16777216))/65536))
  h3=$(($(($a%65536))/256))
  h4=$(($a%256))

  echo "${h1}.${h2}.${h3}.${h4}"
}


# INPUT rule to allow access to all proxy ports
iptables -I INPUT 4 -p tcp \
  -dport ${PORT_BEGIN}:${PORT_END} \
  -m state --state NEW \
  -j ACCEPT

# Create the table and clear it
new_table ${UTABLE}

# Bottom block is system services
iptables -A OUTPUT -o ${UIFACE} -d ${USAFE_NET}/${USAFE_NM} \
  -m owner --uid-owner ${UID_BEGIN}-${UID_END} \
  -j ACCEPT

# Established connections allowed
iptables -A OUTPUT -o ${UIFACE} \
  -m owner --uid-owner ${UID_BEGIN}-${UID_END} \
  -m state --state ESTABLISHED,RELATED \
  -j ACCEPT


# New connections with specific uids get checked on the app table.
iptables -A OUTPUT -o ${UIFACE} -d ${UWHOLE_NET}/${UWHOLE_NM} \
  -m state --state NEW \
  -j ${UTABLE}

seq ${UID_BEGIN} ${UID_END} | while read uid; do
  iptables -A ${UTABLE} -d `uid_to_ip $uid`/${UAPP_NM} \
    -m owner --uid-owner $uid \
    -j ACCEPT
done

iptables -A ${UTABLE} -j REJECT --reject-with icmp-host-prohibited

