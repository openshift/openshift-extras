These files are intended to be used by mod_auth_form as referenced here:
https://docs.openshift.com/enterprise/3.0/admin_guide/configuring_authentication.html#RequestHeaderIdentityProvider

They were created simply as a referenced by scraping the html from the default
Origin login and logout pages.  The href's were made relative and the inlined
logos were removed.  The assumption is that the assests would be served from a
proxy that redirects the browser to the correct location of the Master.
