for i in $(openstack baremetal node list -c Name -f value); 
do 
	echo "saving disks data for" $i ;
	openstack baremetal introspection data save $i | jq .inventory.disks > introspection_disks_$i
done
