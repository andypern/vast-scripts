#!/usr/bin/bash
#
#run like this:
# make sure FIO is installed, put the path in the FIO_BIN variable.
# you don't _need_ clustershell/clush , but it makes it easier to run this on multiple hosts.
# 1.  put this script on client-1
# 2.  Run it like this 'bash /home/vastdata/vast-perf.sh 10.100.201.201 / read_bw 120 8 1 tcp'  <--- this will ONLY run on client, and will read_bw test for 120 seconds, with 8 numjobs.
# 3.  Once you verify it works, copy to all cnodes: `clush -g clients -c /home/vastdata/vast-perf.sh`
# 4.  Run on all nodes like this `clush -g clients 'bash /home/vastdata/vast-perf.sh 10.100.201.201 read_bw 120 8 1 tcp'`


###Notes
# You will want to run the write_bw test for at least 5 minutes to blow through Optane buffers.
# The first time you run a read test, it may want to create some files as it reads, this will slow down the test, just re-run it until it stops trying to create files.
# Its better to start with numjobs=8 (or 16) so that the files get created for subsequent runs.
#

#positional $ARGS:
mVIP=$1  # the VMS-VIP of the vast cluster you are testing against.
NFSEXPORT=$2
TEST=$3 # one of 'write_bw' , 'read_bw', 'write_iops' , 'read_iops'
RUNTIME=$4 # runtime in seconds of the test.
JOBS=$5 # how many threads per host. This will also result in N mountpoints per host (up to the total number of VIPs in the vast cluster.)
POOL=$6 # what pool to run on, typically this will be '1', but check!
NFS=$7 #rdma or tcp

REMOTE_PATH="fio" # change this to whatever you need it to be.


###other variables you can set.
#set this to 1 if you want to delete between runs.
DELETE_RUN=0

#set this to 1 if you want to delete everything that this script may have created previously.
DELETE_ALL=0

MOUNT=/mnt/fiodemo #where the mountpoints will get created.

FIO_BIN=/usr/bin/fio

#libaio most of the time..
ioengine=libaio
#ioengine=psync

iodepth=8



#pick the ID of the vip pool you want to use..most of the time it will be '1'

#
#
###end vars.###


run_num=`date +%s`




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
    echo $NFS
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
    echo Failed to retrieve cluster virtual IPs for client access
    exit 20
fi

numVIPS=`echo $client_VIPs | wc -w`
if [ "$numVIPS" -lt "$JOBS" ]; then
  echo "$numVIPS vips is < $JOBS jobs , re-run with $numVIPS or less jobs."
  exit 20
fi








#
#If we're running on a CNode, and the cluster is more than 4 CNodes, then don't run on VMS node.
#
if [ $IS_VAST == 1 ]; then
  #dima don't like this, but for now its fine.
  numCNodes=`grep 'cnodes:' /etc/clustershell/groups.d/local.cfg |awk -F ":" {'print $2'}|wc -w`
  if [ "$numCNodes" -gt 4 ]; then
    #check if we're on the VMS Cnode
    if [ $(docker ps -q --filter label=role=vms |wc -l) -eq 1 ]; then
      echo "not going to run on VMS node"
      exit
    fi
  fi
  #next, avoid crossing ISLs since we are on cnodes.
  #an attempt to try and temporarily setup the routing table to ensure that reads/writes go over both ifaces. Note that this assumes you have at least one VIP on each iface on a given cnode.
  #
  #first, figure out what ifaces we need to use.

  export EXT_IFACES=$(cat /etc/vast-configure_network.py-params.ini|grep external|awk -F "=" {'print $2'}| sed -E 's/,/ /')

  # we only care if there are more than one iface.
  export iface_count=`echo $EXT_IFACES | wc -w`
  echo "interface count is $iface_count"

  ###if you really want to use this logic, change the `3` to a `2` on the next line, and also in the route deletion block at the end of this script.
  if [[ $iface_count -eq 2 ]] ; then
    #so...this gets complicated.  sometimes the route is OK, sometimes its not, so we have to check them all and only change if they are 'wrong'
    for iface in $EXT_IFACES
      do IPS_TO_ROUTE=$(clush -g cnodes "/sbin/ip a s ${iface} | grep vip|egrep -o '[0-9]{1,3}*\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'"|awk {'print $2'})
      #now that we have them all, check what the route looks like on this node for each ip.
      for IP in ${IPS_TO_ROUTE}
        do current_route=`/sbin/ip route get ${IP}|egrep -o 'dev \w+'|awk {'print $2'}`
        if [[ ${current_route} == $iface ]] ; then
          echo "route is OK for $IP -> $iface , skipping"
        else
          echo "fixing route for $IP -> $iface"
          sudo /sbin/ip route add ${IP}/32 dev ${iface}
        fi
      done
    done
  else
    echo "only one external iface, skipping route setup"
  fi
fi



#remake this into a proper array
all_vips=()
for i in $client_VIPs; do
  all_vips+=(${i})
done

# shuffle...but this may not behave like you want.

#all_vips=( $(shuf -e "${all_vips[@]}") )

#but: if you are using read_bw_reuse , then you definitely want to shuffle.

if [[ ${TEST} == "read_bw_reuse" ]] ; then
  all_vips=( $(shuf -e "${all_vips[@]}") )
fi




sudo umount -lf ${MOUNT}/*

export node=`hostname`


#only use as many mounts as we have threads on this host..
#
needed_vips=()
for ((idx=0; idx<${JOBS} && idx+1<${#all_vips[@]}; ++idx)); do
  needed_vips+=(${all_vips[$idx]})
done


DIRS=()
MD_DIRS=()

for i in ${needed_vips[@]}
        do sudo mkdir -p ${MOUNT}/${i}
        if [[ ${NFS} == "rdma" ]] ; then
          sudo mount -vvv -t nfs -o proto=rdma,port=20049,vers=3 ${i}:/${NFSEXPORT} ${MOUNT}/${i}
        else
          sudo mount -vvv -t nfs -o tcp,rw,vers=3 ${i}:/${NFSEXPORT} ${MOUNT}/${i}
        fi
        export fio_dir=${MOUNT}/$i/${REMOTE_PATH}/${node}/${i}
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

read_bw_reuse_test () {
  #rando_dir=${MOUNT}/${all_vips[0]}/${REMOTE_PATH}/${node}
  rando_dir=${MOUNT}/${all_vips[0]}/${REMOTE_PATH}
  echo ${rando_dir}
  ${FIO_BIN} --name=randrw --ioengine=${ioengine} --iodepth=${iodepth} --rw=randrw --bs=1mb --direct=1 --numjobs=${JOBS} --rwmixread=100 --group_reporting --opendir=${rando_dir} --time_based=1 --runtime=${RUNTIME}
}

cleanup_only () {
  #basically, just skip doing any actual testing, and make sure that routes and mounts are cleaned up.
  echo "I'm only cleaning up..."
}




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




if [[ $DELETE_RUN -eq 1 ]] ; then
  echo "cleaning up everything for ${run_num}"
  for dir in ${DIRS}
    do rm -f ${dir}/randrw.${run_num}
  done
else
  echo "leaving ${run_num} in place. you may want to clean up before you leave.."
fi

# this will clean up anything in dirs
if [[ $DELETE_ALL -eq 1 ]] ; then
  echo "cleaning up everything for ${run_num}"
  for dir in ${DIRS}
    do rm -f ${dir}/*
  done
else
  echo "leaving ${run_num} in place. you may want to clean up before you leave.."
fi



sudo umount -lf ${MOUNT}/*


if [ $IS_VAST == 1 ]; then
  #get rid of routes...change the `3` to `2` if you used the routing affinity.
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
