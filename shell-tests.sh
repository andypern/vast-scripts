#!/usr/bin/bash

vips=()

for ip in `seq 22`; do
  vips+=(${ip})
done


#echo ${vips[10]}

MAX_THREADS=11

for node in `seq 16`; do
  node_map=()
  array_start=$(( $node - 1 ))
  array_end=$(($array_start + $MAX_THREADS))
  #echo "start: $array_start , end: $array_end"
  for ((idx=$array_start; idx<=${array_end};idx++)); do
    #echo "index:$idx : vip: ${vips[$idx]}"
    node_map+=(${vips[$idx]})
    #echo $node_map
  done
  echo "$node -> ${node_map[@]}"
done
