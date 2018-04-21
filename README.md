# hubic_lib

This is a knocked-together, "Works for me (TM)" shell library to interact with HubiC storage: upload/download files, create containers, etc. NOT ALL OF THE API IS IMPLEMENTED. See https://developer.openstack.org/api-ref/object-store/ for the full API.

## Dependencies

The only dependencies needed are [bash](https://www.gnu.org/software/bash/), [curl](https://curl.haxx.se/) and [perl](https://www.perl.org/). Well, and **rm**, but if you don't have that you have bigger problems than not being able to use this library.

## Installation

No special installation needed. Just put **`hubic-lib.sh`** wherever you want. You have to know the location because you'll have to source it in your script.

## Getting started

- Create an application in your HubiC control panel. Name it whatever you want, and use a made-up return URL (eg, http://localhost/). It's not used here, but it has to be present.

- Source `hubic-lib.sh` in your script

- Implement a function called `hubic_get_userdef_credentials` that sets some environment variables with suitable values (`hubic_lib[login]` and `hubic_lib[pass]` you should know, and the others can be found in your HubiC control panel app settings). See below.

- Call `hubic_api_init` and check that it returns without errors.

- At this point, you can perform storage operation by invoking functions like `hubic_upload_file`, `hubic_delete_container` and others. See below for more.

- When you're done using the storage, call `hubic_api_cleanup`.

- Profit. 

## Logging

Sourcing the library gives you access to a very rudimentary log function called `hubic_log`. Its arguments are a log level (one of  DEBUG, INFO, NOTICE, WARNING, ERROR) and the message to log. You can use this function to log your application messages together with those coming from the library. By default, the library detects automatically whether to log to file or to stdout (if stdout is not a terminal, log to file; otherwise log to stdout). This allows eg running from cron without getting output, but still being able to manually run on the command line and see the messages. The log destination can however be forced. The minimum logging level can also be configured, or logging can be turned off altogether. See code below for examples.

## Internals

All the variables used by the library are kept in an associative array called `hubic_lib`. 

Since the REST API sometimes fails with transient errors, each operation defines a series of HTTP return codes upon which the function is considered to have completed; any other HTTP code produces a retry of the operation, up to a maximum, by default, of 3 times.

After each file API function invocation, the three variables `hubic_lib['last_http_headers']`, `hubic_lib['last_http_body']` and `hubic_lib['last_http_code']` contain what their name says, so they can be inspected in your code for extra control. Additionally, after operations that return lists of objects, `hubic_lib['object_list']` is set with such list (a single variable of newline-separated strings), and can be accessed from your code.

Each file API operation ends up invoking `hubic_do_operation` internally, after setting the appropriate (global) parameters (via `hubic_parse_args`). `hubic_do_operation`, in turn, calls `hubic_do_single_operation`, handling retries in case of transient errors. Finally, `hubic_do_single_operation` calls `hubic_do_curl` (which does the actual curl invocation) and returns success or failure (based on the HTTP return code) all the way up.

## Sample code

(See also the included `sample-backup.sh` script.)

```
#!/bin/bash

hubic_get_userdef_credentials(){
  hubic_lib['client_id']=XXXXX
  hubic_lib['client_key']=YYYYY
  hubic_lib['login']=foo@foo.com
  hubic_lib['pass']=ZZZZZZ
  hubic_lib['return_url']="http://localhost/"   # or whatever you used in the app
  
  # or read them from a file, from vault, whatever, as long as you set the above variables
}

. /path/to/hubic-lib.sh

# OPTIONAL: configure logging

# hubic_set_log_level DEBUG        # valid values: DEBUG, INFO, NOTICE, WARNING], ERROR
# hubic_set_logging_enabled 1      # valid values: 0 = logging disabled, anything else = enabled
# hubic_set_log_destination file   # valid values: file = log to file, stdout = log to stdout (doh!)
                                   # default file: /tmp/hubic_YYYY-MM-DD_hh:mm:ss.log

# OPTIONAL: configure retry behaviour
# hubic_set_retries 4              # retry up to 4 times when operation fails

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

hubic_log INFO "Now I'm going to download a file"

# get remote file "default/archive.tar.gz", saves to local file /tmp/archive.tar.gz
hubic_download_file -p "" -r "archive.tar.gz" -l /tmp/archive.tar.gz

# delete an object
hubic_delete_object -c oldcontainer -p somepath -r file.tar

# delete a container (fails if not empty)
hubic_delete_container -c oldcontainer

# list containers
hubic_list_containers

declare -a containers

oIFS=$IFS
IFS=$'\n'
containers=( ${hubic_lib['object_list']} )
IFS=$oIFS

# hubic_object_list is set by the previous function
for container in "${containers[@]}"; do
  : # do something with "$container"
done

# list files (really objects), optionally specify a path
hubic_list_files -c newcontainer -p foobar

declare -a objects

oIFS=$IFS
IFS=$'\n'
objects=( ${hubic_lib['object_list']} )
IFS=$oIFS

for object in "${objects[@]}"; do
  : # do something with "$object"
done

# when done, cleanup
hubic_api_cleanup
```
