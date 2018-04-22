for i in $(openstack baremetal node list -c Name -f value); 
do 
openstack baremetal node set --property root_device='{"name": "/dev/sda"}' $i
openstack baremetal node show $i ;
done
