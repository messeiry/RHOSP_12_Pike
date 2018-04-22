for i in $(openstack baremetal node list -c Name -f value); 
do 
	echo "saving numa data for" $i ;
	openstack baremetal introspection data save $i | jq .numa_topology > introspection_numa_$i
done
