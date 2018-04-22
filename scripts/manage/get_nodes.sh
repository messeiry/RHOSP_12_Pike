for i in $(openstack baremetal node list -c Name -f value); do echo $i ; done
