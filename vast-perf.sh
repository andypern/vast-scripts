#!/usr/bin/bash
# This script can be run either on a Vast-CNode, or another linux host.


#New stuff
# now supports loopback mode when there are vlan tag interfaces.
# In order to simplify usage...we no longer require any args. However:
#  * if you are _not_ running on a CNode, you must specify --vms=$vip


####Background/details##
##If you are running on a Vast-Cnode

# If you use 'modulo' for CN_DIST_MODE, it will require a larger VIP pool, specifically ($numCNodes + $JOBS) - 1.
# If running on a cluster with more than 8 CNodes, the script will not execute on the node holding VMS (this is to prevent OOM issues)
# If you notice issues on 8CN or smaller clusters where VMS crashes, set --usevms=false
# If you choose 'RDMA', the script will automatically change to TCP, because Vast-CNodes do not have RDMA-client packages.
# This script will temporarily adjust CNode <-> CNode routing tables to ensure that traffic does not cross the ISL's.
####

##When running on a non-vast client
## it requires that FIO 3.1 or higher is available on the host (by default it is on vast-cnodes)
# If FIO is in a different location than /usr/bin/fio : specify --binary=/path/to/fio
# you must make sure that the number of VIPs in the VIP-pool you use is at least equal to the number of jobs you are using.
# If you choose '--proto=rdma' : make sure that you have already setup and verified that you can mount NFS using RDMA.
#


###Behavior, 'best practices'
# You will want to run the write_bw test for at least 5 minutes (300 seconds) to blow through Optane buffers.
# The first time you run a read test, it may want to create some files as it reads, this will slow down the test, just re-run it until it stops trying to create files.
# When running on a Vast-cnode: start with JOBS=12 before testing with smaller values.  That way the files will get pre-created for subsequent runs.
# Refrain from pressing 'crtl-c' when you are performing write tests, or if you are performing read tests and you see that FIO is 'laying out .. files'.  Doing so may result in unkillable FIO processes
# If you press crtl-c during any test, then immediately re-run the script with the 'cleanup' job with --test=cleanup .This will ensure that mounts/etc are cleaned up.
# Minimal error checking is done.  incorrect usage may yield unexpected results.  Read through the 'Variables' section below and make sure you understand.
#####


###How to Run###


##Running on a CNode
# 1.  put this script on Cnode-1
# 2.  'bash /home/vastdata/vast-perf.sh'  <--only runs on one host it will run with config defaults (see below), and discover VMS ip.
# 3.  Once you verify it works, copy to all cnodes: `clush -g cnodes -c /home/vastdata/vast-perf.sh`.
# 4.  Run on all Cnodes like this `clush -g cnodes "bash /home/vastdata/vast-perf.sh"`
# 5.  Specify different tests with the '--test=' flag (write_bw , read_iops, write_iops)
# 6.  Run like this to clean everything up: `clush -g cnodes "bash /home/vastdata/vast-perf.sh --test=cleanup --delete=1"`
####

## Running on an external client ##
# you don't _need_ clustershell/clush , but it makes it easier to run this on multiple hosts.

# 1.  put this script on client-1 (whatever that is)
# 2.  'bash vast-perf.sh --vms=x.x.x.x --pool=2 --proto=rdma'  <--only runs on one host.
# 3.  Once you verify it works, copy to all hosts (using whatever mechanism you have)
# 4.  run on all hosts..here's a clush example, but pdsh/etc can work: clush -g clients "bash /home/vastdata/vast-perf.sh --vms=x.x.x.x"
# 5.  Specify different tests with the '--test=' flag (write_bw , read_iops, write_iops)
# 6.  Run like this to clean everything up: clush -g clients "bash /home/vastdata/vast-perf.sh --vms=x.x.x.x --test=cleanup --delete=1"


#=============================================================================
# Variables

# Below are defaults (which will get overridden by user specified ARGS).
# Don't set these variables directly, use the '--' args.

mVIP="empty"  # the VMS-VIP of the vast cluster you are testing against. If you run on CNodes, don't worry about setting.  If you run on an external client, you must specify the VMS-VIP with --vms=ip
NFSEXPORT="/" # the NFS export to use.  On a brand new cluster use '/' (no quotes)
TEST="read_bw" # one of 'write_bw' , 'read_bw', 'write_iops' , 'read_iops' , 'cleanup'
RUNTIME=120 # runtime in seconds of the test.
JOBS=8 # how many threads per host. This will also result in N mountpoints per host.
SIZE="20g" # size of each file, one per thread.
BLOCKSIZE="1mb" #leave alone for max b/w. Note that this only applies to the b/w tests, for iops tests it will be 4kb (hardcoded)
MIX=100 # only applicable if TEST="mix_bw" or "mix_iops"
POOL=2 # what pool to run on, typically this will be '2', but check!
PROTO="tcp" #rdma or tcp.  When in doubt, use tcp
REMOTE_PATH="fio" # change this to whatever you want it to be. This is the subdir underneath the export which will be created.
FIO_BIN=/usr/bin/fio #location where fio binary exists.
MOUNT=/mnt/fiodemo #where the mountpoints will get created on the host/cnode you are running this on.
DELETE_ALL=0 #if you use --delete=1 , it will clean up all files & mountpoints.
ioengine=libaio #use libaio most of the time. other options: posixaio
iodepth=8 #For b/w tests, lower values can result in slightly better latency.  For IOPS tests, higher values can yield higher IOps
USE_VMS="true" # should the VMS cnodes also be a client?  Note that in clusters larger than USABLE_CNODES , vms won't be used even if this is set to 1.
CN_DIST_MODE=random #or 'modulo' ( experimental ) .  Only applies to running on a vast-cnode.
PROXY="empty" #use IP:port if you need a proxy to get to VMS.
EXTRA_FIO_ARGS=" --numa_mem_policy=local --gtod_reduce=1 --clocksource=cpu --refill_buffers --randrepeat=0 --create_serialize=0 --random_generator=lfsr --fallocate=none" #don't change these unless you know...
DIRECT=1 # o_direct or not..
ADMINUSER="admin"
ADMINPASSWORD=123456
LOOPBACK=1 # only applies when running on cnodes. default is on now. BUT: this requires a lot of vips..
VERBOSE=1 # verbosely output details, may be too noisy on large clusters

###experimental flags ###
VIPFILE="empty" #use at own risk.
CN_AVOID_ISL=0 # only set this to 1 if you are in the lab or know what you are doing. if there are bugs, it can screw up routing.
ALT_POOL="empty" # experimental. don't set this or use --alt-pool "2 3 4 5" option.
VLAN_ID="empty" # only useful if we are attempting to modify routing (CN_AVOID_ISL=1)
VLAN_IFACES="empty" # a hack for now. we need to know what the vlan ifaces are. used in conjuction with VLAN_ID & CN_AVOID_ISL

###Following are hardcoded and not change-able via args/flags.
USABLE_CNODES=15 #this isn't changable via OPTS. its experimental. Use the --usevms=1/0 flag instead.
NOT_CNODE=0 # this only applies in the lab. leave at 0 normally
CLIENT_ISL_AVOID=0 # experimental. only for use in the lab. it can change routes.


#=============================================================================
# Functions

avoid_isl_func () {
  # experimental.  this only applies if you are NOT running on cnodes, since we already have a hack for that.
  # this is only really useful in the lab, where we have clients directly attached to same switches as clusters.
  if [ $IS_VAST == 0 ] && [ "$CLIENT_ISL_AVOID" == 1 ]; then
    #basically, we need to find out if the CNode iface matches the client.
    # for that..ssh key must work to the VMS-ip.
    # what we do is ssh to the VMS ip, do a 'clush' looking for the various ip's, and make a list.
    # Then, we have to look at the client side IPs, and determine if the iface which is on the same 'subnet' will
    # be able to talk directly to the iface on the CNode.  This assumes that the clients have ib0 on the same switch
    # that the cnode has ib0 on.
    CLIENT_IFACES="ib0 ib1"
    for iface in $CLIENT_IFACES; do
      export IPS=`ssh vastdata@${mVIP} clush -g cnodes "/sbin/ip a s ${iface} | egrep ':vip[0-9]+|:v[0-9]+'|egrep -o '[0-9]{1,3}*\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'"|awk {'print $1'}`
      #now check what the route looks like on this node for each ip.
      for IP in ${IPS}; do
        current_route=`/sbin/ip route get ${IP}|egrep -o 'dev \w+'|awk {'print $2'}`
        if [[ ${current_route} == $iface ]]; then
          echo "route is OK for $IP -> $iface , skipping"
        else
          echo "temporarily changing route for $IP -> $iface"
          sudo /sbin/ip route add ${IP}/32 dev ${iface}
        fi
      done
    done
  fi
}

remove_isl_func() {
  # experimental.  this only applies if you are NOT running on cnodes, since we already have a hack for that.
  # this is only really useful in the lab, where we have clients directly attached to same switches as clusters.
  if [ $IS_VAST == 0 ] && [ "$CLIENT_ISL_AVOID" == 1 ]; then
    CLIENT_IFACES="ib0 ib1"
    for iface in $CLIENT_IFACES; do
      export IPS=`ssh vastdata@${mVIP} clush -g cnodes "/sbin/ip a s ${iface} | egrep ':vip[0-9]+|:v[0-9]+'|egrep -o '[0-9]{1,3}*\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'"|awk {'print $1'}`
      #now check what the route looks like on this node for each ip.
      for IP in ${IPS}; do
        #this just deletes all /32 routes that we might have..
        sudo /sbin/ip route del ${IP}/32 dev ${iface} >/dev/null 2>1
      done
    done
  fi
}


mount_func () {
  export node=`hostname`

  DIRS=()
  MD_DIRS=()

  # Do the mounts. Stash away the command and the verbose output format
  # but only output them on mount failure to reduce noise.

  for i in ${needed_vips[@]}; do
    sudo mkdir -p ${MOUNT}/${i}
    if [[ ${PROTO} == "rdma" ]]; then
      mount_cmd="sudo mount -v -t nfs -o retry=0,proto=rdma,soft,port=20049,vers=3 ${i}:${NFSEXPORT} ${MOUNT}/${i}"
      mount_output=$(eval $mount_cmd 2>&1)
      if [ $? -eq 0 ]; then
        if [ ${VERBOSE} -eq 1 ]; then
          echo "mounted ${MOUNT}/${i} ok"
        fi
      else
        echo "mount of ${MOUNT}/${i} failed : $? , going to unmount everything and exit"
        echo "Command: $mount_cmd"
        echo "Output:"
        echo "$mount_output"
        cleanup
        exit
      fi
    else
      mount_cmd="sudo mount -v -t nfs -o retry=0,tcp,soft,rw,vers=3 ${i}:${NFSEXPORT} ${MOUNT}/${i}"
      mount_output=$(eval $mount_cmd 2>&1)
      if [ $? -eq 0 ]; then
        if [ ${VERBOSE} -eq 1 ]; then
          echo "mounted ${MOUNT}/${i} ok"
        fi
      else
        echo "mount of ${MOUNT}/${i} failed : $? , going to unmount everything and exit"
        echo "Command: $mount_cmd"
        echo "Output:"
        echo "$mount_output"
        cleanup
        exit
      fi
    fi
    export fio_dir=${MOUNT}/$i/${REMOTE_PATH}/${node}
    DIRS+=${fio_dir}:
    sudo mkdir -p ${fio_dir}
    sudo chmod 777 ${fio_dir}
  done
}

multipath_func () {
  #basically we want to build a mount command
  # which uses all VIPs.  I believe the limit with current multipath driver
  # is 32, so we'll set a limit of that.
  #

  # first, shuffle
  all_vips=( $(shuf -e "${all_vips[@]}") )
  needed_vips=()
  for ((idx=0; idx<${JOBS} && idx<${#all_vips[@]}; ++idx)); do
    needed_vips+=(${all_vips[$idx]})
  done
}


write_bw_test () {
  if [ -z ${RUNTIMEWRITE} ]; then
    #didn't specify runtime, so just create files of size specified
    ${FIO_BIN} --name=randrw --ioengine=${ioengine} --refill_buffers --create_serialize=0 --randrepeat=0 --create_on_open=1 --fallocate=none --iodepth=${iodepth} --rw=randrw --bs=1mb --direct=${DIRECT} --size=${SIZE} --numjobs=${JOBS} --rwmixread=0 --group_reporting --directory=${DIRS}
  else
    ${FIO_BIN} --name=randrw --ioengine=${ioengine} --refill_buffers --create_serialize=0 --randrepeat=0 --create_on_open=1 --fallocate=none --iodepth=${iodepth} --rw=randrw --bs=1mb --direct=${DIRECT} --size=${SIZE} --numjobs=${JOBS} --rwmixread=0 --group_reporting --directory=${DIRS} --time_based=1 --runtime=${RUNTIME}
  fi
}

seq_write_test () {
  if [ -z ${RUNTIMEWRITE} ]; then
    #didn't specify runtime, so just create files of size specified
    ${FIO_BIN} --name=randrw --ioengine=${ioengine} --refill_buffers --create_serialize=0 --randrepeat=0 --create_on_open=1 --fallocate=none --iodepth=${iodepth} --rw=write --bs=1mb --direct=${DIRECT} --size=${SIZE} --numjobs=${JOBS} --group_reporting --directory=${DIRS}
  else
    ${FIO_BIN} --name=randrw --ioengine=${ioengine} --refill_buffers --create_serialize=0 --randrepeat=0 --create_on_open=1 --fallocate=none --iodepth=${iodepth} --rw=write --bs=1mb --direct=${DIRECT} --size=${SIZE} --numjobs=${JOBS} --group_reporting --directory=${DIRS} --time_based=1 --runtime=${RUNTIME}
  fi
}

read_bw_test () {
  ${FIO_BIN} --name=randrw --ioengine=${ioengine} --iodepth=${iodepth} --rw=randread --bs=${BLOCKSIZE} --direct=${DIRECT} --size=${SIZE} --numjobs=${JOBS} --group_reporting --directory=${DIRS} --time_based=1 --runtime=${RUNTIME} $EXTRA_FIO_ARGS
}


write_iops_test () {
  ${FIO_BIN} --name=randrw --ioengine=${ioengine} --refill_buffers --create_serialize=0 --randrepeat=0 --create_on_open=1 --fallocate=none --iodepth=${iodepth} --rw=randrw --bs=4kb --direct=${DIRECT} --size=${SIZE} --numjobs=${JOBS} --rwmixread=0 --group_reporting --directory=${DIRS} --time_based=1 --runtime=${RUNTIME}
}

read_iops_test () {
  ${FIO_BIN} --name=randrw --ioengine=${ioengine} --refill_buffers --create_serialize=0 --randrepeat=0 --fallocate=none --iodepth=${iodepth} --rw=randread --bs=4kb --direct=${DIRECT} --size=${SIZE} --numjobs=${JOBS} --group_reporting --directory=${DIRS} --time_based=1 --runtime=${RUNTIME}
}

mix_bw_test () {
  if [ -z ${RUNTIMEWRITE} ]; then
    #didn't specify runtime, so just create files of size specified
    ${FIO_BIN} --name=randrw --ioengine=${ioengine} --refill_buffers --create_serialize=0 --randrepeat=0 --create_on_open=1 --fallocate=none --iodepth=${iodepth} --rw=randrw --bs=1mb --direct=${DIRECT} --size=${SIZE} --numjobs=${JOBS} --rwmixread=${MIX} --group_reporting --directory=${DIRS}
  else
    ${FIO_BIN} --name=randrw --ioengine=${ioengine} --refill_buffers --create_serialize=0 --randrepeat=0 --create_on_open=1 --fallocate=none --iodepth=${iodepth} --rw=randrw --bs=1mb --direct=${DIRECT} --size=${SIZE} --numjobs=${JOBS} --rwmixread=${MIX} --group_reporting --directory=${DIRS} --time_based=1 --runtime=${RUNTIME}
  fi
}

mix_iops_test () {
  ${FIO_BIN} --name=randrw --ioengine=${ioengine} --refill_buffers --create_serialize=0 --randrepeat=0 --create_on_open=1 --fallocate=none --iodepth=${iodepth} --rw=randrw --bs=4kb --direct=${DIRECT} --size=${SIZE} --numjobs=${JOBS} --rwmixread=${MIX} --group_reporting --directory=${DIRS} --time_based=1 --runtime=${RUNTIME}
}

#only use if you know what you are doing.
read_bw_reuse_test () {
  rando_dir=${MOUNT}/${all_vips[0]}/${REMOTE_PATH}
  echo ${rando_dir}
  ${FIO_BIN} --name=randrw --ioengine=${ioengine} --iodepth=${iodepth} --rw=randrw --bs=${BLOCKSIZE} --direct=${DIRECT} --numjobs=${JOBS} --rwmixread=100 --group_reporting --opendir=${rando_dir} --time_based=1 --runtime=${RUNTIME}
}



cleanup() {
  #basically, just skip doing any actual testing, and make sure that routes and mounts are cleaned up.
  echo "I'm only cleaning up..."
  pkill fio
  # this will clean up anything in dirs
  if [[ $DELETE_ALL -eq 1 ]]; then
    echo "deleting all created files"
    sudo rm -rvf ${MOUNT}/${needed_vips[0]}/${REMOTE_PATH}/${node}
    sudo umount -lf ${MOUNT}/* >/dev/null 2>/dev/null
    sudo rm -rf ${MOUNT}
  else
    echo "leaving files in place. you may want to clean up before you leave.."
    echo "unmounting all dirs"
    sudo umount -lf ${MOUNT}/* >/dev/null 2>/dev/null
  fi

  if [ $IS_VAST == 1 ] && [ $CN_AVOID_ISL == 1 ]; then
    if [[ $iface_count -eq 2 ]]; then
      if [ $VLAN_ID != "empty" ] && [ $VLAN_IFACES != "empty" ]; then #super experimental
        EXT_IFACES=$VLAN_IFACES.$VLAN_ID
        for iface in $EXT_IFACES; do
          export IPS_TO_ROUTE=$(clush -g cnodes "/sbin/ip a s ${iface} | egrep ':vip[0-9]+|:v[0-9]+'|egrep -o '[0-9]{1,3}*\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'"|awk {'print $2'})
          for IP in ${IPS_TO_ROUTE}; do
            echo "not doing route deletion..beware."
            #sudo /sbin/ip route del ${IP}/32 dev ${iface} >/dev/null 2>1
          done
        done
      else #the normal path
        for iface in $EXT_IFACES; do
          export IPS_TO_ROUTE=$(clush -g cnodes "/sbin/ip a s ${iface} | egrep ':vip[0-9]+|:v[0-9]+'|egrep -o '[0-9]{1,3}*\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'"|awk {'print $2'})
          for IP in ${IPS_TO_ROUTE}; do
            # a little heavy handed, but its OK.
            sudo /sbin/ip route del ${IP}/32 dev ${iface} >/dev/null 2>1
          done
        done
      fi
    else
      echo "only one external iface, skipping route destruction"
    fi
  fi
  remove_isl_func
}

showusage() {
  # the alignment of the arguments below is weird because they are meant
  # to align in the output after variable substitution
  cat << EOF
Usage: vast-perf.sh --test=TEST [optional args]
Available tests ---------------------------------------------------------------
  --test=TEST            test to run, one of:
      read_bw, write_bw, seq_write_bw, write_iops, read_iops,
      mix_bw, mix_ops, reuse_bw_reuse, cleanup, mount_only

Optional arguments with their defaults ----------------------------------------
misc options
  --delete=$DELETE_ALL             delete files upon completion?
  --verbose=$VERBOSE            include verbose output?

fio options
  --binary=$FIO_BIN  path to fio
  --runtime=$RUNTIME          runtime of the test in seconds
  --jobs=$JOBS               number of fio jobs to run
  --size=$SIZE             size of the files to read/write
  --block-size=$BLOCKSIZE       read/write blocksize
  --direct=$DIRECT             use O_DIRECT?
  --ioengine=$ioengine      ioengine to use with fio
  --iodepth=$iodepth            iodepth to use with fio
  --mix=$MIX              read/write mix, only used for "mix_bw" or "mix_iops"

mount-related options
  --proto=$PROTO            mount protocol (auto-detected)
  --mountpoint=$MOUNT
                         mount point on cnode
  --export=$NFSEXPORT             NFS export from the cluster
  --path=$REMOTE_PATH             directory under the mountpoint to place files
  --loopback=$LOOPBACK           use loopback mounts

cluster options
  --usevms=$USE_VMS          use VMS node in the test load? (auto-detected)
  --pool=$POOL               vippool to run against

advanced options -- you shouldn't need any of these when running on cnodes
 --vms=$mVIP             VMS VIP (auto-detected when run on cnode)
 --proxy=$PROXY           proxy in the form of ip:port
 --user=$ADMINUSER            admin username
 --password=$ADMINPASSWORD       admin password

Note: experimental options are not included.
EOF
}


#=============================================================================
# Main program

#--------------------------------------
# Argument Parsing

### try this sometime...
# USAGE="$0 -n <qty> -d <path> -h <list,of,hosts> "
# while getopts n:d:h: c
#       do
#           case $c in
#               n)      shift; QTY=$1 ;;
#               d)      shift; THEPATH="$1" ;;
#               h)      shift; THEHOSTS="$1" ;;
#              \?)      echo $USAGE
#                       exit 2;;
#           esac
#       done


while [ $# -gt 0 ]; do
  case "$1" in
    --vms=*)
      mVIP="${1#*=}"
      ;;
    --proxy=*)
      PROXY="${1#*=}"
      ;;
    --export=*)
      NFSEXPORT="${1#*=}"
      ;;
    --test=*)
      TEST="${1#*=}"
      ;;
    --runtime=*)
      RUNTIME="${1#*=}"
      RUNTIMEWRITE=$RUNTIME
      ;;
    --proto=*)
      PROTO="${1#*=}"
      ;;
    --jobs=*)
      JOBS="${1#*=}"
      ;;
    --size=*)
      SIZE="${1#*=}"
      ;;
    --mix=*)
      MIX="${1#*=}"
      ;;
    --block-size=*)
      BLOCKSIZE="${1#*=}"
      ;;
    --pool=*)
      POOL="${1#*=}"
      ;;
    --alt-pool=*)
      ALT_POOL="${1#*=}"
      ;;
    --path=*)
      REMOTE_PATH="${1#*=}"
      ;;
    --binary=*)
      FIO_BIN="${1#*=}"
      ;;
    --mountpoint=*)
      MOUNT="${1#*=}"
      ;;
    --delete=*)
      DELETE_ALL="${1#*=}"
      ;;
    --ioengine=*)
      ioengine="${1#*=}"
      ;;
    --iodepth=*)
      iodepth="${1#*=}"
      ;;
    --direct=*)
      DIRECT="${1#*=}"
      ;;
    --usevms=*)
      USE_VMS="${1#*=}"
      ;;
    --distmode=*)
      CN_DIST_MODE="${1#*=}"
      ;;
    --avoid-isl=*)
      CN_AVOID_ISL="${1#*=}"
      ;;
    --loopback=*)
      LOOPBACK="${1#*=}"
      ;;
    --user=*)
      ADMINUSER="${1#*=}"
      ;;
    --password=*)
      ADMINPASSWORD="${1#*=}"
      ;;
    --verbose=*)
      VERBOSE="${1#*=}"
      ;;
    --vipfile=*)
      VIPFILE="${1#*=}"
      ;;
    --help=*)
      HELPME="true"
      ;;
    *)
      showusage
      exit 1
  esac
  shift
done


#--------------------------------------
# Pre-flight checks

#
#check if we are running on a vast CNode
#
IS_VAST=0

if  [ -f "/vast/vman/mgmt-vip" ] && [ $NOT_CNODE == 0 ]; then
  IS_VAST=1
  mVIP=`cat /vast/vman/mgmt-vip`
  echo "running on a Vast node. setting VMSIP to ${mVIP}"

  if [ ${PROTO} == "multipath" ]; then
    echo "can't use multipath on cnode, falling back to regular rdma"
    PROTO=rdma
  fi

  # Nowadays, vast-OS supports RDMA so default to it when running on loopback
  # mode, but first check two exceptions: Broadcom NICs & Rocky

  # Check for the Broadcom driver
  LSMOD=`sudo lsmod|grep bnxt_en|wc -l`
  if [ "$LSMOD" -gt "0" ]; then
    PROTO=tcp
    echo "setting PROTO to ${PROTO} because broadcom"

  # Check for Rocky
  elif grep -q "Rocky" /etc/redhat-release; then
    PROTO=tcp
    echo "setting PROTO to ${PROTO} because rocky"

  # by default, use RDMA
  else
    PROTO=rdma
    echo "setting PROTO to ${PROTO} because cnode"
  fi
else # if we are running on an external client.
  if [[ ${mVIP} == "empty" ]]; then
    echo "You must specify a VMS ip via --vms=x.x.x.x"
    exit 20
  fi
  # loopback isn't valid on non-cnodes
  LOOPBACK=0
fi

# Confirm we can connect to mVIP
CURL_OPTS="-s -u ${ADMINUSER}:${ADMINPASSWORD} -H 'accept: application/json' --insecure --ciphers ECDHE-RSA-AES128-GCM-SHA256"

if [ "$PROXY" != "empty" ]; then
  export http_proxy=${PROXY}
  CURL_OPTS="${CURL_OPTS} -x ${PROXY}"
fi

response_code=$(/usr/bin/curl ${CURL_OPTS} -X GET "https://$mVIP/api/vippools/" --write-out "\n%{http_code}\\n" | tail -1)
if [ "$response_code" != "200" ]; then
  echo "Unable to connect to VMS, confirm username & password are correct."
  exit 20
fi

if [[ ${TEST} == "read_bw_reuse" ]]; then
  #this test is really only valid if you are using RDMA, otherwise you will bottleneck on a single mount per client.
  if [[ ${IS_VAST} == 1 ]]; then
    echo "don't use read_bw_reuse on cnodes. only use this option on external clients if you are using RDMA, OR you have a lot of clients."
    exit 20
  fi
fi


#--------------------------------------
# Determine some info about our env

pools=()
pools+=(${POOL})

if [ "$ALT_POOL" != "empty" ]; then
  pools+=" ${ALT_POOL}"
fi

client_VIPs=""
all_vips=()

for pool in $pools; do
  if [ $LOOPBACK == 1 ]; then

    # if [ VIPFILE != "empty" ]; then
    #   echo "you can't specify --vipfile=${VIPFILE} && looback=1. If you want to use a vipfile, use loopback=0"
    #   exit 20
    # fi

    # only mount local vips on the CNode. Note that if there are less vips per CNode than jobs, then some jobs
    # will re-use the same VIPs, which will not necessarily give the b/w you desire..ideally you have at least 5 mounts per CNode.

    # in 4.2, we changed how we name nodes.  So, instead of using node-names in the filter...we will use the internal IP.
    # also, the way this works is different on an IB backend cluster vs an ETH cluster.
    #first..figure out if we have an IB nic for internal

    export INT_IFACES=$(cat /etc/vast-configure_network.py-params.ini|grep internal_interfaces|awk -F "=" {'print $2'}| sed -E 's/,/ /')

    export DATA_VLAN=$(cat /etc/vast-configure_network.py-params.ini|grep data_vlan|awk -F "=" {'print $2'}| sed -E 's/,/ /')

    #
    if [[ "$INT_IFACES" =~ .*"en".* ]]; then
      echo "ETH backend"
      BOND_IFACE="bond0.${DATA_VLAN}"
    elif [[ "$INT_IFACES" =~ .*"p2p".* ]]; then
      echo "ETH backend"
      BOND_IFACE="bond0.${DATA_VLAN}"
    elif [[ "$INT_IFACES" =~ .*"ib".* ]]; then
      echo "IB backend"
      BOND_IFACE="bond0"
    else
      echo "int ifaces: ${INT_IFACES} : not recognized as 'en', 'p2p',  or 'ib' , exiting"
      exit 20
    fi


    ###we need to know what the "inner vip" is.

    export INNER_VIP=$(cat /etc/vast-configure_network.py-params.ini|grep mgmt_inner_vip=|awk -F "=" {'print $2'})

    export INT_IP=`/sbin/ip a s ${BOND_IFACE}|grep inet|grep -v inet6|grep -v ${INNER_VIP} | awk {'print $2'}|sed -E 's/\/[0-9]+//'`
    # query VMS

    if [ $VIPFILE != "empty" ]; then #super experimental
      # grab the vips from a file..which must be formatted perfectly..or you die.
      local_vips="$(cat ${VIPFILE})"
    else
      export local_vips=$(/usr/bin/curl ${CURL_OPTS} -X GET "https://$mVIP/api/vips/?vippool__id=${pool}&cnode__ip=${INT_IP}" | jq '.[] | .ip')
    fi

    if [ "x$local_vips" == 'x' ]; then
      echo "Failed to retrieve cluster virtual IPs for client access using VIP pool ID ${pool}, check VMSip or pool-id. Also: make sure that this CNode is a member of the pool you want to test with."
      echo "Available VIP pools:"
      /usr/bin/curl ${CURL_OPTS} -X GET "https://$mVIP/api/vippools/" | jq -c 'sort_by(.id) | .[] | {id, name, ranges_summary}'
      exit 20
    fi

    for local_vip in ${local_vips}; do
      local_vip=${local_vip//\"/}
      all_vips+=(${local_vip})
    done
  else
    #not loopback..get all the vips in the pool to use.

    if [ $VIPFILE != "empty" ]; then #super experimental
      # grab the vips from a file..which must be formatted perfectly..or you die.
      client_VIPs="$(cat ${VIPFILE})"
    else
      # use curl to grab the VIPs
      client_VIPs+="$(/usr/bin/curl ${CURL_OPTS} -X GET "https://$mVIP/api/vips/?vippool__id=${pool}" | jq -r '.[] | .ip' | sort -t'.' -k4 -n | tr '\n' ' ')"
    fi

    echo $client_VIPs
    if [ "x$client_VIPs" == 'x' ]; then
      echo "Failed to retrieve cluster virtual IPs for client access using VIP pool ID ${pool}, check VMSip or pool-id"
      echo "Available VIP pools:"
      /usr/bin/curl ${CURL_OPTS} -X GET "https://$mVIP/api/vippools/" | jq -c 'sort_by(.id) | .[] | {id, name, ranges_summary}'
      exit 20
    fi
  fi
done


if [ $LOOPBACK == 0 ]; then
  numVIPS=`echo $client_VIPs | wc -w`
  if [ "$numVIPS" -lt "$JOBS" ]; then
    echo "$numVIPS vips is < $JOBS jobs , re-run with $numVIPS or less jobs."
    exit 20
  fi
  #put the vips into an array.
  for i in $client_VIPs; do
    all_vips+=(${i})
  done
fi


####If we are running on a CNode.
#If the cluster is more than XX CNodes, then don't run on VMS node.
#
if [ $IS_VAST == 1 ]; then
  #dima don't like this, but for now its fine.
  numCNodes=`grep 'cnodes:' /etc/clustershell/groups.d/local.cfg |awk -F ":" {'print $2'}|wc -w`
  if [ "$numCNodes" -gt $USABLE_CNODES ] || [ "$USE_VMS" == "false" ]; then
    #check if we're on the VMS Cnode
    if [ $(docker ps -q --filter label=role=vms |wc -l) -eq 1 ]; then
      echo "not going to run on VMS node"
      exit
    fi
  fi
  # next chunk of items don't apply to loopback.
  if [ $LOOPBACK == 0 ]; then
    if [ "$CN_DIST_MODE" == "modulo" ]; then
      #Basic methodology is that we want to shift the starting IP for each CNode, and have it mount $Numjobs (up to 12) VIPs.
      # eg: CN1 mounts .1 -> 12 , CN2 mounts .2 -> .13 , CN3 mounts .3 -> .14 , and so on.
      # check we have enough VIPs for this.
      #
      vipTEST=$(($numVIPS + 1))
      if [[ $vipTEST -lt $(($numCNodes + $JOBS)) ]]; then
        echo "you need at least $((($numCNodes + $JOBS) - 1)) vips"
        exit 20
      fi
    fi

    #next, avoid crossing ISLs since we are on cnodes.
    #temporarily setup the routing table to ensure that reads/writes go over both ifaces. assumes at least one VIP on each iface on a given cnode.
    #

    #first, figure out what ifaces we need to use.

    export EXT_IFACES=$(cat /etc/vast-configure_network.py-params.ini|grep external_interfaces|awk -F "=" {'print $2'}| sed -E 's/,/ /')

    # we only care if there are more than one iface.
    export iface_count=`echo $EXT_IFACES | wc -w`
    echo "interface count is $iface_count"

    if [ $iface_count -eq 2 ] && [ $CN_AVOID_ISL == 1 ]; then
      # sometimes the route is OK, sometimes its not,  check them all and only change if they are 'wrong'
      if [ $VLAN_ID != "empty" ] && [ $VLAN_IFACES != "empty" ]; then #super experimental
        EXT_IFACES=$VLAN_IFACES.$VLAN_ID
        for iface in $EXT_IFACES; do
          export IPS_TO_ROUTE=$(clush -g cnodes "/sbin/ip a s ${iface} | egrep ':vip[0-9]+|:v[0-9]+'|egrep -o '[0-9]{1,3}*\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'"|awk {'print $2'})
          for IP in ${IPS_TO_ROUTE}; do #
            current_route=`/sbin/ip route get ${IP}|egrep -o 'dev \w+\.[0-9]+'|awk {'print $2'}`
            if [[ ${current_route} == $iface ]]; then
              echo "route is OK for $IP -> $iface , skipping"
            else
              echo "temporarily changing route for $IP -> $iface"
              sudo /sbin/ip route add ${IP}/32 dev ${iface}
            fi
          done
        done

      else # this is the 'normal' path
        for iface in $EXT_IFACES; do #this won't work if there is a vlan tag on the pool.
          export IPS_TO_ROUTE=$(clush -g cnodes "/sbin/ip a s ${iface} | egrep ':vip[0-9]+|:v[0-9]+'|egrep -o '[0-9]{1,3}*\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'"|awk {'print $2'})
          #now check what the route looks like on this node for each ip.
          for IP in ${IPS_TO_ROUTE}; do
            current_route=`/sbin/ip route get ${IP}|egrep -o 'dev \w+'|awk {'print $2'}`
            if [[ ${current_route} == $iface ]]; then
              echo "route is OK for $IP -> $iface , skipping"
            else
              echo "temporarily changing route for $IP -> $iface"
              sudo /sbin/ip route add ${IP}/32 dev ${iface}
            fi
          done
        done
      fi
    else
      echo "skipping route setup"
    fi
  fi
fi
####End CNode specific stuff.###


#build the list of vips to actually mount.
#
if [ $IS_VAST == 1 ] && [ "$CN_DIST_MODE" == "modulo" ]; then
  #figure out what node we are on.
  export NODENUM=`grep node /etc/vast-configure_network.py-params.ini |egrep -o 'node=[0-9]+'|awk -F '=' {'print $2'}`
  echo "$NODENUM here"
  idx_start=$(( $NODENUM - 1))
  idx_end=$((($idx_start + $JOBS) -1 ))
  needed_vips=()
  for ((idx=$idx_start; idx<=$idx_end; idx++)); do
    needed_vips+=(${all_vips[$idx]})
  done

else
  #either we're not on a vast cnode, or you chose random distribution.
  #Better logic could be had here, but for now just randomize the vip list, and iterate through them until numJobs is satisfied.

  # regardless of how we got here, shuffle the vips and only use as  many as we need to satisfy the job count, if we have enough.
  all_vips=( $(shuf -e "${all_vips[@]}") )
  needed_vips=()
  for ((idx=0; idx<${JOBS} && idx<${#all_vips[@]}; ++idx)); do
    needed_vips+=(${all_vips[$idx]})
    # echo "${all_vips[$idx]} is in the mix"
  done
fi


#--------------------------------------
# Unmount old mounts & run the test

#force unmount anything that might have been mounted last time this was run.
sudo umount -lf ${MOUNT}/* >/dev/null 2>/dev/null


avoid_isl_func


if [[ ${TEST} == "read_bw" ]]; then
  mount_func
  read_bw_test
  cleanup
elif [[ ${TEST} == "write_bw" ]]; then
  mount_func
  write_bw_test
  cleanup
elif [[ ${TEST} == "seq_write_bw" ]]; then
  mount_func
  seq_write_test
  cleanup
elif [[ ${TEST} == "write_iops" ]]; then
  mount_func
  write_iops_test
  cleanup
elif [[ ${TEST} == "read_iops" ]]; then
  mount_func
  read_iops_test
  cleanup
elif [[ ${TEST} == "mix_bw" ]]; then
  mount_func
  mix_bw_test
  cleanup
elif [[ ${TEST} == "mix_iops" ]]; then
  mount_func
  mix_iops_test
  cleanup
elif [[ ${TEST} == "read_bw_reuse" ]]; then
  mount_func
  read_bw_reuse_test
  cleanup
elif [[ ${TEST} == "cleanup" ]]; then
  mount_func
  cleanup
elif [[ ${TEST} == "mount_only" ]]; then
  mount_func
  echo "done mounting, existing and leaving mounts. if you want to unmount, run with --test=cleanup"
else
  echo "you didn't specify a valid test. unmounting and exiting"
fi
