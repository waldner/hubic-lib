#!/bin/bash

declare -A hubic_log_levels=( [DEBUG]=0 [INFO]=1 [NOTICE]=2 [WARNING]=3 [ERROR]=4 )

hubic_get_curtime(){
  perl -MTime::localtime -e '$tm = localtime; printf("%04d-%02d-%02d %02d:%02d:%02d\n", $tm->year+1900, ($tm->mon)+1, $tm->mday, $tm->hour, $tm->min, $tm->sec);'
}

hubic_curtime=$(hubic_get_curtime)
hubic_curtime=${hubic_curtime/ /_}

hubic_log_file="/tmp/hubic_${hubic_curtime}.log"

hubic_cookiejar=/tmp/hubic.cookies

hubic_log(){

  local level=$1 msg=$2

  local curtime=$(hubic_get_curtime)
 
  if [ $hubic_logging_enabled != "0" ] && [ ${hubic_log_levels[$level]} -ge ${hubic_current_log_level} ]; then
    if [ "$hubic_log_destination" = "stdout" ]; then
      echo "$curtime $level: $msg"
    else
      echo "$curtime $level: $msg" >> "${hubic_log_file}"
    fi
  fi
}

hubic_set_retries(){
  hubic_retries=$1
  [[ ! "$hubic_retries" =~ ^[0-9]+$ ]] && hubic_retries=3
}

hubic_set_log_level(){
  hubic_current_log_level=${hubic_log_levels[$1]}

  if [ "$hubic_current_log_level" = "" ]; then
    hubic_current_log_level=${hubic_log_levels[INFO]}
  fi
}

hubic_set_logging_enabled(){
  hubic_logging_enabled=$1    # 0 disabled, anything else enabled
}

hubic_set_log_destination(){
  if [ "$1" = "" ]; then
    if [ -t 1 ]; then
      # log to stdout
      hubic_log_destination="stdout"
    else
      # log to file
      hubic_log_destination="file"
    fi
  else
    hubic_log_destination="$1"
    [[ "$hubic_log_destination" =~ ^(stdout|file)$ ]] && hubic_log_destination=stdout
  fi
}

#### DEFAULT VALUES
hubic_set_log_level INFO
hubic_set_logging_enabled "1"
hubic_set_log_destination
hubic_set_retries 3

hubic_api_cleanup(){
  $rm -f "$hubic_cookiejar"
}

hubic_get_credentials(){

  hubic_log INFO "Getting Hubic credentials..."

  local hubic_userdef_cred_function=hubic_get_userdef_credentials

  if ! declare -F hubic_get_userdef_credentials >/dev/null; then
    hubic_log ERROR "Function '$hubic_userdef_cred_function()' does not exist, must define it and make sure it sets variables 'hubic_client_id', 'hubic_client_key', 'hubic_login', 'hubic_pass', 'hubic_return_url'"
    return 1
  fi

  $hubic_userdef_cred_function   # user MUST implement this

  ( [ "$hubic_client_id" != "" ] && \
    [ "$hubic_client_key" != "" ] && \
    [ "$hubic_login" != "" ] && \
    [ "$hubic_pass" != "" ] && \
    [ "$hubic_return_url" != "" ] ) || \

    { hubic_log ERROR "Cannot get hubic credentials; make sure '$hubic_userdef_cred_function()' sets variables 'hubic_client_id', 'hubic_client_key', 'hubic_login', 'hubic_pass', 'hubic_return_url'" && return 1; }
}

check_required_binaries(){

  hubic_log INFO "Checking required binaries..."
    
  local retcode=0

  curl=$(command -v curl)
  perl=$(command -v perl)
  rm=$(command -v rm)

  ( [ "$curl" != "" ] && \
    [ "$perl" != "" ] && \
    [ "$rm" != "" ] ) || \
  { hubic_log ERROR "Cannot find needed binaries, make sure you have curl, perl and rm in your PATH" && return 1; }
}



hubic_check_api_initialized(){
  if [ "$hubic_api_initialized" != "1" ]; then
    hubic_log ERROR "hubic API not initialized, call hubic_api_init first"
    return 1
  fi
}

hubic_get_oauth_id(){

  hubic_log INFO "Getting OAUTH ID from form..."

  hubic_parse_args -o "${FUNCNAME[0]#hubic_}" -sc 200

  if ! hubic_do_operation "${hubic_first_url}"; then
    return 1
  fi
  
  hubic_oauth_form_id=$($perl -n0777e 's|.*<input type="hidden" name="oauth" value="(\d+)">.*|$1|s; print' <<< "$hubic_last_http_body")

  hubic_log DEBUG "OAUTH form ID is $hubic_oauth_form_id"

}

hubic_grant_access(){

  hubic_log INFO "Granting access..."

  hubic_parse_args -o "${FUNCNAME[0]#hubic_}" -sc 302

  # submit form accepting everything
  if ! hubic_do_operation -X POST \
    -A "Mozilla/5.0 (Windows NT 6.3; WOW64; rv:30.0) Gecko/20100101 Firefox/30.0" \
    -H "Referer: ${hubic_first_url}" \
    -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
    -H 'Accept-Language: en-US,en;q=0.5' \
    --data-urlencode "credentials=r" \
    --data-urlencode "getAllLinks=r" \
    --data-urlencode "links=r" \
    --data-urlencode "usage=r" \
    --data-urlencode "oauth=${hubic_oauth_form_id}" \
    --data-urlencode "action=accepted" \
    --data-urlencode "account=r" \
    --data-urlencode "login=${hubic_login}" \
    --data-urlencode "user_pwd=${hubic_pass}" \
    https://api.hubic.com/oauth/auth/; then
    return 1
  fi

  hubic_redir_url=$($perl -ne 'print $1 if /^Location: (.*)/;' <<< "$hubic_last_http_headers")

  if [[ ! "$hubic_redir_url" =~ ^$hubic_return_url ]]; then
    hubic_log ERROR "Looks like malformed redirection URL: $hubic_redir_url (should begin with $hubic_return_url)"
    return 1
  fi

  hubic_log DEBUG "Redirection URL is $hubic_redir_url"

  # extract code from url

  # https://whatever.com/?code=cccccccccccccccccccccccccccccc&scope=nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn&state=zzzzzzzzzzzzzz

  hubic_auth_code=$($perl -n0777e 's|.*code=([^&]+).*|$1|s; print' <<< "$hubic_redir_url")

  hubic_log DEBUG "Auth code is $hubic_auth_code"
}

hubic_get_access_token(){

  local base64_auth=$($perl -MMIME::Base64 -e 'print MIME::Base64::encode_base64($ARGV[0], "")' "${hubic_client_id}:${hubic_client_key}")

  hubic_parse_args -o "${FUNCNAME[0]#hubic_}" -sc 200

  hubic_log INFO "Getting access token..."

  if ! hubic_do_operation -X POST \
    -H "Authorization: Basic ${base64_auth}" \
    --data-urlencode "code=${hubic_auth_code}" \
    --data-urlencode "redirect_uri=${hubic_redir_url}" \
    --data-urlencode "grant_type=authorization_code" \
    https://api.hubic.com/oauth/token/; then

    return 1
  fi

  hubic_log DEBUG "json is: $hubic_last_http_body"

  #{"refresh_token":"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz","expires_in":21600,"access_token":"kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk","token_type":"Bearer"}

  hubic_access_token=$($perl -n0777e 's|.*"access_token":"([^"]+)".*|$1|s; print' <<< "$hubic_last_http_body")

  hubic_log DEBUG "access token is: $hubic_access_token"

}


hubic_get_file_credentials(){

  hubic_log INFO "Getting file API credentials..."

  hubic_parse_args -o "${FUNCNAME[0]#hubic_}" -sc 200

  if ! hubic_do_operation -X GET \
    -H "Authorization: Bearer ${hubic_access_token}" \
    https://api.hubic.com/1.0/account/credentials/; then
    return 1
  fi

  #{"token":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","endpoint":"https://aaaaaa.bbbb.ccccc.dddd/v1/yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy","expires":"2014-07-23T10:48:08+02:00"}

  hubic_file_token=$($perl -n0777e 's|.*"token":"([^"]+)".*|$1|s; print' <<< "$hubic_last_http_body")
  hubic_file_endpoint=$($perl -n0777e 's|.*"endpoint":"([^"]+)".*|$1|s; print' <<< "$hubic_last_http_body")
  #expires=$($perl -n0777e 's|.*"expires":"([^"]+)".*|$1|s; print' <<< "$json")

  hubic_log DEBUG "token is $hubic_file_token, endpoint is $hubic_file_endpoint"


}

hubic_urlencode(){
  printf '%s' "$1" | $perl -pe 's/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg'
}

hubic_api_init(){

  hubic_log NOTICE "HUBIC API initialization starting..."

  check_required_binaries || return 1
  hubic_get_credentials || return 1

  $rm -f "$hubic_cookiejar"
  hubic_api_initialized="0"

  local return_url_encoded=$(hubic_urlencode "$hubic_return_url")

  hubic_first_url="https://api.hubic.com/oauth/auth/?client_id=${hubic_client_id}&redirect_uri=${return_url_encoded}&scope=usage.r,account.r,getAllLinks.r,credentials.r,activate.w,links.drw&response_type=code&state=zzzzzzzzzzzzzz"

  hubic_get_oauth_id || return 1
  sleep 3
  hubic_grant_access || return 1
  hubic_get_access_token || return 1
  hubic_get_file_credentials || return 1

  hubic_log NOTICE "HUBIC API initialization completed"

  hubic_api_initialized="1"

}

hubic_download_file(){

  hubic_check_api_initialized || return 1

  hubic_parse_args "$@" -o "${FUNCNAME[0]#hubic_}" -sc 200,404 

  if [ "$hubic_current_remote_file" = "" ]; then
    hubic_log ERROR "No remote file specified to download"
    return 1
  fi

  if [ "$hubic_current_local_file" = "" ]; then
    hubic_log INFO "No local file specified, using same name as remote"
    hubic_current_local_file=$hubic_current_remote_file
  fi

  if [ "$hubic_current_path" != "" ]; then
    hubic_current_path="${hubic_current_path}/"
  fi

  local src="${hubic_current_path}${hubic_current_remote_file}"

  hubic_log INFO "Downloading remote file '${hubic_current_container}/$src' to local file '$hubic_current_local_file'"

  hubic_do_operation -X GET -o "$hubic_current_local_file" \
    -H "X-Auth-Token: $hubic_file_token" \
    "${hubic_file_endpoint}/${hubic_current_container}/${src}"

}

hubic_upload_file(){

  hubic_check_api_initialized || return 1

  hubic_parse_args "$@" -o "${FUNCNAME[0]#hubic_}" -sc 201

  if [ ! -r "$hubic_current_local_file" ]; then
    hubic_log ERROR "Local file '$hubic_current_local_file' does not exist or is not readable"
    return 1
  fi

  if [ "$hubic_current_remote_file" = "" ]; then
    # just use same name as local
    hubic_current_remote_file=$($perl -MFile::Basename -e 'print ((fileparse($ARGV[0]))[0]);' "$hubic_current_local_file")
  fi

  if [ "$hubic_current_path" != "" ]; then
    hubic_current_path="${hubic_current_path}/"
  fi

  local dest="${hubic_current_path}${hubic_current_remote_file}"

  hubic_log INFO "Uploading local file '$hubic_current_local_file' to remote '${hubic_current_container}/${dest}'"

  # disable Expect: 100 header
  hubic_do_operation -X PUT \
    -T "${hubic_current_local_file}" \
    -H "X-Auth-Token: $hubic_file_token" \
    -H "Expect:" \
    "${hubic_file_endpoint}/${hubic_current_container}/${dest}"
}

hubic_do_operation(){

  local retries=0
  local result

  while true; do

    hubic_do_single_operation "$@"

    if [ $? -ne 0 ]; then

      if [ $retries -lt $hubic_retries ]; then
        ((retries++))
        hubic_log WARNING "Retrying operation $hubic_current_operation ($retries of $hubic_retries)..."
        sleep 5
      else
        hubic_log WARNING "Maximum number of tries exceeded for $hubic_current_operation, giving up..."
        return 1
      fi
    else
      return 0
    fi
  done
}


hubic_do_single_operation(){

  hubic_do_curl "$@"

  hubic_log DEBUG "$hubic_current_operation HTTP code: $hubic_last_http_code"

  if hubic_array_contains "$hubic_last_http_code" "${hubic_current_success_codes[@]}"; then
    return 0
  else
    hubic_log WARNING "$hubic_current_operation got HTTP code $hubic_last_http_code, expected $(hubic_join_array "${hubic_current_success_codes[@]}")"
    return 1
  fi
}

hubic_join_array(){

  local string= sep= element

  for element in "$@"; do
    string="${string}${sep}${element}"
    sep=,
  done

  echo "$string"
}


hubic_array_contains(){

  local value=$1
  local element
  shift

  for element in "$@"; do
    [ "$element" = "$value" ] && return 0
  done

  return 1

}


hubic_create_container(){

  hubic_check_api_initialized || return 1

  hubic_parse_args "$@" -o "${FUNCNAME[0]#hubic_}" -sc 201,202,400,404,507

  hubic_log INFO "Creating container $hubic_current_container..."

  hubic_do_operation -X PUT \
    -H "X-Auth-Token: $hubic_file_token" \
    -H "Content-length: 0" \
    "${hubic_file_endpoint}/${hubic_current_container}"
}

hubic_delete_container(){

  hubic_check_api_initialized || return 1

  hubic_parse_args "$@" -o "${FUNCNAME[0]#hubic_}" -sc 204,404,409
  
  hubic_log INFO "Deleting container $hubic_current_container..."

  hubic_do_operation -X DELETE \
    -H "X-Auth-Token: $hubic_file_token" \
    -H "Content-length: 0" \
    "${hubic_file_endpoint}/${hubic_current_container}"
}


hubic_list_containers(){

  hubic_check_api_initialized || return 1

  hubic_parse_args "$@" -o "${FUNCNAME[0]#hubic_}" -sc 200,204,503
 
  local retval
 
  hubic_object_list=()

  hubic_do_operation -X GET \
    -H "X-Auth-Token: $hubic_file_token" \
    -H "Content-length: 0" \
    "${hubic_file_endpoint}/"

  retval=$?

  local oIFS=$IFS
  IFS=$'\n'
  hubic_object_list=( $hubic_last_http_body )
  IFS=$oIFS

  return $retval
}


hubic_create_directory(){

  hubic_check_api_initialized || return 1

  hubic_parse_args "$@" -o "${FUNCNAME[0]#hubic_}" -sc 201

  hubic_log INFO "Creating directory '$hubic_current_path'..."
  
  hubic_do_operation -X PUT \
    -H "X-Auth-Token: $hubic_file_token" \
    -H "Content-type: application/directory" \
    -H "Content-length: 0" \
    "${hubic_file_endpoint}/${hubic_current_container}/${hubic_current_path}"
}

hubic_do_curl(){

  local result

  result=$(
    $curl -s -D- \
    -b "$hubic_cookiejar" -c "$hubic_cookiejar" \
    "$@"
  )

  hubic_last_http_headers=$($perl -pe 'exit if /^\r$/;' <<< "$result")
  hubic_last_http_body=$($perl -ne 'print if $ok; $ok = 1 if /^\r$/;' <<< "$result")
  hubic_last_http_code=$($perl -ne 'if ($_ =~ /^HTTP/) { print ((split())[1]); exit };' <<< "$result")

}

hubic_parse_args(){

  hubic_current_container=
  hubic_current_path=
  hubic_current_remote_file=

  hubic_current_success_codes=()
  hubic_current_operation=
  
  while [ $# -gt 0 ]; do

    case $1 in
      -c|--container)
        hubic_current_container=$2
        shift 2
        ;;

      -p|--path)
        hubic_current_path=$2
        shift 2
        ;;
    
      -l|--local)
        hubic_current_local_file=$2
        shift 2
        ;;

      -r|--remote)
        hubic_current_remote_file=$2
        shift 2
        ;;

      -sc|--success-code)
        IFS=',' read -r -a hubic_current_success_codes <<< "$2"
        shift 2
        ;;

      -o|--operation)
        hubic_current_operation=$2
        shift 2
        ;;

      *)
        hubic_log WARNING "Unknown option/arg: '$1', skipping..."
        shift
        ;;
    esac

  done

  [ "$hubic_current_container" = "" ] && hubic_current_container=default
}


hubic_list_files(){

  hubic_check_api_initialized || return 1

  hubic_parse_args "$@" -o "${FUNCNAME[0]#hubic_}" -sc 200,204,404

  local retval

  hubic_object_list=()

  [ "$hubic_current_path" != "" ] && [[ "$hubic_current_path" != */ ]] && hubic_current_path="${hubic_current_path}/"

  hubic_log INFO "Getting object list for '${hubic_current_container}/${hubic_current_path}'"

  hubic_do_operation -X GET \
    -H "X-Auth-Token: $hubic_file_token" \
    "${hubic_file_endpoint}/${hubic_current_container}/?limit=10000&prefix=${hubic_current_path}"
  
  retval=$?

  local oIFS=$IFS
  IFS=$'\n'
  hubic_object_list=( $hubic_last_http_body )
  IFS=$oIFS

  return $retval
}

hubic_delete_object(){

  hubic_check_api_initialized || return 1

  hubic_parse_args "$@" -o "${FUNCNAME[0]#hubic_}" -sc 204,404

  hubic_log INFO "Deleting object '${hubic_current_container}/${hubic_current_path}'"

  hubic_do_operation -X DELETE \
    -H "X-Auth-Token: $hubic_file_token" \
    "${hubic_file_endpoint}/${hubic_current_container}/${hubic_current_path}"
}



