#!/bin/sh
# Initialization:

export OCF_ROOT=/usr/lib/ocf/

OCF_RESKEY_interface=$1


: ${OCF_FUNCTIONS_DIR=${OCF_ROOT}/lib/heartbeat}
. ${OCF_FUNCTIONS_DIR}/ocf-shellfuncs

#
# Return true, if the interface exists
#
is_interface() {
	#
	# List interfaces but exclude FreeS/WAN ipsecN virtual interfaces
	#
	local iface=`$IP2UTIL -o -f inet addr show | grep " $1 " \
		| cut -d ' ' -f2 | sort -u | grep -v '^ipsec[0-9][0-9]*$'`
		[ "$iface" != "" ]
}

if_init() {
	local rc

	if [ X"$OCF_RESKEY_interface" = "X" ]; then
		ocf_log err "Interface name (the interface parameter) is mandatory"
		exit $OCF_ERR_CONFIGURED
	fi

	NIC="$OCF_RESKEY_interface"

	if is_interface $NIC
	then
		case "$NIC" in
			*:*) ocf_log err "Do not specify a virtual interface : $OCF_RESKEY_interface"
				 exit $OCF_ERR_CONFIGURED;;
			*)   ;;
		esac
	else
		case $__OCF_ACTION in
			validate-all)
				ocf_log err "Interface $NIC does not exist"
				exit $OCF_ERR_CONFIGURED;;
			*)	
				## It might be a bond interface which is temporarily not available, therefore we want to continue here
				ocf_log warn "Interface $NIC does not exist"
				;;
		esac
	fi

	: ${OCF_RESKEY_multiplier:="1"}
	if ! ocf_is_decimal "$OCF_RESKEY_multiplier"; then
		ocf_log err "Invalid OCF_RESKEY_multiplier [$OCF_RESKEY_multiplier]"
		exit $OCF_ERR_CONFIGURED
	fi
	
	ATTRNAME=${OCF_RESKEY_name:-"ethmonitor-$NIC"}
	
	REP_COUNT=${OCF_RESKEY_repeat_count:-5}
	if ! ocf_is_decimal "$REP_COUNT" -o [ $REP_COUNT -lt 1 ]; then
		ocf_log err "Invalid OCF_RESKEY_repeat_count [$REP_COUNT]"
		exit $OCF_ERR_CONFIGURED
	fi
	REP_INTERVAL_S=${OCF_RESKEY_repeat_interval:-10}
	if ! ocf_is_decimal "$REP_INTERVAL_S"; then
		ocf_log err "Invalid OCF_RESKEY_repeat_interval [$REP_INTERVAL_S]"
		exit $OCF_ERR_CONFIGURED
	fi
	: ${OCF_RESKEY_pktcnt_timeout:="5"}
	if ! ocf_is_decimal "$OCF_RESKEY_pktcnt_timeout"; then
		ocf_log err "Invalid OCF_RESKEY_pktcnt_timeout [$OCF_RESKEY_pktcnt_timeout]"
		exit $OCF_ERR_CONFIGURED
	fi
	: ${OCF_RESKEY_arping_count:="1"}
	if ! ocf_is_decimal "$OCF_RESKEY_arping_count"; then
		ocf_log err "Invalid OCF_RESKEY_arping_count [$OCF_RESKEY_arping_count]"
		exit $OCF_ERR_CONFIGURED
	fi
	: ${OCF_RESKEY_arping_timeout:="1"}
	if ! ocf_is_decimal "$OCF_RESKEY_arping_timeout"; then
		ocf_log err "Invalid OCF_RESKEY_arping_timeout [$OCF_RESKEY_arping_count]"
		exit $OCF_ERR_CONFIGURED
	fi
	: ${OCF_RESKEY_arping_cache_entries:="5"}
	if ! ocf_is_decimal "$OCF_RESKEY_arping_cache_entries"; then
		ocf_log err "Invalid OCF_RESKEY_arping_cache_entries [$OCF_RESKEY_arping_cache_entries]"
		exit $OCF_ERR_CONFIGURED
	fi
	return $OCF_SUCCESS
}

# get the link status on $NIC
# asks ip about running (up) interfaces, returns the number of matching interface names that are up
get_link_status () {
	$IP2UTIL -o link show up dev "$NIC" | grep -v 'NO-CARRIER' | grep -c "$NIC"
}

# returns the number of received rx packets on $NIC
get_rx_packets () {
	ocf_log debug "$IP2UTIL -o -s link show dev $NIC"
	$IP2UTIL -o -s link show dev "$NIC" \
		| sed 's/.* RX: [^0-9]*[0-9]* *\([0-9]*\) .*/\1/'
		# the first number after RX: ist the # of bytes ,
		# the second is the # of packets received
}

# watch for packet counter changes for max. OCF_RESKEY_pktcnt_timeout seconds
# returns immedeately with return code 0 if any packets were received
# otherwise 1 is returned
watch_pkt_counter () {
	local RX_PACKETS_NEW
	local RX_PACKETS_OLD
	RX_PACKETS_OLD="`get_rx_packets`"
	for n in `seq $(( $OCF_RESKEY_pktcnt_timeout * 10 ))`; do
		sleep 0.1
		RX_PACKETS_NEW="`get_rx_packets`"
		ocf_log debug "RX_PACKETS_OLD: $RX_PACKETS_OLD	RX_PACKETS_NEW: $RX_PACKETS_NEW"
		if [ "$RX_PACKETS_OLD" -ne "$RX_PACKETS_NEW" ]; then
			ocf_log debug "we received some packets."
			return 0
		fi
	done
	return 1
}

# returns list of cached ARP entries for $NIC
# sorted by age ("last confirmed")
# max. OCF_RESKEY_arping_cache_entries entries
get_arp_list () {
	$IP2UTIL -s neighbour show dev $NIC \
		| sort -t/ -k2,2n | cut -d' ' -f1 \
		| head -n $OCF_RESKEY_arping_cache_entries
		# the "used" entries in `ip -s neighbour show` are:
		# "last used"/"last confirmed"/"last updated"
}

# arping the IP given as argument $1 on $NIC
# until OCF_RESKEY_arping_count answers are received
do_arping () {
	# TODO: add the source IP
	# TODO: check for diffenrent arping versions out there

	ocf_log debug "running --- arping -q -c $OCF_RESKEY_arping_count -w $OCF_RESKEY_arping_timeout -I $NIC $1"
	arping -c $OCF_RESKEY_arping_count -w $OCF_RESKEY_arping_timeout -I $NIC $1
	ocf_log debug "arping res $?"
	# return with the exit code of the arping command 
	return $?
}

#
# Check the interface depending on the level given as parameter: $OCF_RESKEY_check_level
#
# 09: check for nonempty ARP cache
# 10: watch for packet counter changes
#
# 19: check arping_ip_list
# 20: check arping ARP cache entries
# 
# 30:  watch for packet counter changes in promiscios mode
# 
# If unsuccessfull in levels 18 and above,
# the tests for higher check levels are run.
#
if_check () {
	local arp_list
	# always check link status first
	link_status="`get_link_status`"
	ocf_log debug "link_status: $link_status (1=up, 0=down)"

	if [ $link_status -eq 0 ]; then
		ocf_log notice "link_status: DOWN"
		return $OCF_NOT_RUNNING
	fi

	# watch for packet counter changes
	ocf_log debug "watch for packet counter changes"
	watch_pkt_counter
	if [ $? -eq 0 ]; then
		return $OCF_SUCCESS
	else 
		ocf_log info "No packets received during packet watch timeout"
	fi

	# check arping ARP cache entries
	ocf_log debug "check arping ARP cache entries"
	arp_list=`get_arp_list`
	ocf_log debug "arp list $arp_list"
	for ip in `echo $arp_list`; do
		do_arping $ip && return $OCF_SUCCESS
	done

	# if we get here, the ethernet device is considered not running.
	# provide some logging information
	if [ -z "$arp_list" ]; then
		ocf_log info "No ARP cache entries found to arping" 
	fi

	# watch for packet counter changes in promiscios mode
#	ocf_log debug "watch for packet counter changes in promiscios mode" 
	# be sure switch off promiscios mode in any case
	# TODO: check first, wether promisc is already on and leave it untouched.
#	trap "$IP2UTIL link set dev $NIC promisc off; exit" INT TERM EXIT
#		$IP2UTIL link set dev $NIC promisc on
#		watch_pkt_counter && return $OCF_SUCCESS
#		$IP2UTIL link set dev $NIC promisc off
#	trap - INT TERM EXIT

	# looks like it's not working (for whatever reason)
	return $OCF_NOT_RUNNING
}

#######################################################################

if_usage() {
	cat <<END
usage: $0 {start|stop|status|monitor|validate-all|meta-data}

Expects to have a fully populated OCF RA-compliant environment set.
END
}

if_monitor() {
	local mon_rc=$OCF_NOT_RUNNING
	local runs=0
	local start_time
	local end_time
	local sleep_time
	while [ $mon_rc -ne $OCF_SUCCESS -a $REP_COUNT -gt 0 ]
	do
		start_time=`date +%s%N`
		if_check
		mon_rc=$?
		REP_COUNT=$(( $REP_COUNT - 1 ))
		if [ $mon_rc -ne $OCF_SUCCESS -a $REP_COUNT -gt 0 ]; then
			ocf_log warn "Monitoring of $OCF_RESOURCE_INSTANCE failed, $REP_COUNT retries left."
			end_time=`date +%s%N`
			sleep_time=`echo "scale=9; ( $start_time + ( $REP_INTERVAL_S * 1000000000 ) - $end_time ) / 1000000000" | bc -q 2> /dev/null`
			sleep $sleep_time 2> /dev/null
			runs=$(($runs + 1))
			ocf_log debug "sleep time $sleep_time"
		fi

		if [ $mon_rc -eq $OCF_SUCCESS -a $runs -ne 0 ]; then
			ocf_log info "Monitoring of $OCF_RESOURCE_INSTANCE recovered from error"
		fi
	done
	
	ocf_log debug "Monitoring return code: $mon_rc"
	if [ $mon_rc -ne $OCF_SUCCESS ]; then
		ocf_log err "Monitoring of $OCF_RESOURCE_INSTANCE failed."
	fi

	exit $mon_rc
}

if_validate() {
	check_binary $IP2UTIL
	check_binary arping
	if_init
}

if_validate

is_interface $1
echo "is_interface $?"
echo "get link status $(get_link_status)"
echo 'start link info'
$IP2UTIL -o link show up dev "$NIC"
echo 'end link info'


echo 'start rx packets'
$IP2UTIL -o -s link show dev "$NIC"
echo "rx packet sed filter"
$IP2UTIL -o -s link show dev "$NIC" | sed 's/.* RX: [^0-9]*[0-9]* *\([0-9]*\) .*/\1/'
echo 'end rx packets'

if_monitor
