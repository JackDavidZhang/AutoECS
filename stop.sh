#!/bin/bash

TOP_DOMAIN="ztsubaki.top"

instanceId=$(./aliyun ecs DescribeInstances --region cn-chengdu --RegionId 'cn-chengdu' --InstanceName autoecs | awk -F '"' '/InstanceId/{print $4}')

if [ -z "$instanceId" ]; then
  echo "No instance found with the name 'autoecs', maybe it is not started."
  exit 1
fi

echo "Find instance: $instanceId"

ipAddr=$(./aliyun ecs DescribeInstances --region cn-chengdu --RegionId 'cn-chengdu' --InstanceIds [\"$instanceId\"] | awk -F '"' '/PublicIpAddress/{getline; getline; print $2}')

if [ -z "$ipAddr" ]; then
  echo "Failed to get IP address for instance $instanceId."
  exit 1
fi

echo "Get IP address: $ipAddr"

essdId=$(./aliyun ecs DescribeDisks --region cn-chengdu --RegionId 'cn-chengdu' --InstanceId $instanceId | awk -F '"' '/DiskId/{id=$4}$2=="Type"&&$4=="data"{print id;exit}')

if [ -z "$essdId" ]; then
  echo "Failed to get data disk ID for instance $instanceId."
  exit 1
fi

echo "Get ESSD: $essdId"

snapId=$(./aliyun ecs CreateSnapshot --region cn-chengdu --DiskId $essdId --SnapshotName snapautoecs-`date +%s` | awk -F '"' '/SnapshotId/{print $4}')

if [ -z "$snapId" ]; then
  echo "Failed to create snapshot for disk $essdId."
  exit 1
fi

echo "Create snapshot: $snapId"

ssh ecs-user@$ipAddr -o StrictHostKeyChecking=no -o UserKnownHostsFile=./known_hosts "cd vdb && ./stop.sh"
if [ $? -ne 0 ]; then
    echo "Failed to exec stop script on instance."
    echo "Please conform to fore stop the instance: $instanceId [y/N]"
    read answer
    case $answer in
        [Yy]* ) echo "Proceeding to stop the instance...";;
        * ) echo "Aborting."; exit 1;;
    esac
else
    echo "Stop script executed successfully."
fi

./aliyun ecs StopInstance --region cn-chengdu --InstanceId $instanceId > /dev/null

if [ $? -ne 0 ]; then
  echo "Failed to stop instance $instanceId."
  echo "You may need to stop it manually."
else
    echo "Instance $instanceId is stopping..."
    while true; do
        status=$(./aliyun ecs DescribeInstanceStatus --region cn-chengdu --RegionId 'cn-chengdu' --InstanceId.1 $instanceId | awk -F '"' '$2=="Status"{print $4}')
        echo "Current status: $status"
    if [ "$status" == "Stopped" ]; then
        break
    fi
    sleep 2
    done

    echo "Instance $instanceId has stopped."

    ./aliyun ecs DeleteInstance --region cn-chengdu --InstanceId $instanceId > /dev/null
    if [ $? -ne 0 ]; then
      echo "Failed to delete instance $instanceId."
      echo "You may need to delete it manually."
      exit 1
    else
        echo "Instance $instanceId has been deleted."
    fi
fi

SiteId=$(./aliyun esa ListSites --SiteName "$TOP_DOMAIN" | grep SiteId)
SiteId=${SiteId#*\"SiteId\": }
SiteId=${SiteId%,}

for id in $(./aliyun esa ListRecords --region cn-hangzhou --SiteId $SiteId --RecordName autoecs.$TOP_DOMAIN | grep RecordId | awk '{print $2}' | awk -F ',' '{print $1}')
do
    ./aliyun esa DeleteRecord --region cn-hangzhou --RecordId $id > /dev/null
    if [ $? -ne 0 ]; then
        echo "Failed to delete DNS record $id."
        echo "You may need to delete it manually."
    else
        echo delete record $id
    fi
done

rm ./known_hosts

echo Success.
