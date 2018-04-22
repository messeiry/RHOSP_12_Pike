#!/bin/bash
openstack overcloud deploy --templates \
  -e /home/stack/templates/node-info.yaml \
  -e /home/stack/templates/overcloud_images.yaml \
  -e /home/stack/templates/network-environment.yaml \
  -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml \
  -e /home/stack/templates/firstboot-environment.yaml \
  -e /usr/share/openstack-tripleo-heat-templates/environments/ceph-ansible/ceph-ansible.yaml \
  --libvirt-type qemu \
  --stack overcloud7 \
  --ntp-server 192.168.1.200 | tee overcloud-deploy-7.log 
