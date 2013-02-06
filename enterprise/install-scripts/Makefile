all: generic/openshift.ks amazon/openshift-amz.sh generic/openshift.sh

clean:
	rm -f generic/openshift.ks amazon/openshift-amz.sh generic/openshift.sh

generic/openshift.ks: openshift.ks
	generic/converter openshift.ks $@

generic/openshift.sh: generic/openshift.ks
	generic/scriptify generic/openshift.ks $@

amazon/openshift-amz.sh: openshift.ks amazon/openshift-amz.sh.conf
	sed -e '0,/^%post/d;/^%end/,$$d' openshift.ks > $@
	sed -i -e 's/2012-10-22/2012-10-23/g' $@
	sed -i -e 's/^configure_rhel_repo$$/#&/' $@
	sed -i -e 's/^configure_hostname$$/#&/' $@
	sed -i -e 's/^update_resolv_conf$$/#&/' $@
	sed -i -e 's/^gpgcheck=0/gpgcheck=0\nsslverify=false/g' $@
	sed -i -e '1r amazon/openshift-amz.sh.conf' $@
	sed -i -e '1d' $@
	cat amazon/openshift-amz-ext.sh >> $@
