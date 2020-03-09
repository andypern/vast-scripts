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
#
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

MOUNT=/mnt/demo #where the mountpoints will get created.

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





#VIPs for client access
client_VIPs="$(/usr/bin/curl -s -u admin:123456 -H "accept: application/json" --insecure -X GET "https://$mVIP/api/vips/?vippool__id=${POOL}" | grep -Po '"ip":"[0-9\.]*",' | awk -F'"' '{print $4}' | sort -t'.' -k4 -n | tr '\n' ' ')"
echo $client_VIPs
if [ "x$client_VIPs" == 'x' ] ; then
    echo Failed to retrieve cluster virtual IPs for client access
    exit 20
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
