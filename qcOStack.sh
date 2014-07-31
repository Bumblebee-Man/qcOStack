#!/bin/bash
#
#
#
# Script to QC RPC environment
set --

#check QC status
outputStatus() {
  if [[ ${1} = "y" ]]; then
    echo  "QC PASS: "${2}
  elif [[ ${1} = "n" ]]; then
    echo  "QC FAIL: "${2}
  else
    echo  "NOT TESTED: "$*
  fi
}

checkStatus() {
  echo -e '******************************************'
  outputStatus $rabbitStatus ' RabbitMQ'
  outputStatus $myRepl ' MySQL Replication'
  outputStatus $tenantUser ' User and Tenant Created'
  outputStatus $glanceImages ' Glance Images Uploaded'
  outputStatus $instanceSuccess ' Instance Availability'
  outputStatus $snapshot ' Snapshot Creation'
  outputStatus $floatingIP ' Floating IPs'
  outputStatus $cinderVolume ' Cinder Volumes'
  outputStatus $nimCheck ' Nimbus Installed'
  echo -e '******************************************'
}

buildInstance() {

nova boot --image $(nova image-list | awk '/Ubuntu/ {print $2}' | tail -1) \
      --flavor 2 \
      --security-group rpc-support \
      --key-name controller-id_rsa \
      --nic net-id=$network \
      $buildOption \
      $testInstanceName >/dev/null;
}


control_c()
# run if user hits control-c
{
  echo -en "\n*** Ouch! Exiting ***\n"
  checkStatus
  exit 1
}

# trap keyboard interrupt (control-c)
trap control_c SIGINT

# Output and verify rabbitMQ cluster status

/usr/sbin/rabbitmqctl cluster_status

while [ -z $rabbitStatus ]; do
  echo -e 'Is the RabbitMQ cluster status correct? (y/n)'
  read rabbitStatus
done

if [ $rabbitStatus != "y" ]; then
  echo 'Please correct RabbitMQ cluster then run the QC script again.'
  checkStatus
  exit 0
fi


# build instances on each network and each compute node
# then attempt to ping from each instance to 8.8.8.8
 
echo 'Building instances, this may take several minutes.'
for NET in $(nova net-list | awk '/[0-9]/ && !/GATEWAY/ {print $2}');
  do for COMPUTE in $(nova hypervisor-list | awk '/[0-9]/ {print $4}');
    do computeNode=$COMPUTE
       buildOption="--availability-zone nova:$COMPUTE"
       network=$NET
       testInstanceName="rstest-$network-$COMPUTE"
       buildInstance
    done

  sleep 30

  for IP in $(nova list | sed 's/.*=//' | egrep -v "\+|ID" | sed 's/ *|//g');
    do echo "$IP"': Attempting to ping 8.8.8.8 three times';
    pingTest=$(ip netns exec qdhcp-$NET ssh -n -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$IP "ping -c 3 8.8.8.8 | grep loss 2>/dev/null")
    if echo $pingTest | grep '100% packet loss'; then
      echo 'Instances not able to ping out! Please investigate.'
      instanceSuccess=n
      checkStatus
      exit 0
    else
      instanceSuccess=y
    fi
  done

  if [ $instanceSuccess = "y" ]; then
    echo 'Deleting instances from network '"$NET"
    for ID in $(nova list | awk '/[0-9]/ {print $2}');
      do nova delete $ID;
    done
  else
    echo 'Please correct issues and run QC script again.'
    checkStatus
    exit 0
  fi
done

#if replication is configured, test to make sure it's working

if mysql mysql -e 'SELECT User FROM user\G' | grep -q repl; then
  echo 'MySQL replication configured.'
  slave=$(mysql -e "SHOW SLAVE STATUS\G" | awk '/Master_Host/ {print $2}')
  slaveSecsBehind=$(ssh $slave "mysql -e 'SHOW SLAVE STATUS\G' | grep 'Seconds_Behind_Master'")
  if ! mysql -e 'SHOW SLAVE STATUS\G' | grep -q "Slave_IO_Running: Yes"; then
    echo 'MySQL replication possibly broken (Slave IO not running)! Please investigate.'
    exit 0
  elif ! mysql -e 'SHOW SLAVE STATUS\G' | grep -q "Slave_SQL_Running: Yes"; then
    echo 'MySQL replication possibly broken (Slave SQL not running)! Please investigate.'
    exit 0
  elif [ $(mysql -e 'SHOW SLAVE STATUS\G' | awk '/Seconds_Behind_Master/ {print $2}') -gt 0 ]; then
    echo 'MySQL replication possibly broken! The slave is behind master!'
    exit 0
  elif ! ssh $slave 'mysql -e "SHOW SLAVE STATUS\G" | grep -q "Slave_SQL_Running: Yes"'; then
    echo 'MySQL replication possibly broken (Slave SQL not running) on slave! Please investigate.'
    exit 0
  elif ! ssh $slave 'mysql -e "SHOW SLAVE STATUS\G" | grep -q "Slave_SQL_Running: Yes"'; then
    echo 'MySQL replication possibly broken (Slave SQL not running) on slave! Please investigate.'
    exit 0
  elif [ $(echo $slaveSecsBehind | awk '{print $2}') -gt 0 ]; then
    echo 'MySQL replication possibly broken! The slave is behind master on the slave!'
    exit 0
  else
    echo 'MySQL replication looks good!'
    myRepl=y
  fi
fi

# Verify keystone user and tenant

echo '******************************************'
echo
echo 'Keystone users:'
keystone user-list | egrep -v 'ceilometer|cinder|glance|monitoring|neutron|nova' | awk '/True/ {print $2, $4}'
echo
echo '******************************************'
echo
echo 'Keystone tenants:'
keystone tenant-list | egrep -v 'service' | awk '/True/ {print $2, $4}'
echo
echo '******************************************'

while [ -z $tenantUser ]; do
  echo 'Is user/tenant created? (y/n)'
  read tenantUser
done

# Verify Glance images

echo '******************************************'
echo
echo 'Glance Images:'
glance index
echo
echo '******************************************'

while [ -z $glanceImages ]; do
  echo 'Are Glance images uploaded? (y/n)'
  read glanceImages
done

# Verify snapshot

echo 'Booting an instance and testing snapshot. This may take several minutes.'
network=$(nova net-list | awk '/[0-9]/ && !/GATEWAY/ {print $2}' | tail -n1)
testInstanceName="rs-snap-test"
buildInstance

sleep 30
nova image-create $(nova list | awk '/rs-snap-test/ {print $2}') rs_snapshot_test

count=0
while [ $(nova image-list | awk '/rs_snapshot_test/ {print $6}') = "SAVING" ]; do
  sleep 5
  echo 'Waiting for snapshot to save.'
  count=$[count = $count + 1]
  if [ $(echo $count) -gt 15 ]; then
    echo 'Snapshot taking too long to save. Please investigate.'
    exit 0
    checkStatus
  fi
done

if [ $(nova image-list | awk '/rs_snapshot_test/ {print $6}') = "ERROR" ]; then
  echo "There was a problem creating the snapshot. Please investigate."
  exit 0
  checkStatus
else
  echo "Snapshot successful."
  nova image-delete $(nova image-list | awk '/rs_snapshot_test/ {print $2}')
  nova delete $(nova list | awk '/rs-snap-test/ {print $2}')
  snapshot=y
fi

# TODO floating IP check - add more error tests

# Check/test floating IPs

if nova floating-ip-pool-list | egrep -v '\+|name' >/dev/null; then
  echo 'Floating IP Pool Created. Testing floating IP, this may take several minutes.'
  floatPool=$(nova floating-ip-pool-list | egrep -v '\+|name' | sed 's/|//g')
  nova floating-ip-create $floatPool >/dev/null  
  network=$(nova net-list | awk '/[0-9]/ && !/GATEWAY/ {print $2}' | tail -n1)
  testInstanceName="rs-float-test"
  buildInstance
  sleep 30
  floatIP=$(nova floating-ip-list | egrep -v '\+|Ip' | awk '{print $2}')
  floatInstance=$(nova list | awk '/rs-float-test/ {print $2}')
  nova add-floating-ip $floatInstance $floatIP
  sleep 20
  if ! nova list | grep $floatIP >/dev/null; then
    echo 'There was a problem assigning the floating IP. Please investigate.'
    floatingIP=n
    checkStatus
    exit 0
  else
    echo 'Floating IP assigned. Please try pinging the PUBLIC IP that NATs to '$floatIP
    while [ -z $floatingIP ]; do
      echo 'Does floating IP ping? (y/n)'
      read floatingIP
    done
    nova delete $(nova list | awk '/rs-float-test/ {print $2}')
    nova floating-ip-delete $floatIP
  fi 
fi

# TODO Cinder volumes - Add more error tests and clean up

# Test Cinder

if cinder service-list | grep "cinder-volume" >/dev/null; then
  echo 'Cinder configured. Verifing volume creation and attachment. This may take several minutes.'
  network=$(nova net-list | awk '/[0-9]/ && !/GATEWAY/ {print $2}' | tail -n1)
  testInstanceName="rs-cinder-test"
  buildInstance
  sleep 30
  cinder create --display-name "rs-cinder-test" 10 >/dev/null
  sleep 10
  cinderVolumeUUID=$(cinder list | awk '/rs-cinder-test/ {print $2}')
  cinderInstance=$(nova list | awk '/rs-cinder-test/ {print $2}')
  cinderInstanceIP=$(nova list | sed 's/.*=//' | egrep -v "\+|ID" | sed 's/ *|//g')
  nova volume-attach $cinderInstance $cinderVolumeUUID /dev/vdb >/dev/null
  sleep 10
  cinderDetails=$(ip netns exec qdhcp-$network ssh -n -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ubuntu@$cinderInstanceIP "sudo fdisk -l")
  sleep 10
  if echo $cinderDetails | grep '/dev/vdb' >/dev/null; then
    echo 'Cinder volume attached successfully.'
    nova delete $testInstanceName
    sleep 5
    cinder delete $cinderVolumeUUID
    cinderVolume=y
  else
    echo 'Cinder volume did not attach successfully! Please investigate.'
    cinderVolume=n
    checkStatus
    exit 0
  fi
fi  

# Verify NimBUS installed and openstack probes installed

if ps auwx | grep 'nimbus(cdm)' | grep -v grep >/dev/null; then
  echo 'NimBUS installed. Verifying Openstack probe installed.'
  if [ -d /opt/nimbus/probes/openstack/ ]; then
    echo 'Openstack probe installed.'
    nimCheck=y
  else
    echo 'Openstack probe does not seem to be present. Please investigate.'
    nimCheck=n
  fi
else
  echo 'NimBUS does not seem to be installed properly (CDM probe not installed). Please investigate.'
  nimCheck=n
fi


#print QC status output
checkStatus
