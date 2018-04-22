for i in $(openstack baremetal node list -c Name -f value); 
do 
openstack baremetal node show $i ; 
done
