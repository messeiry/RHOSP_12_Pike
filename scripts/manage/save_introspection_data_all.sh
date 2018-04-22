for i in $(openstack baremetal node list -c Name -f value); 
do 
	echo "saving data for" $i ;
	openstack baremetal introspection data save $i | jq .[] > introspection_all_$i
done
