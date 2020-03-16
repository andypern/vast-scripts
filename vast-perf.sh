#!/usr/bin/bash
# This script can be run either on a Vast-CNode, or another linux host.


###When running on a Vast-Cnode
## if you use 'modulo' for CN_DIST_MODE (the default) , it will require a larger VIP pool, specifically ()$numCNodes + $JOBS) - 1
# If running on a cluster with more thatn 8 CNodes, the script will not execute on the node holding VMS (this is to prevent OOM issues)
# If you notice issues on 8CN or smaller clusters where VMS crashes, then adjust the 'USABLE_CNODES' variable to a smaller number.
# If you make changes to any variables in the script, make sure to copy the file to all cnodes before executing.
# If you choose 'RDMA', the script will automatically change to TCP, because Vast-CNodes do not have RDMA-client packages.
# This script will temporarily adjust CNode <-> CNode routing tables to ensure that traffic does not cross the ISL's.
######

###When running on a non-vast client
## it requires that FIO 3.1 or higher is available on the host (by default it is on vast-cnodes)
# If FIO is in a different location than /usr/bin/fio : you must update the FIO_BIN variable before executing.
# you must make sure that the number of VIPs in the VIP-pool you use is at least equal to the number of jobs you are using.
# If you choose 'rdma' for the final argument: make sure that you have already setup and verified that you can mount NFS using RDMA.
#
#####

###Behavior, 'best practices'
# You will want to run the write_bw test for at least 5 minutes (300 seconds) to blow through Optane buffers.
# The first time you run a read test, it may want to create some files as it reads, this will slow down the test, just re-run it until it stops trying to create files.
# When running on a Vast-cnode: start with JOBS=12 before testing with smaller values.  That way the files will get pre-created for subsequent runs.
# Refrain from pressing 'crtl-c' when you are performing write tests, or if you are performing read tests and you see that FIO is 'laying out .. files'.  Doing so may result in unkillable FIO processes
# If you press crtl-c during any test, then immediately re-run the script with the 'cleanup' job : 'vast-perf.sh 10.100.201.201 cleanup 120 8 1 tcp'.  This will ensure that mounts/etc are cleaned up.
#all arguments are positional, and all are required.  There is currently minimal error checking done, __
# and incorrect usage may yield unexpected results.  Read through the 'positional args' below to make sure you understand.

##run like this:
# you don't _need_ clustershell/clush , but it makes it easier to run this on multiple hosts.
# 1.  put this script on client-1 (or Cnode-1)
# 2.  Run it like this 'bash /home/vastdata/vast-perf.sh 10.100.201.201 / read_bw 120 8 1 tcp'  <--- this will ONLY run on client, and will read_bw test for 120 seconds, with 8 numjobs.
# 3.  Once you verify it works, copy to all clients: `clush -g clients -c /home/vastdata/vast-perf.sh`.  substitute the word 'cnodes' for clients in the clush example if you are running on a cnode.
# 4.  Run on all nodes like this `clush -g clients 'bash /home/vastdata/vast-perf.sh 10.100.201.201 / read_bw 120 8 1 tcp`




###positional $ARGS:###
#
#
mVIP=$1  # the VMS-VIP of the vast cluster you are testing against.
NFSEXPORT=$2 # the NFS export to use.  On a brand new cluster use '/' (no quotes)
TEST=$3 # one of 'write_bw' , 'read_bw', 'write_iops' , 'read_iops' , 'cleanup'
RUNTIME=$4 # runtime in seconds of the test.
JOBS=$5 # how many threads per host. This will also result in N mountpoints per host.
POOL=$6 # what pool to run on, typically this will be '1', but check!
NFS=$7 #rdma or tcp.  When in doubt, use tcp

REMOTE_PATH="fio" # change this to whatever you want it to be. This is the subdir underneath the export which will be created.



#set this to 1 if you want to delete all FIO generated files that this script may have created previously.
DELETE_ALL=0

MOUNT=/mnt/fiodemo #where the mountpoints will get created on the host/cnode you are running this on.

FIO_BIN=/usr/bin/fio

#use libaio most of the time.
ioengine=libaio #other options: posixaio

#For b/w tests, lower values can result in slightly better latency.  For IOPS tests, higher values can yield higher IOps
iodepth=8 #


###don't change this unless you know what you are doing
USABLE_CNODES=8
CN_DIST_MODE=modulo #or 'random' .  Only applies to running on a vast-cnode.
#
#
###end vars.###



##some pre-flight checks.

#
#check if we are running on a vast CNode
#
IS_VAST=0

if  [[ -f "/vast/vman/mgmt-vip" ]]; then
  IS_VAST=1
  echo 'running on a Vast node.'
  if [[ ${NFS} == "rdma" ]] ; then
    echo "running on a vast node requires using tcp, doing that instead."
    NFS=tcp
  fi

fi



if [[ ${TEST} == "read_bw_reuse" ]] ; then
  #this test is really only valid if you are using RDMA, otherwise you will bottleneck on a single mount per client.
  if [[ ${IS_VAST} == 1 ]] ; then
    echo "don't use read_bw_reuse on cnodes. only use this option on external clients if you are using RDMA, OR you have a lot of clients."
    exit 20
  fi
fi



#VIPs for client access
client_VIPs="$(/usr/bin/curl -s -u admin:123456 -H "accept: application/json" --insecure -X GET "https://$mVIP/api/vips/?vippool__id=${POOL}" | grep -Po '"ip":"[0-9\.]*",' | awk -F'"' '{print $4}' | sort -t'.' -k4 -n | tr '\n' ' ')"
echo $client_VIPs
if [ "x$client_VIPs" == 'x' ] ; then
    echo 'Failed to retrieve cluster virtual IPs for client access, check VMSip or pool-id'
    exit 20
fi

numVIPS=`echo $client_VIPs | wc -w`
if [ "$numVIPS" -lt "$JOBS" ]; then
  echo "$numVIPS vips is < $JOBS jobs , re-run with $numVIPS or less jobs."
  exit 20
fi

#put the vips into an array.
all_vips=()
for i in $client_VIPs; do
  all_vips+=(${i})
done



####If we are running on a CNode.
#If the cluster is more than XX CNodes, then don't run on VMS node.
#
if [ $IS_VAST == 1 ]; then
  #dima don't like this, but for now its fine.
  numCNodes=`grep 'cnodes:' /etc/clustershell/groups.d/local.cfg |awk -F ":" {'print $2'}|wc -w`
  if [ "$numCNodes" -gt $USABLE_CNODES ]; then
    #check if we're on the VMS Cnode
    if [ $(docker ps -q --filter label=role=vms |wc -l) -eq 1 ]; then
      echo "not going to run on VMS node"
      exit
    fi
  fi

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

  export EXT_IFACES=$(cat /etc/vast-configure_network.py-params.ini|grep external|awk -F "=" {'print $2'}| sed -E 's/,/ /')

  # we only care if there are more than one iface.
  export iface_count=`echo $EXT_IFACES | wc -w`
  echo "interface count is $iface_count"

  if [[ $iface_count -eq 2 ]] ; then
    # sometimes the route is OK, sometimes its not,  check them all and only change if they are 'wrong'
    for iface in $EXT_IFACES
      do IPS_TO_ROUTE=$(clush -g cnodes "/sbin/ip a s ${iface} | grep vip|egrep -o '[0-9]{1,3}*\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'"|awk {'print $2'})
      #now check what the route looks like on this node for each ip.
      for IP in ${IPS_TO_ROUTE}
        do current_route=`/sbin/ip route get ${IP}|egrep -o 'dev \w+'|awk {'print $2'}`
        if [[ ${current_route} == $iface ]] ; then
          echo "route is OK for $IP -> $iface , skipping"
        else
          echo "temporarily changing route for $IP -> $iface"
          sudo /sbin/ip route add ${IP}/32 dev ${iface}
        fi
      done
    done
  else
    echo "only one external iface, skipping route setup"
  fi
fi
####End CNode specific stuff.###


#build the list of vips to actually mount.
#
if [ $IS_VAST == 1 ] && [ "$CN_DIST_MODE" == "modulo" ];then

  #figure out what node we are on.
  export NODENUM=`grep node /etc/vast-configure_network.py-params.ini |egrep -o 'node=[0-9]+'|awk -F '=' {'print $2'}`

  idx_start=$(( $NODENUM - 1))
  idx_end=$((($idx_start + $JOBS) -1 ))
  needed_vips=()
  for ((idx=$idx_start; idx<=$idx_end; idx++)); do
    needed_vips+=(${all_vips[$idx]})
  done

else
  #either we're not on a vast cnode, or you chose random distribution.
  #Better logic could be had here, but for now just randomize the vip list, and iterate through them until numJobs is satisfied.
  all_vips=( $(shuf -e "${all_vips[@]}") )
  needed_vips=()
  for ((idx=0; idx<${JOBS} && idx+1<${#all_vips[@]}; ++idx)); do
    needed_vips+=(${all_vips[$idx]})
  done
fi



#force unmount anything that might have been mounted last time this was run.
sudo umount -lf ${MOUNT}/* >/dev/null 2>/dev/null

export node=`hostname`




DIRS=()
MD_DIRS=()

for i in ${needed_vips[@]}
        do sudo mkdir -p ${MOUNT}/${i}
        if [[ ${NFS} == "rdma" ]] ; then
          sudo mount -v -t nfs -o proto=rdma,port=20049,vers=3 ${i}:${NFSEXPORT} ${MOUNT}/${i}
        else
          sudo mount -v -t nfs -o tcp,rw,vers=3 ${i}:${NFSEXPORT} ${MOUNT}/${i}
        fi
        export fio_dir=${MOUNT}/$i/${REMOTE_PATH}/${node}
        DIRS+=${fio_dir}:
        sudo mkdir -p ${fio_dir}
        sudo chmod 777 ${fio_dir}

done


echo ${DIRS}

write_bw_test () {
  ${FIO_BIN} --name=randrw --ioengine=${ioengine} --refill_buffers --create_serialize=0 --randrepeat=0 --create_on_open=1 --fallocate=none --iodepth=${iodepth} --rw=randrw --bs=1mb --direct=1 --size=20g --numjobs=${JOBS} --rwmixread=0 --group_reporting --directory=${DIRS} --time_based=1 --runtime=${RUNTIME}

}


read_bw_test () {
  ${FIO_BIN} --name=randrw --ioengine=${ioengine} --refill_buffers --create_serialize=0 --randrepeat=0 --fallocate=none --iodepth=${iodepth} --rw=randrw --bs=1mb --direct=1 --size=20g --numjobs=${JOBS} --rwmixread=100 --group_reporting --directory=${DIRS} --time_based=1 --runtime=${RUNTIME}
}


write_iops_test () {
  ${FIO_BIN} --name=randrw --ioengine=${ioengine} --refill_buffers --create_serialize=0 --randrepeat=0 --create_on_open=1 --fallocate=none --iodepth=${iodepth} --rw=randrw --bs=4kb --direct=1 --size=20g --numjobs=${JOBS} --rwmixread=0 --group_reporting --directory=${DIRS} --time_based=1 --runtime=${RUNTIME}

}

read_iops_test () {
  ${FIO_BIN} --name=randrw --ioengine=${ioengine} --refill_buffers --create_serialize=0 --randrepeat=0 --fallocate=none --iodepth=${iodepth} --rw=randrw --bs=4kb --direct=1 --size=20g --numjobs=${JOBS} --rwmixread=100 --group_reporting --directory=${DIRS} --time_based=1 --runtime=${RUNTIME}
}

#only use if you know what you are doing.
read_bw_reuse_test () {
  rando_dir=${MOUNT}/${all_vips[0]}/${REMOTE_PATH}
  echo ${rando_dir}
  ${FIO_BIN} --name=randrw --ioengine=${ioengine} --iodepth=${iodepth} --rw=randrw --bs=1mb --direct=1 --numjobs=${JOBS} --rwmixread=100 --group_reporting --opendir=${rando_dir} --time_based=1 --runtime=${RUNTIME}
}

cleanup_only () {
  #basically, just skip doing any actual testing, and make sure that routes and mounts are cleaned up.
  echo "I'm only cleaning up..."
  pkill fio
}

####unused (appendix) functions.####


####end all functions.#####


if [[ ${TEST} == "read_bw" ]] ; then
  read_bw_test
elif [[ ${TEST} == "write_bw" ]] ; then
  write_bw_test
elif [[ ${TEST} == "write_iops" ]] ; then
  write_iops_test
elif [[ ${TEST} == "read_iops" ]] ; then
  read_iops_test
elif [[ ${TEST} == "read_bw_reuse" ]] ; then
  read_bw_reuse_test
elif [[ ${TEST} == "cleanup" ]] ; then
  cleanup_only
else
  echo "you didn't specify a valid test. unmounting and exiting"
fi



# this will clean up anything in dirs
if [[ $DELETE_ALL -eq 1 ]] ; then
  echo "deleting all created files"
  for dir in ${DIRS}
    do rm -f ${dir}/*
  done
else
  echo "leaving files in place. you may want to clean up before you leave.."
fi


echo "unmounting all dirs"
sudo umount -lf ${MOUNT}/* >/dev/null 2>/dev/null


if [ $IS_VAST == 1 ]; then
  if [[ $iface_count -eq 2 ]] ; then
    for iface in $EXT_IFACES
      do export IPS_TO_ROUTE=$(clush -g cnodes "/sbin/ip a s ${iface} | grep vip|egrep -o '[0-9]{1,3}*\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'"|awk {'print $2'})
      for IP in ${IPS_TO_ROUTE}
      # a little heavy handed, but its OK.
        do sudo /sbin/ip route del ${IP}/32 dev ${iface} >/dev/null 2>1
      done
    done
  else
    echo "only one external iface, skipping route destruction"
  fi
fi
