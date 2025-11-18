#!/bin/bash

TOP_DOMAIN="ztsubaki.top"

rollback(){
    echo "Rolling back resources..."
    if [ "$instanceId" != "" ]; then
        echo "Deleting instance $instanceId..."
        ./aliyun ecs DeleteInstance --region cn-chengdu --RegionId 'cn-chengdu' --InstanceId $instanceId --Force true
        echo "Waiting for instance to be deleted..."
        while true; do
            status=$(./aliyun ecs DescribeInstanceStatus --region cn-chengdu --RegionId 'cn-chengdu' --InstanceId.1 $instanceId | awk -F '"' '$2=="Status"{print $4}')
            echo "Current status: $status"
            if [ "$status" == "Stopped" ]; then
                break
            fi
            sleep 2
        done
    fi
    if [ "$diskId" != "" ]; then
        echo "Deleting data disk $diskId..."
        ./aliyun ecs DeleteDisk --region cn-chengdu --RegionId 'cn-chengdu' --DiskId $diskId
    fi
    if [ "$recordId" != "" ]; then
        echo "Deleting DNS record $recordId..."
        ./aliyun esa DeleteRecord --region cn-hangzhou --SiteId $SiteId --RecordId $recordId
    fi
}

setDNS(){
    SiteId=$(./aliyun esa ListSites --SiteName "$TOP_DOMAIN" | grep SiteId)
    SiteId=${SiteId#*\"SiteId\": }
    SiteId=${SiteId%,}
    recordId=$(./aliyun esa CreateRecord --region cn-hangzhou --SiteId $SiteId --RecordName autoecs.$TOP_DOMAIN --Proxied false --Type "A/AAAA" --Data {\"Value\":\"$1\"} --Ttl 1 | awk '/RecordId/{print $2}')
    recordId=${recordId%,}
    if [ "$recordId" == "" ]; then
        return 1
    fi
    echo "Set DNS record $recordId, please wait for propagation..."
    while [ "" == "$(nslookup autoecs.$TOP_DOMAIN | grep $ipAddr)" ]
    do
        echo Waiting for DNS propagation...
        sleep 5
    done
}
snapId=$(./aliyun ecs DescribeSnapshots --region cn-chengdu --RegionId 'cn-chengdu' | awk -F '"' '$2=="SnapshotId"{id=$4} $2=="SnapshotName"&&$4~/snapautoecs-/{print id;exit}')

if [ "$snapId" == "" ]; then
    echo "No suitable snapshot found."
    exit 1
fi

echo "Find snapshot: $snapId"

diskId=$(./aliyun ecs CreateDisk --region cn-chengdu --RegionId 'cn-chengdu' --ZoneId 'cn-chengdu-b' --SnapshotId $snapId --DiskName data-disk-autoecs --DiskCategory cloud_auto --Size 20 --BurstingEnabled true | awk -F '"' '/DiskId/{print $4}')

if [ "$diskId" == "" ]; then
    echo "Failed to create data disk."
    rollback
    echo "Field."
    exit 1
fi

echo "Create data disk: $diskId"

instanceId=$(./aliyun ecs RunInstances --region cn-chengdu --RegionId 'cn-chengdu' --ZoneId 'cn-chengdu-b' --LaunchTemplateName game_server --Amount 1 --MinAmount 1 | awk -F '"' '/InstanceIdSets/{getline; getline; print $2}')

if [ "$instanceId" == "" ]; then
    echo "Failed to create instance."
    rollback
    echo "Field."
    exit 1
fi

echo "Create instance: $instanceId"

while true; do
    status=$(./aliyun ecs DescribeInstanceStatus --region cn-chengdu --RegionId 'cn-chengdu' --InstanceId.1 $instanceId | awk -F '"' '$2=="Status"{print $4}')
    echo "Waiting for instance to be running, Current status: $status"
  if [ "$status" == "Running" ]; then
    break
  fi
  sleep 3
done

ipAddr=$(./aliyun ecs DescribeInstances --region cn-chengdu --RegionId 'cn-chengdu' --InstanceIds [\"$instanceId\"] | awk -F '"' '/PublicIpAddress/{getline; getline; print $2}')

if [ "$ipAddr" == "" ]; then
    echo "Failed to get IP address."
    rollback
    echo "Field."
    exit 1
fi

echo "Get IP address: $ipAddr"

./aliyun ecs AttachDisk --region cn-chengdu --RegionId 'cn-chengdu' --InstanceId $instanceId --DiskId $diskId --DeleteWithInstance true > /dev/null

if [ $? -ne 0 ]; then
    echo "Failed to attach disk."
    rollback
    echo "Field."
    exit 1
fi

echo "Attach disk $diskId to instance $instanceId"

setDNS $ipAddr

if [ "$recordId" == "" ]; then
    echo "Failed to set DNS record."
    echo "Please connect to the instance using IP: $ipAddr"
    exit 1
fi

echo "DNS record autoecs.$TOP_DOMAIN set with ID: $recordId"

while true
do    
    ssh ecs-user@autoecs.$TOP_DOMAIN -o StrictHostKeyChecking=no -o UserKnownHostsFile=./known_hosts "mkdir vdb&& sudo mount /dev/vdb1 ./vdb&& sudo chown ecs-user:ecs-user ./vdb&& date > ./vdb/mounted"
    if [ $? -eq 0 ]; then
        echo
        echo "Disk mounted successfully on the instance."
        break
    else
        echo
        echo "Failed to mount disk, retrying in 5 seconds..."
        sleep 5
    fi
done

while true 
do
    ssh ecs-user@autoecs.$TOP_DOMAIN -o StrictHostKeyChecking=no -o UserKnownHostsFile=./known_hosts "cd vdb && ./init.sh"
    if [ $? -eq 0 ]; then
        echo
        echo 
        echo "Initialization script executed successfully on the instance."
        break
    else
        echo 
        echo 
        echo "Failed to execute initialization script, retrying in 5 seconds..."
        sleep 5
    fi
done

rm ./known_hosts

echo Success.
