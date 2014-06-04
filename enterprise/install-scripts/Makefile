all: amazon/openshift-amz.sh generic/openshift.sh vm/openshift-vm.ks

clean:
	rm -f generic/openshift.ks amazon/openshift-amz.sh generic/openshift.sh vm/openshift-vm.ks

vm/openshift-vm.ks: openshift.ks vm/to_rhel_vm vm/parts/*
	vm/to_rhel_vm openshift.ks $@

generic/openshift.sh: openshift.ks generic/scriptify 
	generic/scriptify openshift.ks $@

amazon/openshift-amz.sh: openshift.ks amazon/openshift-amz.sh.conf amazon/openshift-amz-ext.sh amazon/to_amz_conf
	amazon/to_amz_conf openshift.ks $@
