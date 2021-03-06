#!/bin/sh /etc/rc.common
# Copyright (C) 2006-2011 OpenWrt.org

START=99
STOP=98

if grep -q 'processor.*: 2' /proc/cpuinfo; then
	eth_core_offset=4
	lan_queue_offset=4
	wan_queue_offset=1
	wifi_core=8
	queue_core_count=2
elif grep -q 'processor.*: 1' /proc/cpuinfo; then
	eth_core_offset=1
	lan_queue_offset=1
	wan_queue_offset=1
	wifi_core=2
	queue_core_count=2
else
	return
fi

usb_core=1

assign_interface_round() {
	local interface=$1
	local cpu_offset=$2
	local count=$3
	
	local index=1
	local cpu=$cpu_offset
	for mask in /sys/class/net/$interface/queues/rx-[0-9]*/rps_cpus
	do
		echo $cpu > $mask
		echo 256 > `dirname $mask`/rps_flow_cnt
		if [ $index -lt $count ]
		then
			cpu=`expr $cpu \* 2`
			index=`expr $index + 1`
		else
			cpu=$cpu_offset
			index=1
		fi
	done
	
	index=1
	cpu=$cpu_offset
	for mask in /sys/class/net/$interface/queues/tx-[0-9]*/xps_cpus
	do
		echo $cpu > $mask
		if [ $index -lt $count ]
		then
			cpu=`expr $cpu \* 2`
			index=`expr $index + 1`
		else
			cpu=$cpu_offset
			index=1
		fi
	done
}

assign_interface() {
	local interface=$1
	local cpu_mask=$2

	for mask in /sys/class/net/$interface/queues/rx-[0-9]*/rps_cpus
	do
		echo $cpu_mask > $mask
		echo 256 > `dirname $mask`/rps_flow_cnt
	done

	for mask in /sys/class/net/$interface/queues/tx-[0-9]*/xps_cpus
	do
		echo $cpu_mask > $mask
	done
}

assign_queues() {
	for netpath in /sys/class/net/eth[0-9]*; do
		eth=`basename $netpath`
		
	done
	
	echo "binding cpu for eth0.1"
	assign_interface_round eth0.1 $lan_queue_offset $queue_core_count
	which ethtool > /dev/null 2>&1 && ethtool -K eth0.1 gro on
	
	echo "binding cpu for eth0.2"
	assign_interface_round eth0.2 $wan_queue_offset $queue_core_count
	which ethtool > /dev/null 2>&1 && ethtool -K eth0.2 gro on
	
	for netpath in /sys/class/net/ra[i0-9]*; do
		wlan=`basename $netpath`
		echo "binding cpu for $wlan"

		assign_interface_round $wlan $lan_queue_offset $queue_core_count
	done

	echo 1024 > /proc/sys/net/core/rps_sock_flow_entries
}

# set net interface queue mask -- /sys/class/net/eth*/queues/rx-*/rps_cpus
set_mask() {
	echo "set mask $2 for irq: $1"
	echo "$2" > "/proc/irq/$1/smp_affinity"
}

set_mask_pattern() {
	local name_pattern="$1"
	local mask="$2"
	
	for irq in `grep "$name_pattern" /proc/interrupts | cut -d: -f1 | sed 's, *,,'`
	do
		set_mask $irq $mask
	done
}

set_mask_index() {
	local name_pattern="$1"
	local index="$2"
	local mask="$3"
	
	set_mask `grep -m$index "$name_pattern" /proc/interrupts | cut -d: -f1 | tail -n1 | tr -d ' '` $mask
}

set_mask_range() {
	local name_pattern="$1"
	local start="$2"
	local end="$3"
	local mask="$4"
	
	local count=`expr $end - $start + 1`
	for irq in `grep "$name_pattern" /proc/interrupts | cut -d: -f1 | head -n$end | tail -n$count | sed 's, *,,'`
	do
		set_mask $irq $mask
	done
}

set_mask_interleave() {
	local name_pattern=$1
	local cpu_offset=$2
	local cpu_count=$3
	local step_size=$4
	
	local step_counter=1
	local cpu_counter=1
	local mask=$cpu_offset
	for irq in `grep "$name_pattern" /proc/interrupts | cut -d: -f1 | sed 's, *,,'`
	do
		set_mask $irq $mask
		if [ $step_counter -eq $step_size ]
		then
			step_counter=1
			if [ $cpu_counter -eq $cpu_count ]
			then
				mask=$cpu_offset
				cpu_counter=1
			else
				mask=`expr $mask \* 2`
				cpu_counter=`expr $cpu_counter + 1`
			fi
		else
			step_counter=`expr $step_counter + 1`
		fi
	done
}

set_mask_interleave_reverse() {
	local name_pattern=$1
	local cpu_offset=$2
	local cpu_count=$3
	local step_size=$4
	
	local step_counter=1
	local cpu_counter=1
	local mask=$cpu_offset
	for irq in `grep "$name_pattern" /proc/interrupts | cut -d: -f1 | sed 's, *,,'`
	do
		set_mask $irq $mask
		if [ $step_counter -eq $step_size ]
		then
			step_counter=1
			if [ $cpu_counter -eq $cpu_count ]
			then
				mask=$cpu_offset
				cpu_counter=1
			else
				mask=`expr $mask / 2`
				cpu_counter=`expr $cpu_counter + 1`
			fi
		else
			step_counter=`expr $step_counter + 1`
		fi
	done
}

# set irq mask -- /sys/irq/*/smp_affinity
set_irq_mask() {
	#ethernet
	set_mask_pattern eth $eth_core_offset
	set_mask_pattern esw $eth_core_offset

	#wifi
	set_mask_pattern ra[i0-9] $wifi_core

	#usb
	set_mask_pattern usb $usb_core
}

start() {
	assign_queues
	set_irq_mask
}
