# hubic_lib

This is a knocked-together, "Works for me (TM)" shell library to interact with HubiC storage: upload/download files, create containers, etc. NOT ALL OF THE API IS IMPLEMENTED. See https://developer.openstack.org/api-ref/object-store/ for the full API.
The only dependencies needed are bash, curl and perl.

Yes, all communication in the library is via global variables.

### Getting started

Create an application in your HubiC control panel. Name it whatever you want, and use a made-up return URL (eg, http://localhost/).

You have to source hubic_lib.sh in your script, and implement a function called **hubic_get_userdef_credentials** that sets some environment variables with suitable values (hubic_login and hubic_pass you should know, and the others can be found in your HubiC control panel app settings). See below.

See also the included sample_backup.sh script.

Sample code:

```
#!/bin/bash

hubic_get_userdef_credentials(){
  hubic_client_id=XXXXX
  hubic_client_key=YYYYY
  hubic_login=foo@foo.com
  hubic_pass=ZZZZZZ
  hubic_return_url="http://localhost/"   # or whatever you used in the app
  
  # or read them from a file, from vault, whatever, as long as you set the above variables
}

. hubic_lib.sh

# optionally configure logging

# hubic_set_log_level DEBUG        # valid values: DEBUG, INFO, NOTICE, WARNING], ERROR
# hubic_set_logging_enabled 1      # valid values: 0 = logging disabled, anything else = enabled
# hubic_set_log_destination file   # valid values: file = log to file, stdout = log to stdout (doh!)
                                   # default file: /tmp/hubic_YYYY-MM-DD_hh:mm:ss.log

# Init API (auth app, get tokens, etc)
if ! hubic_api_init; then
  echo "Hubic library API initialization failed" >&2
  exit 1
fi

# now do actual operations
# following switches are supported:
#
# -c container: container name (defaults to "default" if omitted)
# -p path: remote path (ok, they're pseudo, but let's pretend they are real), defaults to ""
# -l localfile: local file name
# -r remotefile: remote file name

# create a container
hubic_create_container -c newcontainer

# create (pseudo)directory "foobar" in container "newcontainer"
hubic_create_directory -c newcontainer -p foobar

# upload local file /tmp/backup.tgz to remote file "newcontainer/foobar/backup-last.tgz"
hubic_upload_file -c newcontainer -p foobar -r backup-last.tgz -l /tmp/backup.tgz 

# get remote file "default/archive.tar.gz", saves to local file /tmp/archive.tar.gz
hubic_download_file -p "" -r "archive.tar.gz" -l /tmp/archive.tar.gz

# delete an object
hubic_delete_object -c oldcontainer -p somepath -r file.tar

# delete a container (fails if not empty)
hubic_delete_container -c oldcontainer

# list containers
hubic_list_containers

for container in "${hubic_object_list[@]}"; do
  echo "container: $container"
done

# list files (really objects), optionally specify a path
hubic_list_files -c newcontainer -p foobar

for object in "${hubic_object_list[@]}"; do
  echo "object: $object"
done

# when done, cleanup
hubic_api_cleanup
```
