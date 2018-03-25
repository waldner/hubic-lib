#!/bin/bash

hubic_get_userdef_credentials(){
  hubic_client_id="api_hubic_xxxxxxxxxxxxxxxxxxxxxx"
  hubic_client_key="yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy"
  hubic_login="my@hubic.login"
  hubic_pass="somesecretpassword"
  hubic_return_url="http://localhost/"
}

. hubic-lib.sh

now=$(date "+%F_%H-%M-%S")

keep=6

# create the tarball
/bin/tar -cjf /tmp/backup.tbz2 -C /my/data/directory/ .

if ! hubic_api_init; then
  echo "Hubic library API initialization failed" >&2
  exit 1
fi

if ! hubic_upload_file -p backups -r "backup_${now}.tbz2" -l /tmp/backup.tbz2; then
  echo "Upload not successful" >&2
  exit 1
fi

/bin/rm -f /tmp/backup.tbz2

# cleanup

declare -a files

hubic_list_files -p backups

files=( $(printf '%s\n' "${hubic_object_list[@]}" | sort) )
nfiles=${#files[@]}

if [ $nfiles -gt $keep ]; then
  # remove old ones

  ntodelete=$(( nfiles - keep ))

  for (( i = 0; i < ntodelete; i++ )); do
    # delete
    hubic_delete_object -p "${files[$i]}"
  done
fi

hubic_api_cleanup
